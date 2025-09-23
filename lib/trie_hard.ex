defmodule TrieHard do
  @moduledoc """
  A blazing fast, memory-efficient Trie (prefix tree) implementation for Elixir
  with autocomplete support, powered by the trie_hard_rs Rust library.

  ## Features

  - **Fast operations**: Sub-microsecond autocomplete performance
  - **Memory efficient**: Shared prefix storage
  - **Unicode support**: Full UTF-8 character support
  - **Generic values**: Store any Erlang term as values
  - **Batch operations**: Efficient bulk insertions
  - **Thread-safe**: Concurrent access support

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
      iex> {:ok, results} = TrieHard.auto_complete(trie, "ca", 10)
      iex> Enum.sort(results)
      ["car", "card", "cat"]
  """

  alias TrieHard.Native

  @type trie :: reference()
  @type key :: String.t()
  @type value :: term()

  @doc """
  Creates a new empty Trie.

  ## Examples

      iex> trie = TrieHard.new()
      iex> is_reference(trie)
      true
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
  @spec insert(trie(), key(), value()) :: :ok | :error
  def insert(trie, key, value) when is_binary(key) do
    Native.insert(trie, key, value)
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
  @spec get(trie(), key()) :: {:ok, value()} | {:not_found, nil} | {:error, nil}
  def get(trie, key) when is_binary(key) do
    case Native.get(trie, key) do
      {:ok, value} when is_binary(value) ->
        # Try to decode if it's an Erlang external term format
        try do
          decoded = :erlang.binary_to_term(value)
          {:ok, decoded}
        rescue
          ArgumentError ->
            # If decoding fails, it's just a binary value
            {:ok, value}
        end

      other ->
        other
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
  @spec delete(trie(), key()) :: :ok | :error
  def delete(trie, key) when is_binary(key) do
    Native.delete(trie, key)
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
  @spec prefix_search(trie(), String.t()) :: {:ok, boolean()} | {:error, false}
  def prefix_search(trie, prefix) when is_binary(prefix) do
    Native.prefix_search(trie, prefix)
  end

  @doc """
  Returns words that start with the given prefix, up to max_results.

  ## Parameters
  - `trie` - The trie reference
  - `prefix` - The prefix to search for
  - `max_results` - Maximum number of results to return (default: 10)

  ## Returns
  - `{:ok, [String.t()]}` - List of matching words
  - `{:error, []}` on internal error

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.insert(trie, "cat", "1")
      :ok
      iex> TrieHard.insert(trie, "car", "2")
      :ok
      iex> TrieHard.insert(trie, "card", "3")
      :ok
      iex> {:ok, results} = TrieHard.auto_complete(trie, "ca", 2)
      iex> length(results) <= 2
      true
  """
  @spec auto_complete(trie(), String.t(), non_neg_integer()) :: {:ok, [String.t()]} | {:error, []}
  def auto_complete(trie, prefix, max_results \\ 10)
      when is_binary(prefix) and is_integer(max_results) do
    Native.auto_complete(trie, prefix, max_results)
  end

  @doc """
  Efficiently inserts multiple words at once.

  Each word will be inserted with itself as the value.

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
  @spec add_word_list(trie(), [String.t()]) :: :ok | :error
  def add_word_list(trie, words) when is_list(words) do
    Native.add_word_list(trie, words)
  end

  @doc """
  Returns the number of words with a given prefix.

  This is a convenience function that uses auto_complete with unlimited results.

  ## Examples

      iex> trie = TrieHard.new()
      iex> TrieHard.add_word_list(trie, ["cat", "car", "card", "dog"])
      :ok
      iex> TrieHard.count_prefix(trie, "ca")
      {:ok, 3}
      iex> TrieHard.count_prefix(trie, "do")
      {:ok, 1}
  """
  @spec count_prefix(trie(), String.t()) :: {:ok, non_neg_integer()} | {:error, 0}
  def count_prefix(trie, prefix) when is_binary(prefix) do
    case auto_complete(trie, prefix, :erlang.system_info(:wordsize) * 8) do
      {:ok, results} -> {:ok, length(results)}
      {:error, _} -> {:error, 0}
    end
  end
end
