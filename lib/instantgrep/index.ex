defmodule Instantgrep.Index do
  @moduledoc """
  ETS-backed trigram inverted index with disk persistence.

  Builds a trigram index from a set of files using parallel workers.
  Each trigram maps to a list of `{file_id, next_mask, loc_mask}` postings.
  The index can be saved to and loaded from a `.instantgrep/` directory.
  """

  alias Instantgrep.{Scanner, Trigram}

  @type t :: %__MODULE__{
          postings_table: :ets.tid(),
          files_table: :ets.tid(),
          file_count: non_neg_integer(),
          trigram_count: non_neg_integer(),
          build_time_us: non_neg_integer()
        }

  defstruct [:postings_table, :files_table, :file_count, :trigram_count, :build_time_us]

  @postings_file "postings.dat"
  @files_file "files.dat"

  @doc """
  Return the cache directory for a given project root.

  Uses `$XDG_CACHE_HOME/instantgrep/<hex>` (falling back to `~/.cache`) where
  `<hex>` is a SHA-256 digest of the absolute project path. This keeps index
  files out of the project tree entirely.
  """
  @spec cache_dir(String.t()) :: String.t()
  def cache_dir(base_dir) do
    base_dir = Path.expand(base_dir)
    # Use the first 20 bytes (40 hex chars) — enough for uniqueness, short enough
    # that the daemon socket path stays within the 104-byte macOS/Linux limit.
    hash = :crypto.hash(:sha256, base_dir) |> binary_part(0, 20) |> Base.encode16(case: :lower)

    xdg =
      System.get_env("XDG_CACHE_HOME") ||
        Path.join(System.user_home!(), ".cache")

    Path.join([xdg, "instantgrep", hash])
  end

  @doc """
  Build a trigram index from a directory path.

  Uses file-level incremental updates - only reindexes files that have changed.
  """
  @spec build(String.t(), keyword()) :: t()
  def build(path, opts \\ []) do
    incremental = Keyword.get(opts, :incremental, true)
    start_time = System.monotonic_time(:microsecond)

    files = Scanner.scan(path, opts)

    postings_table = :ets.new(:instantgrep_postings, [:set, :public, read_concurrency: true])
    files_table = :ets.new(:instantgrep_files, [:set, :public, read_concurrency: true])

    # Get current file mtimes
    current_mtimes =
      Enum.reduce(files, %{}, fn {file_id, file_path}, acc ->
        case File.stat(file_path, [{:time, :posix}]) do
          {:ok, %{mtime: mtime}} -> Map.put(acc, file_path, mtime)
          _ -> acc
        end
      end)

    # Try to load existing index and mtimes for incremental updates
    existing_mtimes = if incremental, do: load_mtimes(path), else: %{}

    # Determine which files need reindexing
    {files_to_index, files_unchanged} =
      if incremental and existing_mtimes != %{} do
        Enum.reduce(files, {[], []}, fn {file_id, file_path}, {to_index, unchanged} ->
          current_mtime = Map.get(current_mtimes, file_path)
          existing_mtime = Map.get(existing_mtimes, file_path)

          cond do
            current_mtime == nil ->
              # File deleted
              {to_index, unchanged}

            existing_mtime == nil or current_mtime > existing_mtime ->
              # New or changed - needs reindexing
              {[{file_id, file_path} | to_index], unchanged}

            true ->
              # Unchanged
              {to_index, [{file_id, file_path} | unchanged]}
          end
        end)
      else
        {files, []}
      end

    # Load unchanged files from existing index if doing incremental
    if incremental and existing_mtimes != %{} and files_unchanged != [] do
      case load(path) do
        {:ok, existing_index} ->
          # Copy trigrams for unchanged files
          existing_postings = :ets.tab2list(existing_index.postings_table)
          :ets.insert(postings_table, existing_postings)

          # Copy file paths
          existing_files = :ets.tab2list(existing_index.files_table)

          Enum.each(existing_files, fn {fid, fpath} ->
            :ets.insert(files_table, {fid, fpath})
          end)

        _ ->
          :ok
      end
    end

    # Store file mappings for new/changed files
    Enum.each(files_to_index, fn {file_id, file_path} ->
      :ets.insert(files_table, {file_id, file_path})
    end)

    # Reindex changed files
    files_to_index
    |> Task.async_stream(
      fn {file_id, file_path} ->
        case File.read(file_path) do
          {:ok, content} ->
            masks = Trigram.extract_with_masks(content)
            {file_id, masks}

          {:error, _} ->
            {file_id, %{}}
        end
      end,
      max_concurrency: System.schedulers_online() * 2,
      ordered: false,
      timeout: 30_000
    )
    |> Enum.each(fn {:ok, {file_id, masks}} ->
      Enum.each(masks, fn {trigram, {next_mask, loc_mask}} ->
        downcased_trigram = String.downcase(trigram)

        case :ets.lookup(postings_table, downcased_trigram) do
          [{^downcased_trigram, postings}] ->
            :ets.insert(
              postings_table,
              {downcased_trigram, [{file_id, next_mask, loc_mask} | postings]}
            )

          [] ->
            :ets.insert(postings_table, {downcased_trigram, [{file_id, next_mask, loc_mask}]})
        end
      end)
    end)

    # Save mtimes for next incremental build
    if incremental do
      save_mtimes(path, current_mtimes)
    end

    elapsed = System.monotonic_time(:microsecond) - start_time
    trigram_count = :ets.info(postings_table, :size)

    %__MODULE__{
      postings_table: postings_table,
      files_table: files_table,
      file_count: length(files),
      trigram_count: trigram_count,
      build_time_us: elapsed
    }
  end

  # Load file mtimes from disk
  defp load_mtimes(base_dir) do
    dir = cache_dir(base_dir)
    path = Path.join(dir, "mtimes.dat")

    if File.regular?(path) do
      File.read!(path) |> :erlang.binary_to_term()
    else
      %{}
    end
  end

  # Save file mtimes to disk
  defp save_mtimes(base_dir, mtimes) do
    dir = cache_dir(base_dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mtimes.dat"), :erlang.term_to_binary(mtimes))
  end

  @doc """
  Query the index with a list of trigrams. Returns a `MapSet` of file IDs
  whose documents contain the given trigram.
  """
  @spec lookup(t(), binary()) :: MapSet.t(non_neg_integer())
  def lookup(%__MODULE__{postings_table: table}, trigram) do
    case :ets.lookup(table, trigram) do
      [{^trigram, postings}] ->
        postings
        |> Enum.map(fn {file_id, _next, _loc} -> file_id end)
        |> MapSet.new()

      [] ->
        MapSet.new()
    end
  end

  @doc """
  Resolve file IDs to file paths.
  """
  @spec resolve_files(t(), MapSet.t(non_neg_integer()) | :all) :: [String.t()]
  def resolve_files(%__MODULE__{files_table: table, file_count: count}, :all) do
    for id <- 0..(count - 1),
        [{^id, path}] = :ets.lookup(table, id) do
      path
    end
  end

  def resolve_files(%__MODULE__{files_table: table}, file_ids) do
    file_ids
    |> Enum.flat_map(fn id ->
      case :ets.lookup(table, id) do
        [{^id, path}] -> [path]
        [] -> []
      end
    end)
    |> Enum.sort()
  end

  @doc """
  Return all indexed file paths.
  """
  @spec all_files(t()) :: [String.t()]
  def all_files(%__MODULE__{} = index) do
    resolve_files(index, :all)
  end

  @doc """
  Save the index to disk in the given base directory.
  """
  @spec save(t(), String.t()) :: :ok
  def save(%__MODULE__{postings_table: pt, files_table: ft} = index, base_dir) do
    dir = cache_dir(base_dir)
    File.mkdir_p!(dir)

    postings_data = :ets.tab2list(pt)
    files_data = :ets.tab2list(ft)

    meta = %{
      file_count: index.file_count,
      trigram_count: index.trigram_count,
      build_time_us: index.build_time_us
    }

    File.write!(Path.join(dir, @postings_file), :erlang.term_to_binary({postings_data, meta}))
    File.write!(Path.join(dir, @files_file), :erlang.term_to_binary(files_data))

    :ok
  end

  @doc """
  Load a previously saved index from disk.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, :not_found}
  def load(base_dir) do
    dir = cache_dir(base_dir)
    postings_path = Path.join(dir, @postings_file)
    files_path = Path.join(dir, @files_file)

    if File.regular?(postings_path) and File.regular?(files_path) do
      {postings_data, meta} =
        postings_path |> File.read!() |> :erlang.binary_to_term()

      files_data =
        files_path |> File.read!() |> :erlang.binary_to_term()

      postings_table = :ets.new(:instantgrep_postings, [:set, :public, read_concurrency: true])
      files_table = :ets.new(:instantgrep_files, [:set, :public, read_concurrency: true])

      :ets.insert(postings_table, postings_data)
      :ets.insert(files_table, files_data)

      {:ok,
       %__MODULE__{
         postings_table: postings_table,
         files_table: files_table,
         file_count: meta.file_count,
         trigram_count: meta.trigram_count,
         build_time_us: meta.build_time_us
       }}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Print index statistics to stdout.
  """
  @spec stats(t()) :: :ok
  def stats(%__MODULE__{} = index) do
    IO.puts("Index Statistics:")
    IO.puts("  Files indexed:   #{index.file_count}")
    IO.puts("  Unique trigrams: #{index.trigram_count}")
    IO.puts("  Build time:      #{format_time(index.build_time_us)}")
    :ok
  end

  defp format_time(us) when us < 1_000, do: "#{us}µs"
  defp format_time(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  defp format_time(us), do: "#{Float.round(us / 1_000_000, 2)}s"
end
