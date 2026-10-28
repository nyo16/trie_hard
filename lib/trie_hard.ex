defmodule TrieHard do
  @moduledoc """
  A fast, memory-efficient trie (prefix tree) with autocomplete, implemented as a
  Rust NIF.

  ## Features

  - **Fast**: sub-microsecond lookups and prefix checks
  - **Compact**: shared prefixes; two node layouts (see `new/1`)
  - **Deterministic**: `auto_complete/3` returns keys in lexicographic order
  - **Unicode**: keys are UTF-8 strings; non-binary keys raise `FunctionClauseError`,
    invalid UTF-8 raises `ArgumentError`
  - **Any value**: values are arbitrary Erlang terms
  - **Concurrent**: see "Concurrency" below

  ## Example

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "cat", :feline)
      :ok
      iex> TrieHard.insert_many(trie, [{"car", %{wheels: 4}}, {"card", {"payment", "plastic"}}])
      :ok
      iex> TrieHard.get(trie, "cat")
      {:ok, :feline}
      iex> TrieHard.get(trie, "dog")
      :error
      iex> TrieHard.auto_complete(trie, "ca", 10)
      ["car", "card", "cat"]
      iex> TrieHard.count_prefix(trie, "car")
      2

  ## Concurrency

  A trie can be shared by any number of processes. Reads run concurrently and
  writes are exclusive (a read-write lock). Each call first runs on the calling
  scheduler without blocking; when the trie is locked by a writer, the key is
  longer than 4 KiB, the value is larger than 64 KiB, or a traversal needs more
  than 10,000 node visits, it is transparently retried on a dirty CPU scheduler.
  `add_word_list/2` and `insert_many/2` always run on a dirty scheduler, in chunks
  of 1,000 entries.

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

  # Entries per bulk NIF call; bounds how long the write lock is held.
  @chunk_size 1_000

  @doc """
  Creates a new empty trie.

  ## Options

  - `:layout` - `:radix` (default) or `:sorted`.
    - `:radix` is path-compressed: a run of bytes without branches is a single
      node, so inserts and deletes may split or merge edges. In the bundled
      benchmark it uses about a tenth of the memory of `:sorted` (75 vs 764
      bytes per key for 200,000 `"word_<n>_suffix"` keys) and is as fast or
      faster for every operation except `prefix?/2` (~15 ns slower).
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

    trie
    |> Native.insert(key, etf)
    |> fast_or_dirty(fn -> Native.insert_dirty(trie, key, etf) end)
  end

  @doc """
  Inserts every `{key, value}` pair from `entries` (any enumerable).

  Later pairs win over earlier ones with the same key. Pairs are sent to the NIF
  in chunks of #{@chunk_size}, so the write lock is never held for long. The
  operation is not atomic: an invalid element (not a `{binary, term}` tuple, or
  a key that is not UTF-8) raises `ArgumentError`, and the chunks before it stay
  inserted.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert_many(trie, %{"a" => 1, "b" => [2]})
      :ok
      iex> TrieHard.get(trie, "b")
      {:ok, [2]}
  """
  @spec insert_many(t(), Enumerable.t({key(), value()})) :: :ok
  def insert_many(trie, entries) do
    entries
    |> Stream.map(&encode_entry/1)
    |> Stream.chunk_every(@chunk_size)
    |> Enum.each(&Native.insert_many(trie, &1))
  end

  defp encode_entry({key, value}) when is_binary(key), do: {key, :erlang.term_to_binary(value)}

  defp encode_entry(other) do
    raise ArgumentError,
          "expected a {key, value} tuple with a binary key, got: #{inspect(other)}"
  end

  @doc """
  Returns `{:ok, value}` for an exact key match, or `:error`.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "data", {:ok, %{id: 123}})
      :ok
      iex> TrieHard.get(trie, "data")
      {:ok, {:ok, %{id: 123}}}
      iex> TrieHard.get(trie, "missing")
      :error
  """
  @spec get(t(), key()) :: {:ok, value()} | :error
  def get(trie, key) when is_binary(key) do
    trie
    |> Native.get(key)
    |> fast_or_dirty(fn -> Native.get_dirty(trie, key) end)
    |> case do
      {:ok, etf} -> {:ok, :erlang.binary_to_term(etf, [:safe])}
      :self_key -> {:ok, key}
      :not_found -> :error
    end
  end

  @doc """
  Removes `key`. Returns `:ok` if it was present, `:error` otherwise.

  Keys that share a prefix with `key` are unaffected.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "hello", "world")
      :ok
      iex> TrieHard.delete(trie, "hello")
      :ok
      iex> TrieHard.delete(trie, "hello")
      :error
  """
  @spec delete(t(), key()) :: :ok | :error
  def delete(trie, key) when is_binary(key) do
    trie
    |> Native.delete(key)
    |> fast_or_dirty(fn -> Native.delete_dirty(trie, key) end)
    |> if(do: :ok, else: :error)
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
    |> fast_or_dirty(fn -> Native.prefix_search_dirty(trie, prefix) end)
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
    trie
    |> Native.auto_complete(prefix, max_results)
    |> fast_or_dirty(fn -> Native.auto_complete_dirty(trie, prefix, max_results) end)
  end

  @doc """
  Inserts each word with itself as the value.

  Words are sent to the NIF in chunks of #{@chunk_size} so the write lock is never
  held for long; readers interleave between chunks. The operation is not atomic:
  if an element is not a UTF-8 binary, `ArgumentError` is raised and the chunks
  before it stay inserted.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.add_word_list(trie, ["cat", "car", "card"])
      :ok
      iex> TrieHard.get(trie, "cat")
      {:ok, "cat"}
  """
  @spec add_word_list(t(), [String.t()]) :: :ok
  def add_word_list(trie, words) when is_list(words) do
    words
    |> Stream.chunk_every(@chunk_size)
    |> Enum.each(&Native.add_word_list(trie, &1))
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
    |> fast_or_dirty(fn -> Native.count_prefix_dirty(trie, prefix) end)
  end

  # Fast NIFs run on the calling (normal) scheduler and return `:dirty` instead of
  # blocking on a contended lock or doing unbounded work; the twin runs on a dirty
  # CPU scheduler.
  defp fast_or_dirty(:dirty, dirty_fun), do: dirty_fun.()
  defp fast_or_dirty(result, _dirty_fun), do: result
end
