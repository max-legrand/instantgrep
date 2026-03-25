defmodule Instantgrep.Daemon do
  @moduledoc """
  Unix-socket daemon for persistent index searches.

  Starts a server that loads the trigram index once, then accepts search
  queries over a Unix domain socket. Each query is a single newline-terminated
  line; results are streamed back in `file:line:col:content` format, followed
  by a NUL byte (`\\0`) to signal end-of-results.

  Socket path convention: `<index_dir>/.instantgrep/daemon.sock`

  Protocol:
    client sends:  "<pattern>\\n"
    server sends:  "<file>:<line>:<col>:<content>\\n" (0 or more lines)
                   "\\0\\n"  (end-of-results sentinel)
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
    case :gen_tcp.recv(sock, 0) do
      {:ok, line} ->
        pattern = String.trim_trailing(line, "\n")

        case Regex.compile(pattern) do
          {:ok, _regex} ->
            query_tree = Query.decompose(pattern)

            candidate_ids =
              Query.evaluate(query_tree, fn trigram ->
                Index.lookup(index, trigram)
              end)

            candidate_files = Index.resolve_files(index, candidate_ids)
            results = Matcher.match_files(candidate_files, {pattern, ""})
            output = Matcher.format_results(results)

            if output != "" do
              :gen_tcp.send(sock, output <> "\n")
            end

          {:error, _} ->
            :ok
        end

        :gen_tcp.send(sock, @sentinel)
        :gen_tcp.close(sock)

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end
end
