defmodule TrieHard do
  @moduledoc """
  A fast, memory-efficient trie (prefix tree) with autocomplete, implemented as a
  Rust NIF.

  ## Features

  - **Fast**: sub-microsecond lookups and prefix checks
  - **Compact**: shared prefixes; two node layouts (see `new/1`)
  - **Deterministic**: `auto_complete/3` returns keys in lexicographic order
  - **Unicode**: keys are UTF-8 strings. Single-key functions raise
    `FunctionClauseError` for non-binary keys; `insert_many/2` and
    `add_word_list/2` raise `ArgumentError` for any invalid element; invalid
    UTF-8 always raises `ArgumentError`
  - **Any value**: values are arbitrary Erlang terms
  - **Concurrent**: see "Concurrency" below

  ## Example

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "cat", :feline)
      :ok
      iex> TrieHard.insert_many(trie, [{"car", %{wheels: 4}}, {"card", {"payment", "plastic"}}])
      :ok
      iex> TrieHard.fetch(trie, "cat")
      {:ok, :feline}
      iex> TrieHard.fetch(trie, "dog")
      {:error, :not_found}
      iex> TrieHard.get(trie, "dog", :none)
      :none
      iex> TrieHard.auto_complete(trie, "ca", 10)
      ["car", "card", "cat"]
      iex> TrieHard.count_prefix(trie, "car")
      2

  ## Concurrency

  A trie can be shared by any number of processes. Reads run concurrently and
  writes are exclusive (a read-write lock). Each call first runs on the calling
  scheduler without blocking:

  - when the key is longer than 4 KiB, the value is larger than 64 KiB, or the
    operation would visit more than 10,000 nodes or copy more than 64 KiB of
    keys (results, or an edge split/merged in the `:radix` layout), it is
    retried on a dirty CPU scheduler;
  - when a writer holds the lock, the calling process yields and retries
    (sleeping 1 ms between later attempts), so waiting does not occupy dirty
    schedulers; after about 50 ms it waits on a dirty scheduler instead.

  `add_word_list/2` and `insert_many/2` always run on a dirty scheduler, in
  chunks of at most 1,000 entries or 1 MiB of keys and values, so no bulk call
  holds the write lock for long. Bound key lengths for untrusted input: a
  single huge key makes its own write long.

  Values are encoded with `:erlang.term_to_binary/1` and decoded with
  `:erlang.binary_to_term/2` (`[:safe]`) in the calling process, never inside
  the NIF.

  ## Memory

  A trie lives in native memory owned by its reference. It is freed when the last
  reference is garbage collected, on whichever scheduler thread runs that GC;
  freeing a trie with millions of keys takes correspondingly long on that thread.
  """

  alias TrieHard.Native

  @opaque t :: reference()
  @type key :: String.t()
  @type value :: term()
  @typedoc "Node layout, see `new/1`."
  @type layout :: :sorted | :radix

  @layouts [:sorted, :radix]

  # Bounds on each bulk NIF call (whichever is hit first), which bound how long
  # the write lock is held and so how long readers wait.
  @chunk_size 1_000
  @chunk_bytes 1_048_576

  # auto_complete limits decode as a u64 in the NIF.
  @max_results_cap 0xFFFF_FFFF_FFFF_FFFF

  @doc """
  Creates a new empty trie.

  ## Options

  - `:layout` - `:radix` (default) or `:sorted`.
    - `:radix` is path-compressed: a run of bytes without branches is a single
      node, so inserts and deletes may split or merge edges. In the bundled
      benchmark it uses about a twelfth of the memory of `:sorted` (~50 vs ~600
      bytes per key for 200,000 `"word_<n>_suffix"` keys). It is faster for
      writes, `auto_complete/3` and `count_prefix/2`; point lookups (`fetch/2`,
      `get/3`, `prefix?/2`) are 20–35 ns slower.
    - `:sorted` stores one node per key byte with sorted child arrays; its
      structure is simpler and never splits or merges nodes.

    Both layouts give identical results for every operation.

  Raises `ArgumentError` for unknown options or layouts.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.count_prefix(trie, "")
      0
      iex> sorted = TrieHard.new(layout: :sorted)
      iex> TrieHard.insert(sorted, "card", 1)
      :ok
      iex> TrieHard.auto_complete(sorted, "ca")
      ["card"]
  """
  @spec new([{:layout, layout()}]) :: t()
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, layout: :radix)
    layout = opts[:layout]

    if layout not in @layouts do
      raise ArgumentError,
            "expected :layout to be one of #{inspect(@layouts)}, got: #{inspect(layout)}"
    end

    Native.new_trie(layout)
  end

  @doc """
  Inserts `value` (any term) under `key`, replacing an existing value.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "hello", "world")
      :ok
      iex> TrieHard.insert(trie, "config", %{timeout: 5000, retry: true})
      :ok
  """
  @spec insert(t(), key(), value()) :: :ok
  def insert(trie, key, value) when is_binary(key) do
    etf = :erlang.term_to_binary(value)

    trie |> Native.insert(key, etf) |> settle(:insert, :insert_dirty, [trie, key, etf])
  end

  @doc """
  Inserts every `{key, value}` pair from `entries` (any enumerable).

  Later pairs win over earlier ones with the same key. Pairs are sent to the NIF
  in chunks of at most #{@chunk_size} pairs or 1 MiB, so the write lock is never
  held for long. The operation is not atomic: an invalid element (not a
  `{binary, term}` tuple, or a key that is not UTF-8) raises `ArgumentError`;
  earlier chunks stay inserted, while entries in the invalid element's chunk,
  including those before it, are not inserted.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert_many(trie, %{"a" => 1, "b" => [2]})
      :ok
      iex> TrieHard.get(trie, "b")
      [2]
  """
  @spec insert_many(t(), Enumerable.t({key(), value()})) :: :ok
  def insert_many(trie, entries) do
    entries
    |> Stream.map(&encode_entry/1)
    |> chunk(fn {key, etf} -> byte_size(key) + byte_size(etf) end)
    |> Enum.each(&Native.insert_many(trie, &1))
  end

  defp encode_entry({key, value}) when is_binary(key), do: {key, :erlang.term_to_binary(value)}

  defp encode_entry(other) do
    raise ArgumentError,
          "expected a {key, value} tuple with a binary key, got: #{inspect(other)}"
  end

  @doc """
  Returns `{:ok, value}` for an exact key match, or `{:error, :not_found}`.

  Use this when stored values may be `nil` (or your default): unlike `get/3`,
  it tells a stored value apart from a missing key.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "data", {:ok, %{id: 123}})
      :ok
      iex> TrieHard.fetch(trie, "data")
      {:ok, {:ok, %{id: 123}}}
      iex> TrieHard.insert(trie, "nothing", nil)
      :ok
      iex> TrieHard.fetch(trie, "nothing")
      {:ok, nil}
      iex> TrieHard.fetch(trie, "missing")
      {:error, :not_found}
  """
  @spec fetch(t(), key()) :: {:ok, value()} | {:error, :not_found}
  def fetch(trie, key) when is_binary(key) do
    case trie |> Native.get(key) |> settle(:get, :get_dirty, [trie, key]) do
      {:ok, etf} -> {:ok, :erlang.binary_to_term(etf, [:safe])}
      :self_key -> {:ok, key}
      :not_found -> {:error, :not_found}
    end
  end

  @doc """
  Returns the value stored under `key`, or `default` (`nil` unless given) when
  the key is missing.

  Like `Map.get/3`, a stored `default` and a missing key look the same; use
  `fetch/2` to tell them apart.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "hello", "world")
      :ok
      iex> TrieHard.get(trie, "hello")
      "world"
      iex> TrieHard.get(trie, "missing")
      nil
      iex> TrieHard.get(trie, "missing", "fallback")
      "fallback"
  """
  @spec get(t(), key(), default) :: value() | default when default: term()
  def get(trie, key, default \\ nil) when is_binary(key) do
    case fetch(trie, key) do
      {:ok, value} -> value
      {:error, :not_found} -> default
    end
  end

  @doc """
  Removes `key`. Returns `:ok` if it was present, `{:error, :not_found}` otherwise.

  Keys that share a prefix with `key` are unaffected.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "hello", "world")
      :ok
      iex> TrieHard.delete(trie, "hello")
      :ok
      iex> TrieHard.delete(trie, "hello")
      {:error, :not_found}
  """
  @spec delete(t(), key()) :: :ok | {:error, :not_found}
  def delete(trie, key) when is_binary(key) do
    case trie |> Native.delete(key) |> settle(:delete, :delete_dirty, [trie, key]) do
      true -> :ok
      false -> {:error, :not_found}
    end
  end

  @doc """
  Returns whether at least one stored key starts with `prefix`.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "cat", "feline")
      :ok
      iex> TrieHard.prefix?(trie, "ca")
      true
      iex> TrieHard.prefix?(trie, "dog")
      false
  """
  @spec prefix?(t(), String.t()) :: boolean()
  def prefix?(trie, prefix) when is_binary(prefix) do
    trie
    |> Native.prefix_search(prefix)
    |> settle(:prefix_search, :prefix_search_dirty, [trie, prefix])
  end

  @doc """
  Returns up to `max_results` (default 10) stored keys starting with `prefix`.

  Keys come back in lexicographic (codepoint) order; when there are more
  matches than `max_results`, the first ones in that order are returned.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.add_word_list(trie, ["cat", "car", "card"])
      :ok
      iex> TrieHard.auto_complete(trie, "ca", 2)
      ["car", "card"]
      iex> TrieHard.auto_complete(trie, "ca")
      ["car", "card", "cat"]
  """
  @spec auto_complete(t(), String.t(), non_neg_integer()) :: [String.t()]
  def auto_complete(trie, prefix, max_results \\ 10)
      when is_binary(prefix) and is_integer(max_results) and max_results >= 0 do
    limit = min(max_results, @max_results_cap)

    trie
    |> Native.auto_complete(prefix, limit)
    |> settle(:auto_complete, :auto_complete_dirty, [trie, prefix, limit])
  end

  @doc """
  Inserts each word from `words` (any enumerable) with itself as the value.

  Words are sent to the NIF in chunks of at most #{@chunk_size} words or 1 MiB,
  so the write lock is never held for long; readers interleave between chunks.
  The operation is not atomic: if an element is not a UTF-8 binary,
  `ArgumentError` is raised; earlier chunks stay inserted, while words in the
  invalid element's chunk, including those before it, are not inserted.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.add_word_list(trie, ["cat", "car", "card"])
      :ok
      iex> TrieHard.get(trie, "cat")
      "cat"
  """
  @spec add_word_list(t(), Enumerable.t(String.t())) :: :ok
  def add_word_list(trie, words) do
    words
    |> chunk(fn word -> if is_binary(word), do: byte_size(word), else: 0 end)
    |> Enum.each(&Native.add_word_list(trie, &1))
  end

  # Groups entries into chunks of at most @chunk_size entries or @chunk_bytes
  # bytes (a single larger entry is its own chunk).
  defp chunk(entries, size_fun) do
    Stream.chunk_while(
      entries,
      {[], 0, 0},
      fn entry, {acc, count, bytes} ->
        acc = [entry | acc]
        count = count + 1
        bytes = bytes + size_fun.(entry)

        if count >= @chunk_size or bytes >= @chunk_bytes do
          {:cont, Enum.reverse(acc), {[], 0, 0}}
        else
          {:cont, {acc, count, bytes}}
        end
      end,
      fn
        {[], _, _} -> {:cont, {[], 0, 0}}
        {acc, _, _} -> {:cont, Enum.reverse(acc), {[], 0, 0}}
      end
    )
  end

  @doc """
  Returns the exact number of stored keys starting with `prefix`.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.add_word_list(trie, ["cat", "car", "card", "dog"])
      :ok
      iex> TrieHard.count_prefix(trie, "ca")
      3
      iex> TrieHard.count_prefix(trie, "")
      4
  """
  @spec count_prefix(t(), String.t()) :: non_neg_integer()
  def count_prefix(trie, prefix) when is_binary(prefix) do
    trie
    |> Native.count_prefix(prefix)
    |> settle(:count_prefix, :count_prefix_dirty, [trie, prefix])
  end

  # Fast NIFs run on the calling (normal) scheduler and never block:
  #
  #   * `:dirty` - the work exceeds the fast-path bounds; run the twin on a
  #     dirty CPU scheduler.
  #   * `:busy` - a writer holds the lock; yield, then retry the fast NIF, so
  #     waiting readers don't occupy dirty schedulers (which the writer's own
  #     bulk calls need). Only after ~50 ms of retries fall back to the
  #     blocking twin.
  @busy_yields 16
  @busy_retries 64

  # The fast NIF is called directly by each function; only the rare `:dirty` /
  # `:busy` outcomes go through a dynamic `apply/3`.
  defp settle(result, fast, dirty, args, attempt \\ 0)

  defp settle(:dirty, _fast, dirty, args, _attempt), do: apply(Native, dirty, args)

  defp settle(:busy, fast, dirty, args, attempt) when attempt < @busy_retries do
    if attempt < @busy_yields, do: :erlang.yield(), else: Process.sleep(1)
    settle(apply(Native, fast, args), fast, dirty, args, attempt + 1)
  end

  defp settle(:busy, _fast, dirty, args, _attempt), do: apply(Native, dirty, args)
  defp settle(result, _fast, _dirty, _args, _attempt), do: result
end
