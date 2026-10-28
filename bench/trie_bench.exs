# Run with:
#
#     MIX_ENV=bench TRIE_HARD_BUILD=true mix run bench/trie_bench.exs
#
# The :bench environment compiles the NIF in release mode (dev/test use debug).
# Data is deterministic: keys are "word_<n>_suffix". Every scenario runs once per
# layout (Benchee inputs); memory is measured per layout in a fresh VM by
# bench/memory.exs, for short shared-prefix keys ("words") and long URL-like keys.

layouts = [:sorted, :radix]

IO.puts("Memory, bytes per key (RSS delta, 200k keys):")

for keys <- ["words", "urls"], layout <- layouts do
  {out, 0} = System.cmd("mix", ["run", "bench/memory.exs", "#{layout}", keys])
  IO.puts("  #{String.pad_trailing(keys, 6)} #{String.pad_trailing("#{layout}", 7)} #{String.trim(out)}")
end

IO.puts("")

words = fn range -> Enum.map(range, &"word_#{&1}_suffix") end
batch = words.(1..1_000)
pairs = Enum.map(batch, &{&1, &1})

build = fn layout ->
  trie = TrieHard.new(layout: layout)
  :ok = TrieHard.add_word_list(trie, words.(1..100_000))
  trie
end

inputs = Map.new(layouts, &{"#{&1}", {&1, build.(&1)}})

Benchee.run(
  %{
    "insert/3 x1000 (fresh trie)" => fn {layout, _} ->
      t = TrieHard.new(layout: layout)
      Enum.each(batch, &TrieHard.insert(t, &1, &1))
    end,
    "insert_many/2 x1000 (fresh trie)" => fn {layout, _} ->
      TrieHard.insert_many(TrieHard.new(layout: layout), pairs)
    end,
    "add_word_list/2 x1000 (fresh trie)" => fn {layout, _} ->
      TrieHard.add_word_list(TrieHard.new(layout: layout), batch)
    end,
    "delete/2 + insert/3" => fn {_, trie} ->
      :ok = TrieHard.delete(trie, "word_54321_suffix")
      :ok = TrieHard.insert(trie, "word_54321_suffix", 1)
    end,
    "get/2 hit" => fn {_, trie} -> {:ok, _} = TrieHard.get(trie, "word_54321_suffix") end,
    "get/2 miss" => fn {_, trie} -> :error = TrieHard.get(trie, "word_54321_suffiy") end,
    "prefix?/2" => fn {_, trie} -> true = TrieHard.prefix?(trie, "word_5432") end,
    "auto_complete/3 10" => fn {_, trie} -> TrieHard.auto_complete(trie, "word_1", 10) end,
    "auto_complete/3 100" => fn {_, trie} -> TrieHard.auto_complete(trie, "word_1", 100) end,
    "count_prefix/2 (111 keys)" => fn {_, trie} -> 111 = TrieHard.count_prefix(trie, "word_123") end,
    "count_prefix/2 (11,112 keys)" => fn {_, trie} ->
      11_112 = TrieHard.count_prefix(trie, "word_1")
    end
  },
  inputs: inputs,
  warmup: 0.5,
  time: 2,
  print: [fast_warning: false]
)
