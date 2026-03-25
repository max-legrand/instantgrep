defmodule Instantgrep.Matcher do
  @moduledoc """
  Parallel regex matching on candidate files.

  Given a list of file paths and a compiled regex, scans each file
  line-by-line and returns matching results in grep-compatible format.
  """

  @type match_result :: %{
          file: String.t(),
          line: pos_integer(),
          col: pos_integer(),
          content: String.t()
        }

  @doc """
  Match a regex against a list of candidate files in parallel.

  Accepts either a compiled `%Regex{}` or a `{pattern, flags}` tuple.
  When a tuple is given the regex is compiled fresh inside each Task so
  that no compiled regex term is ever sent across BEAM process boundaries
  (doing so triggers `size_object: matchstate term not allowed` / SIGABRT).

  Returns a list of `%{file: path, line: number, content: text}` maps,
  sorted by file path and line number.
  """
  @spec match_files([String.t()], Regex.t() | {String.t(), String.t()}) :: [match_result()]
  def match_files(file_paths, {pattern, flags}) do
    file_paths
    |> Task.async_stream(
      fn path ->
        {:ok, regex} = Regex.compile(pattern, flags)
        match_single_file(path, regex)
      end,
      max_concurrency: System.schedulers_online() * 2,
      ordered: false,
      timeout: 10_000
    )
    |> Enum.flat_map(fn
      {:ok, results} -> results
      {:exit, _reason} -> []
    end)
    |> Enum.sort_by(fn %{file: f, line: l} -> {f, l} end)
  end

  def match_files(file_paths, %Regex{} = regex) do
    source = Regex.source(regex)
    flags = Regex.opts(regex)
    match_files(file_paths, {source, flags})
  end

  @doc """
  Brute-force scan: match regex against all files in a directory.

  This is the fallback "grep mode" — no index used.
  """
  @spec brute_force(String.t(), Regex.t() | {String.t(), String.t()}) :: [match_result()]
  def brute_force(path, regex) do
    files =
      path
      |> Instantgrep.Scanner.scan()
      |> Enum.map(fn {_id, file_path} -> file_path end)

    match_files(files, regex)
  end

  @doc """
  Format match results as grep-compatible output lines.
  """
  @spec format_results([match_result()]) :: String.t()
  def format_results(results) do
    results
    |> Enum.map(fn %{file: f, line: l, col: col, content: c} ->
      "#{f}:#{l}:#{col}:#{c}"
    end)
    |> Enum.join("\n")
  end

  # --- Private ---

  defp match_single_file(path, regex) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, line_num} ->
          # Use return: :index to get a byte offset for the column.
          # Avoid binary_part/3 + String.length/1 on the result: the sub-binary
          # from binary_part retains a reference into the underlying matched
          # binary, and in OTP 27 walking that term for grapheme counting causes
          # `size_object: matchstate term not allowed` / SIGABRT in the BEAM GC.
          # Reporting a byte-offset column is accurate for ASCII and acceptable
          # for multibyte content — editors use byte offsets anyway.
          case Regex.run(regex, line, return: :index) do
            [{col_byte, _len} | _] ->
              [%{file: path, line: line_num, col: col_byte + 1, content: line}]

            nil ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end
end
