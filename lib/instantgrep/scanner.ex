defmodule Instantgrep.Scanner do
  @moduledoc """
  Recursive file scanner with ignore-pattern support.

  Walks a directory tree collecting text files suitable for indexing.
  Skips binary files, VCS directories, build artifacts, and paths
  matching `.gitignore` patterns.
  """

  @default_ignores [
    # VCS
    ~r{/\.git(/|$)},
    ~r{/\.jj(/|$)},
    ~r{/\.hg(/|$)},
    ~r{/\.svn(/|$)},
    # Dependencies / build output
    ~r{/node_modules(/|$)},
    ~r{/_build(/|$)},
    ~r{/deps(/|$)},
    ~r{/target(/|$)},
    ~r{/vendor(/|$)},
    ~r{/\.zig-cache(/|$)},
    ~r{/zig-out(/|$)},
    # Editors / tools
    ~r{/\.elixir_ls(/|$)},
    ~r{/\.idea(/|$)},
    ~r{/\.vscode(/|$)},
    # instantgrep index cache
    ~r{/\.instantgrep(/|$)}
  ]

  @binary_extensions ~w(.png .jpg .jpeg .gif .bmp .ico .svg .woff .woff2 .ttf .eot
    .mp3 .mp4 .avi .mov .pdf .zip .tar .gz .bz2 .xz .7z .rar
    .exe .dll .so .dylib .o .a .beam .class .jar .war .pyc .pyo
    .DS_Store .lock)

  @max_file_size 1_048_576

  @doc """
  Scan a directory and return a list of `{file_id, path}` tuples.

  Options:
  - `:max_file_size` — skip files larger than this (default: 1MB)
  """
  @spec scan(String.t(), keyword()) :: [{non_neg_integer(), String.t()}]
  def scan(path, opts \\ []) do
    max_size = Keyword.get(opts, :max_file_size, @max_file_size)
    gitignore_patterns = load_gitignore(path)

    path
    |> Path.expand()
    |> do_scan(max_size, gitignore_patterns)
    |> Enum.with_index()
    |> Enum.map(fn {file_path, idx} -> {idx, file_path} end)
  end

  # --- Private ---

  defp do_scan(path, max_size, gitignore_patterns) do
    cond do
      File.regular?(path) ->
        if indexable_file?(path, max_size, gitignore_patterns), do: [path], else: []

      File.dir?(path) ->
        if ignored_dir?(path) or gitignore_match?(path, gitignore_patterns) do
          []
        else
          path
          |> File.ls!()
          |> Enum.flat_map(fn entry ->
            full_path = Path.join(path, entry)
            do_scan(full_path, max_size, gitignore_patterns)
          end)
          |> Enum.sort()
        end

      true ->
        []
    end
  end

  defp indexable_file?(path, max_size, gitignore_patterns) do
    ext = Path.extname(path)
    basename = Path.basename(path)

    cond do
      ext in @binary_extensions -> false
      String.starts_with?(basename, ".") and ext == "" -> false
      gitignore_match?(path, gitignore_patterns) -> false
      true -> file_size_ok?(path, max_size) and not binary_content?(path)
    end
  end

  defp file_size_ok?(path, max_size) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size <= max_size and size > 0
      _ -> false
    end
  end

  defp binary_content?(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        chunk = IO.binread(file, 512)
        File.close(file)

        case chunk do
          :eof -> false
          {:error, _} -> true
          data when is_binary(data) -> binary_heuristic?(data)
        end

      _ ->
        true
    end
  end

  defp binary_heuristic?(data) do
    # If more than 10% of bytes are null bytes, treat as binary
    total = byte_size(data)

    if total == 0 do
      false
    else
      null_count =
        for <<byte <- data>>, byte == 0, reduce: 0 do
          count -> count + 1
        end

      null_count / total > 0.1
    end
  end

  defp ignored_dir?(path) do
    Enum.any?(@default_ignores, &Regex.match?(&1, path))
  end

  defp gitignore_match?(_path, []), do: false

  defp gitignore_match?(path, patterns) do
    Enum.any?(patterns, &Regex.match?(&1, path))
  end

  defp load_gitignore(path) do
    dir = if File.dir?(path), do: path, else: Path.dirname(path)
    root = Path.expand(dir)
    gitignore_file = Path.join(root, ".gitignore")

    if File.regular?(gitignore_file) do
      gitignore_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&(String.starts_with?(&1, "#") or String.trim(&1) == ""))
      |> Enum.flat_map(&gitignore_to_regex(&1, root))
    else
      []
    end
  end

  defp gitignore_to_regex(pattern, root) do
    pattern = String.trim(pattern)

    # A trailing "/" means "match directories only" — strip it for the regex
    # (we apply the pattern to both files and directories; the directory-only
    # check is implicit because we test directories in do_scan too).
    {pattern, _dir_only} =
      if String.ends_with?(pattern, "/") do
        {String.slice(pattern, 0..-2//1), true}
      else
        {pattern, false}
      end

    # Patterns starting with "/" are rooted to the repo root.
    # All others can match any path component.
    anchored = String.starts_with?(pattern, "/")

    bare =
      if anchored do
        String.slice(pattern, 1..-1//1)
      else
        pattern
      end

    # Convert gitignore glob syntax to regex
    escaped =
      bare
      |> String.replace(".", "\\.")
      |> String.replace("**/", "(.*/)?")
      |> String.replace("*", "[^/]*")
      |> String.replace("?", "[^/]")

    final_regex_str =
      if anchored do
        # Must match from the repo root exactly
        Regex.escape(root) <> "/" <> escaped <> "(/|$)"
      else
        # Must match at a path-segment boundary to avoid partial-name collisions
        # e.g. "ig" must not match inside "instantgrep"
        "(^|/)" <> escaped <> "(/|$)"
      end

    case Regex.compile(final_regex_str) do
      {:ok, regex} -> [regex]
      _ -> []
    end
  end
end
