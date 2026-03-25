defmodule Instantgrep.Daemon do
  @moduledoc """
  Unix-socket daemon for persistent index searches.

  Starts a server that loads the trigram index once, then accepts search
  queries over a Unix domain socket. Each query is a single newline-terminated
  line; results are streamed back in `file:line:col:content` format, followed
  by a NUL byte (`\\0`) to signal end-of-results.

  Socket path convention: `<index_dir>/.instantgrep/daemon.sock`

  Protocol (v1 — plain):
    client sends:  "<pattern>\\n"
    server sends:  "<file>:<line>:<col>:<content>\\n" (0 or more lines)
                   "\\0\\n"  (end-of-results sentinel)

  Protocol (v2 — with options):
    client sends:  "opts:<key>=<val>[,<key>=<val>...]\\n<pattern>\\n"
    option keys:
      flags : string  — regex flags, e.g. "i" for case-insensitive
      glob  : string  — file glob filter, e.g. "*.rb" or "{*.rb,*.rake}"
    server sends:  same as v1

  Example:
    "opts:flags=i,glob=*.rb\\nmy_pattern\\n"
  """

  alias Instantgrep.{Index, Matcher, Query}

  @sentinel "\0\n"

  @doc """
  Start the daemon for the given directory. Blocks until the socket is closed
  or the process receives SIGINT/SIGTERM.
  """
  @spec run(String.t()) :: no_return()
  def run(base_dir) do
    base_dir = Path.expand(base_dir)
    sock_path = socket_path(base_dir)

    index =
      case Index.load(base_dir) do
        {:ok, idx} ->
          idx

        {:error, :not_found} ->
          IO.puts(:stderr, "No index found, building...")
          idx = Index.build(base_dir)
          Index.save(idx, base_dir)
          idx
      end

    # Remove stale socket file if it exists
    File.rm(sock_path)

    {:ok, listen_sock} =
      :gen_tcp.listen(0,
        ifaddr: {:local, sock_path},
        mode: :binary,
        packet: :line,
        active: false,
        reuseaddr: true,
        backlog: 32
      )

    IO.puts(:stderr, "instantgrep daemon ready: #{sock_path}")

    accept_loop(listen_sock, index)
  end

  @doc """
  Return the socket path for a given base directory.
  """
  @spec socket_path(String.t()) :: String.t()
  def socket_path(base_dir) do
    Path.join(Instantgrep.Index.cache_dir(base_dir), "daemon.sock")
  end

  # --- Private ---

  defp accept_loop(listen_sock, index) do
    case :gen_tcp.accept(listen_sock) do
      {:ok, client} ->
        # Handle each client in a separate process so the accept loop stays hot
        spawn(fn -> handle_client(client, index) end)
        accept_loop(listen_sock, index)

      {:error, reason} ->
        IO.puts(:stderr, "Accept error: #{inspect(reason)}")
    end
  end

  defp handle_client(sock, index) do
    with {:ok, line1} <- :gen_tcp.recv(sock, 0) do
      {pattern, opts} = parse_request(sock, String.trim_trailing(line1, "\n"))

      case Regex.compile(pattern, Map.get(opts, "flags", "")) do
        {:ok, _} ->
          query_tree = Query.decompose(pattern)

          candidate_ids =
            Query.evaluate(query_tree, fn trigram ->
              lookup =
                if String.contains?(Map.get(opts, "flags", ""), "i"),
                  do: String.downcase(trigram),
                  else: trigram

              Index.lookup(index, lookup)
            end)

          candidate_files =
            index
            |> Index.resolve_files(candidate_ids)
            |> filter_glob(Map.get(opts, "glob"))

          results = Matcher.match_files(candidate_files, {pattern, Map.get(opts, "flags", "")})
          output = Matcher.format_results(results)

          if output != "" do
            :gen_tcp.send(sock, output <> "\n")
          end

        {:error, _} ->
          :ok
      end

      :gen_tcp.send(sock, @sentinel)
      :gen_tcp.close(sock)
    else
      {:error, _} -> :ok
    end
  end

  # If the first line starts with "opts:", parse key=value pairs and read a
  # second line for the pattern. Otherwise treat the line as the pattern (v1).
  defp parse_request(sock, first_line) do
    if String.starts_with?(first_line, "opts:") do
      opts =
        first_line
        |> String.trim_leading("opts:")
        |> String.split(",")
        |> Enum.reduce(%{}, fn pair, acc ->
          case String.split(pair, "=", parts: 2) do
            [k, v] -> Map.put(acc, k, v)
            _ -> acc
          end
        end)

      case :gen_tcp.recv(sock, 0) do
        {:ok, line2} -> {String.trim_trailing(line2, "\n"), opts}
        {:error, _} -> {"", opts}
      end
    else
      {first_line, %{}}
    end
  end

  # Filter a list of file paths by a glob pattern.
  # Supports brace expansion like `{*.rb,*.rake}` by splitting on commas inside braces.
  defp filter_glob(files, nil), do: files
  defp filter_glob(files, ""), do: files

  defp filter_glob(files, glob) do
    patterns = expand_glob_alts(glob)

    Enum.filter(files, fn path ->
      base = Path.basename(path)
      Enum.any?(patterns, &glob_match?(&1, base))
    end)
  end

  # Expand `{a,b,c}` alternatives into a list of plain globs.
  defp expand_glob_alts(glob) do
    case Regex.run(~r/^\{(.+)\}$/, glob) do
      [_, inner] -> String.split(inner, ",")
      _ -> [glob]
    end
  end

  # Simple glob match: `*` matches any sequence of non-separator chars.
  defp glob_match?(pattern, string) do
    regex_str =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    case Regex.compile("^" <> regex_str <> "$") do
      {:ok, r} -> Regex.match?(r, string)
      _ -> false
    end
  end
end
