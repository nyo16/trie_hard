# Run with:
#
#     MIX_ENV=bench TRIE_HARD_BUILD=true mix run bench/trie_bench.exs
#
# The :bench environment compiles the NIF in release mode (dev/test use debug).
# Data is deterministic: keys are "word_<n>_suffix".

defmodule TrieBench do
  @memory_words 200_000

  def words(range), do: Enum.map(range, &"word_#{&1}_suffix")

  def build(words) do
    trie = TrieHard.new()
    :ok = TrieHard.add_word_list(trie, words)
    trie
  end

  @doc "Resident set size delta per key after loading #{@memory_words} keys."
  def bytes_per_word do
    words = words(1..@memory_words)
    :erlang.garbage_collect()
    before = rss()
    trie = build(words)
    :erlang.garbage_collect()
    loaded = rss()
    {:ok, @memory_words} = TrieHard.count_prefix(trie, "word_")
    div(loaded - before, @memory_words)
  end

  defp rss do
    {out, 0} = System.cmd("ps", ["-o", "rss=", "-p", System.pid()])
    out |> String.trim() |> String.to_integer() |> Kernel.*(1024)
  end
end

IO.puts("Memory: #{TrieBench.bytes_per_word()} bytes/word (RSS delta, 200k keys)\n")

batch = TrieBench.words(1..1_000)
trie = TrieBench.build(TrieBench.words(1..100_000))

Benchee.run(
  %{
    "insert/3 x1000 (fresh trie)" => fn ->
      t = TrieHard.new()
      Enum.each(batch, &TrieHard.insert(t, &1, &1))
    end,
    "add_word_list/2 x1000 (fresh trie)" => fn -> TrieHard.add_word_list(TrieHard.new(), batch) end,
    "get/2 hit" => fn -> {:ok, _} = TrieHard.get(trie, "word_54321_suffix") end,
    "get/2 miss" => fn -> {:not_found, nil} = TrieHard.get(trie, "word_54321_suffiy") end,
    "prefix_search/2" => fn -> {:ok, true} = TrieHard.prefix_search(trie, "word_5432") end,
    "auto_complete/3 10" => fn -> {:ok, _} = TrieHard.auto_complete(trie, "word_1", 10) end,
    "auto_complete/3 100" => fn -> {:ok, _} = TrieHard.auto_complete(trie, "word_1", 100) end,
    "count_prefix/2 (111 keys)" => fn -> {:ok, 111} = TrieHard.count_prefix(trie, "word_123") end,
    "count_prefix/2 (11,112 keys, dirty)" => fn ->
      {:ok, 11_112} = TrieHard.count_prefix(trie, "word_1")
    end
  },
  warmup: 0.5,
  time: 2,
  print: [fast_warning: false]
)
