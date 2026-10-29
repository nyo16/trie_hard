defmodule TrieHard.SchedulerTest do
  # The system monitor is VM-global, so this module must not run concurrently
  # with itself; other processes are filtered out below.
  use ExUnit.Case, async: false

  # Only the reader processes are monitored: their trie calls are the ones
  # that run on normal schedulers. Each fast call is bounded far below this
  # (≲1 ms in a debug build); an unbounded one on this trie takes tens of ms
  # (a whole-trie count in :sorted ≈ 35 ms). Long-schedule reports are not
  # produced for dirty schedulers.
  @threshold_ms 20

  for layout <- [:sorted, :radix] do
    test "#{layout}: no trie call blocks a normal scheduler, during or after a bulk load" do
      trie = TrieHard.new(layout: unquote(layout))
      parent = self()

      writer =
        Task.async(fn ->
          words = for i <- 1..200_000, do: "w#{i}"
          TrieHard.add_word_list(trie, [String.duplicate("x", 300_000) | words])
        end)

      readers =
        for i <- 1..20 do
          Task.async(fn ->
            receive do: (:monitoring -> :ok)

            for _ <- 1..100 do
              TrieHard.fetch(trie, "w#{i}")
              TrieHard.auto_complete(trie, "w#{i}", 10)
              TrieHard.count_prefix(trie, "w#{i}0")
              TrieHard.insert(trie, "r#{i}", i)
            end

            send(parent, {:loop_done, self()})
            receive do: (:loaded -> :ok)

            # On the full trie: a whole-trie traversal and a 300 KB key copy.
            TrieHard.count_prefix(trie, "")
            TrieHard.auto_complete(trie, "x", 1)
          end)
        end

      previous = :erlang.system_monitor(self(), [{:long_schedule, @threshold_ms}])
      on_exit(fn -> restore(previous) end)
      Enum.each(readers, &send(&1.pid, :monitoring))

      for %{pid: pid} <- readers, do: assert_receive({:loop_done, ^pid}, 60_000)
      Task.await(writer, 60_000)
      Enum.each(readers, &send(&1.pid, :loaded))
      Task.await_many(readers, 60_000)

      assert TrieHard.count_prefix(trie, "w") == 200_000
      assert TrieHard.count_prefix(trie, "") == 200_021

      monitored = MapSet.new(readers, & &1.pid)

      stalls =
        collect_stalls()
        |> Enum.filter(fn {pid, _info} -> MapSet.member?(monitored, pid) end)

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
