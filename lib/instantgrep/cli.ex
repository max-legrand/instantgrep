defmodule Instantgrep.CLI do
  @moduledoc """
  Main CLI entry point for the instantgrep escript.

  Usage:
      instantgrep [OPTIONS] PATTERN [PATH]

  Options:
      --build              Build/rebuild index only (no search)
      --no-index           Skip index, brute-force scan (like grep)
      --daemon             Start persistent daemon on a Unix socket
      --search-only        Send one query to a running daemon and print results
      --socket-path        Print the daemon socket path for a directory and exit
      -i, --ignore-case    Case-insensitive matching
      --stats              Show index statistics
      -h, --help           Show this help message

  Examples:
      instantgrep "defmodule" lib/
      instantgrep --build .
      instantgrep -i "todo|fixme" src/
      instantgrep --no-index "pattern" .
      instantgrep --daemon .
      instantgrep --search-only "defmodule" .
  """

  alias Instantgrep.{Daemon, Index, Matcher, Query}

  @doc false
  @spec main([String.t()]) :: :ok
  def main(args) do
    args
    |> parse_args()
    |> execute()
  end

  # --- Argument Parsing ---

  defp parse_args(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          build: :boolean,
          no_index: :boolean,
          ignore_case: :boolean,
          stats: :boolean,
          help: :boolean,
          daemon: :boolean,
          search_only: :boolean,
          socket_path: :boolean
        ],
        aliases: [i: :ignore_case, h: :help]
      )

    %{
      build: Keyword.get(opts, :build, false),
      no_index: Keyword.get(opts, :no_index, false),
      ignore_case: Keyword.get(opts, :ignore_case, false),
      stats: Keyword.get(opts, :stats, false),
      help: Keyword.get(opts, :help, false),
      daemon: Keyword.get(opts, :daemon, false),
      search_only: Keyword.get(opts, :search_only, false),
      socket_path: Keyword.get(opts, :socket_path, false),
      pattern: Enum.at(positional, 0),
      path: Enum.at(positional, 1, ".")
    }
  end

  # --- Command Execution ---

  defp execute(%{help: true}) do
    IO.puts(@moduledoc)
  end

  defp execute(%{build: true, path: path}) do
    IO.puts("Building index for #{path}...")
    index = Index.build(path)
    Index.save(index, path)
    Index.stats(index)
    IO.puts("Index saved to #{Index.cache_dir(path)}/")
  end

  defp execute(%{stats: true, path: path}) do
    case Index.load(path) do
      {:ok, index} -> Index.stats(index)
      {:error, :not_found} -> IO.puts(:stderr, "No index found. Run: instantgrep --build #{path}")
    end
  end

  defp execute(%{socket_path: true, path: path, pattern: pattern}) do
    # Accept the path from either position (pattern slot or path slot)
    dir = if pattern != nil, do: pattern, else: path
    IO.puts(Daemon.socket_path(dir))
  end

  defp execute(%{daemon: true, path: path}) do
    Daemon.run(path)
  end

  defp execute(%{search_only: true, pattern: nil}) do
    IO.puts(:stderr, "Error: no pattern specified. Run: instantgrep --help")
    System.halt(1)
  end

  defp execute(%{search_only: true, pattern: pattern, path: path, ignore_case: ignore_case}) do
    execute_search_only(pattern, path, ignore_case)
  end

  defp execute(%{pattern: nil}) do
    IO.puts(:stderr, "Error: no pattern specified. Run: instantgrep --help")
    System.halt(1)
  end

  defp execute(%{no_index: true} = args) do
    execute_brute_force(args)
  end

  defp execute(args) do
    execute_indexed(args)
  end

  defp execute_indexed(%{pattern: pattern, path: path, ignore_case: ignore_case}) do
    regex = compile_regex(pattern, ignore_case)

    # Try loading existing index, or build one
    index =
      case Index.load(path) do
        {:ok, loaded} ->
          loaded

        {:error, :not_found} ->
          IO.puts(:stderr, "No index found, building...")
          idx = Index.build(path)
          Index.save(idx, path)
          idx
      end

    # Decompose pattern into trigram query
    query_pattern = if ignore_case, do: String.downcase(pattern), else: pattern
    query_tree = Query.decompose(query_pattern)

    # Evaluate query tree against index
    candidate_ids =
      Query.evaluate(query_tree, fn trigram ->
        lookup_trigram = if ignore_case, do: String.downcase(trigram), else: trigram
        Index.lookup(index, lookup_trigram)
      end)

    # Resolve file IDs to paths
    candidate_files = Index.resolve_files(index, candidate_ids)

    # Full regex verification
    results = Matcher.match_files(candidate_files, regex)

    # Output
    output = Matcher.format_results(results)

    if output != "" do
      IO.puts(output)
    end
  end

  defp execute_brute_force(%{pattern: pattern, path: path, ignore_case: ignore_case}) do
    regex = compile_regex(pattern, ignore_case)
    results = Matcher.brute_force(path, regex)
    output = Matcher.format_results(results)

    if output != "" do
      IO.puts(output)
    end
  end

  defp execute_search_only(pattern, path, ignore_case) do
    sock_path = Daemon.socket_path(path)

    case :gen_tcp.connect({:local, sock_path}, 0,
           mode: :binary,
           packet: :line,
           active: false
         ) do
      {:ok, sock} ->
        query = if ignore_case, do: "(?i)#{pattern}", else: pattern
        :gen_tcp.send(sock, query <> "\n")
        collect_results(sock)
        :gen_tcp.close(sock)

      {:error, reason} ->
        IO.puts(
          :stderr,
          "Daemon not running (#{inspect(reason)}). Start with: instantgrep --daemon #{path}"
        )

        System.halt(1)
    end
  end

  # Read lines from socket until the sentinel "\0\n", printing each result line.
  defp collect_results(sock) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, "\0\n"} ->
        :ok

      {:ok, line} ->
        IO.write(line)
        collect_results(sock)

      {:error, _} ->
        :ok
    end
  end

  defp compile_regex(pattern, true) do
    case Regex.compile(pattern, "i") do
      {:ok, regex} -> regex
      {:error, {msg, _}} -> error_exit("Invalid regex: #{msg}")
    end
  end

  defp compile_regex(pattern, false) do
    case Regex.compile(pattern) do
      {:ok, regex} -> regex
      {:error, {msg, _}} -> error_exit("Invalid regex: #{msg}")
    end
  end

  defp error_exit(message) do
    IO.puts(:stderr, "Error: #{message}")
    System.halt(1)
  end
end
