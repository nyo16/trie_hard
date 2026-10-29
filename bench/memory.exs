# Prints resident-set bytes per key for one layout and one key set, measured in a
# fresh VM (RSS rarely shrinks, so layouts must not share a process).
#
#     MIX_ENV=bench TRIE_HARD_BUILD=true mix run bench/memory.exs sorted words
#
# Invoked by bench/trie_bench.exs for every layout/key-set combination.

[layout, keys] = System.argv()
n = 200_000

words =
  case keys do
    "words" -> for i <- 1..n, do: "word_#{i}_suffix"
    "urls" -> for i <- 1..n, do: "https://example.com/users/#{i * 7919}/profile/settings"
  end

rss = fn ->
  {out, 0} = System.cmd("ps", ["-o", "rss=", "-p", System.pid()])
  out |> String.trim() |> String.to_integer() |> Kernel.*(1024)
end

# Create the trie first so the NIF library is loaded before the baseline.
trie = TrieHard.new(layout: String.to_existing_atom(layout))
:erlang.garbage_collect()
before = rss.()
:ok = TrieHard.add_word_list(trie, words)
:erlang.garbage_collect()
loaded = rss.()
^n = TrieHard.count_prefix(trie, "")

IO.puts(div(loaded - before, n))
