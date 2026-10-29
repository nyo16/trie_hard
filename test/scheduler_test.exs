defmodule TrieHard.SchedulerTest do
  # The system monitor is VM-global, so this module must not run concurrently
  # with itself; other modules' processes are filtered out below.
  use ExUnit.Case, async: false

  # An integration check for gross stalls (before fast/dirty NIF pairs, a
  # similar load stalled normal schedulers for up to 564 ms). The exact
  # fast-path bounds are pinned by the `:dirty` contract tests in
  # trie_hard_test.exs. 100 ms stays clear of GC pauses in test processes.
  @threshold_ms 100

  for layout <- [:sorted, :radix] do
    test "#{layout}: no trie call blocks a normal scheduler during a contended bulk load" do
      trie = TrieHard.new(layout: unquote(layout))
      long = String.duplicate("x", 300_000)
      words = for i <- 1..200_000, do: "w#{i}"

      previous = :erlang.system_monitor(self(), [{:long_schedule, @threshold_ms}])
      on_exit(fn -> restore(previous) end)

      writer = Task.async(fn -> TrieHard.add_word_list(trie, [long | words]) end)

      readers =
        for i <- 1..20 do
          Task.async(fn ->
            # One whole-trie traversal and one long-key copy per reader: both
            # must leave the normal scheduler; the rest are cheap fast calls.
            TrieHard.count_prefix(trie, "")
            TrieHard.auto_complete(trie, "x", 1)

            for _ <- 1..100 do
              TrieHard.fetch(trie, "w#{i}")
              TrieHard.auto_complete(trie, "w#{i}", 10)
              TrieHard.count_prefix(trie, "w#{i}0")
              TrieHard.insert(trie, "r#{i}", i)
            end
          end)
        end

      Task.await_many([writer | readers], 60_000)
      assert TrieHard.count_prefix(trie, "w") == 200_000
      assert TrieHard.count_prefix(trie, "") == 200_021

      ours = MapSet.new([self(), writer.pid | Enum.map(readers, & &1.pid)])

      stalls =
        collect_stalls()
        |> Enum.filter(fn {pid, _info} -> MapSet.member?(ours, pid) end)

      assert stalls == []
    end
  end

  defp collect_stalls(acc \\ []) do
    receive do
      {:monitor, pid, :long_schedule, info} when is_pid(pid) ->
        collect_stalls([{pid, info} | acc])
    after
      0 -> acc
    end
  end

  defp restore(:undefined), do: :erlang.system_monitor(:undefined)
  defp restore({pid, options}), do: :erlang.system_monitor(pid, options)
end
