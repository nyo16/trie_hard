defmodule TrieHard do
  @moduledoc """
  A fast, memory-efficient trie (prefix tree) with autocomplete, implemented as a
  Rust NIF.

  ## Features

  - **Fast**: sub-microsecond lookups and prefix checks
  - **Compact**: shared prefixes, byte-keyed nodes with sorted child arrays
  - **Deterministic**: `auto_complete/3` returns keys in lexicographic order
  - **Unicode**: keys are UTF-8 strings; non-binary keys raise `FunctionClauseError`,
    invalid UTF-8 raises `ArgumentError`
  - **Any value**: values are arbitrary Erlang terms
  - **Concurrent**: see "Concurrency" below

  ## Example

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "cat", :feline)
      :ok
      iex> TrieHard.insert(trie, "car", %{type: "vehicle", wheels: 4})
      :ok
      iex> TrieHard.insert(trie, "card", {"payment", "plastic"})
      :ok
      iex> TrieHard.get(trie, "cat")
      {:ok, :feline}
      iex> TrieHard.auto_complete(trie, "ca", 10)
      {:ok, ["car", "card", "cat"]}

  ## Concurrency

  A trie can be shared by any number of processes. Reads run concurrently and
  writes are exclusive (a read-write lock). Each call first runs on the calling
  scheduler without blocking; when the trie is locked by a writer, the key is
  longer than 4 KiB, the value is larger than 64 KiB, or a traversal needs more
  than 10,000 node visits, it is transparently retried on a dirty CPU scheduler.
  `add_word_list/2` always runs on a dirty scheduler, in chunks of 1,000 words.

  Values are encoded with `:erlang.term_to_binary/1` and decoded with
  `:erlang.binary_to_term/2` (`[:safe]`) in the calling process, never inside
  the NIF.

  ## Memory

  A trie lives in native memory owned by its reference. It is freed when the last
  reference is garbage collected, on whichever scheduler thread runs that GC;
  freeing a trie with millions of keys takes correspondingly long on that thread.
  """

  alias TrieHard.Native

  @type trie :: reference()
  @type key :: String.t()
  @type value :: term()

  # Words per add_word_list NIF call; bounds how long the write lock is held.
  @word_list_chunk 1_000

  @doc """
  Creates a new empty Trie.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.count_prefix(trie, "")
      {:ok, 0}
  """
  @spec new() :: trie()
  def new do
    Native.new_trie()
  end

  @doc """
  Inserts a key-value pair into the trie.

  ## Parameters
  - `trie` - The trie reference
  - `key` - The key to insert (string)
  - `value` - The value to associate with the key (any Erlang term)

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "hello", "world")
      :ok
      iex> TrieHard.insert(trie, "config", %{timeout: 5000, retry: true})
      :ok
      iex> TrieHard.insert(trie, "data", {:ok, [1, 2, 3]})
      :ok
  """
  @spec insert(trie(), key(), value()) :: :ok
  def insert(trie, key, value) when is_binary(key) do
    etf = :erlang.term_to_binary(value)

    trie
    |> Native.insert(key, etf)
    |> fast_or_dirty(fn -> Native.insert_dirty(trie, key, etf) end)
  end

  @doc """
  Retrieves a value by exact key match.

  ## Parameters
  - `trie` - The trie reference
  - `key` - The key to look up

  ## Returns
  - `{:ok, value}` if the key exists
  - `{:not_found, nil}` if the key doesn't exist
  - `{:error, nil}` on internal error

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "hello", "world")
      :ok
      iex> TrieHard.get(trie, "hello")
      {:ok, "world"}
      iex> TrieHard.insert(trie, "data", {:ok, %{id: 123}})
      :ok
      iex> TrieHard.get(trie, "data")
      {:ok, {:ok, %{id: 123}}}
      iex> TrieHard.get(trie, "missing")
      {:not_found, nil}
  """
  @spec get(trie(), key()) :: {:ok, value()} | {:not_found, nil}
  def get(trie, key) when is_binary(key) do
    trie
    |> Native.get(key)
    |> fast_or_dirty(fn -> Native.get_dirty(trie, key) end)
    |> case do
      {:ok, etf} -> {:ok, :erlang.binary_to_term(etf, [:safe])}
      :self_key -> {:ok, key}
      :not_found -> {:not_found, nil}
    end
  end

  @doc """
  Removes a key and its associated value from the trie.

  ## Parameters
  - `trie` - The trie reference
  - `key` - The key to remove

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "hello", "world")
      :ok
      iex> TrieHard.delete(trie, "hello")
      :ok
      iex> TrieHard.get(trie, "hello")
      {:not_found, nil}
  """
  @spec delete(trie(), key()) :: :ok
  def delete(trie, key) when is_binary(key) do
    trie
    |> Native.delete(key)
    |> fast_or_dirty(fn -> Native.delete_dirty(trie, key) end)

    :ok
  end

  @doc """
  Checks if any words in the trie start with the given prefix.

  ## Parameters
  - `trie` - The trie reference
  - `prefix` - The prefix to search for

  ## Returns
  - `{:ok, true}` if words with the prefix exist
  - `{:ok, false}` if no words with the prefix exist
  - `{:error, false}` on internal error

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "cat", "feline")
      :ok
      iex> TrieHard.prefix_search(trie, "ca")
      {:ok, true}
      iex> TrieHard.prefix_search(trie, "dog")
      {:ok, false}
  """
  @spec prefix_search(trie(), String.t()) :: {:ok, boolean()}
  def prefix_search(trie, prefix) when is_binary(prefix) do
    found =
      trie
      |> Native.prefix_search(prefix)
      |> fast_or_dirty(fn -> Native.prefix_search_dirty(trie, prefix) end)

    {:ok, found}
  end

  @doc """
  Returns words that start with the given prefix, up to max_results.

  ## Parameters
  - `trie` - The trie reference
  - `prefix` - The prefix to search for
  - `max_results` - Maximum number of results to return (default: 10)

  ## Returns
  - `{:ok, [String.t()]}` - up to `max_results` matching words, in lexicographic
    (codepoint) order; when there are more matches, the first ones in that order

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "cat", "1")
      :ok
      iex> TrieHard.insert(trie, "car", "2")
      :ok
      iex> TrieHard.insert(trie, "card", "3")
      :ok
      iex> TrieHard.auto_complete(trie, "ca", 2)
      {:ok, ["car", "card"]}
      iex> TrieHard.auto_complete(trie, "ca")
      {:ok, ["car", "card", "cat"]}
  """
  @spec auto_complete(trie(), String.t(), non_neg_integer()) :: {:ok, [String.t()]}
  def auto_complete(trie, prefix, max_results \\ 10)
      when is_binary(prefix) and is_integer(max_results) and max_results >= 0 do
    words =
      trie
      |> Native.auto_complete(prefix, max_results)
      |> fast_or_dirty(fn -> Native.auto_complete_dirty(trie, prefix, max_results) end)

    {:ok, words}
  end

  @doc """
  Efficiently inserts multiple words at once.

  Each word will be inserted with itself as the value. Words are sent to the NIF in
  chunks of #{@word_list_chunk} so the write lock is never held for long; readers
  interleave between chunks. The operation is not atomic: if an element is not a
  UTF-8 binary, `ArgumentError` is raised and the chunks before it stay inserted.

  ## Parameters
  - `trie` - The trie reference
  - `words` - List of words to insert

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.add_word_list(trie, ["cat", "car", "card"])
      :ok
      iex> TrieHard.get(trie, "cat")
      {:ok, "cat"}
  """
  @spec add_word_list(trie(), [String.t()]) :: :ok
  def add_word_list(trie, words) when is_list(words) do
    words
    |> Stream.chunk_every(@word_list_chunk)
    |> Enum.each(&Native.add_word_list(trie, &1))
  end

  @doc """
  Returns the number of words with a given prefix.

  Counts every stored key under `prefix`; the result is exact and not capped.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.add_word_list(trie, ["cat", "car", "card", "dog"])
      :ok
      iex> TrieHard.count_prefix(trie, "ca")
      {:ok, 3}
      iex> TrieHard.count_prefix(trie, "do")
      {:ok, 1}
  """
  @spec count_prefix(trie(), String.t()) :: {:ok, non_neg_integer()}
  def count_prefix(trie, prefix) when is_binary(prefix) do
    count =
      trie
      |> Native.count_prefix(prefix)
      |> fast_or_dirty(fn -> Native.count_prefix_dirty(trie, prefix) end)

    {:ok, count}
  end

  # Fast NIFs run on the calling (normal) scheduler and return `:dirty` instead of
  # blocking on a contended lock or doing unbounded work; the twin runs on a dirty
  # CPU scheduler.
  defp fast_or_dirty(:dirty, dirty_fun), do: dirty_fun.()
  defp fast_or_dirty(result, _dirty_fun), do: result
end
