defmodule TrieHardTest do
  use ExUnit.Case, async: true
  doctest TrieHard

  describe "basic operations" do
    test "a new trie is empty" do
      trie = TrieHard.new()

      assert TrieHard.count_prefix(trie, "") == {:ok, 0}
      assert TrieHard.auto_complete(trie, "", 10) == {:ok, []}
      assert TrieHard.get(trie, "") == {:not_found, nil}
    end

    test "inserts and retrieves values" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "hello", "world") == :ok
      assert TrieHard.get(trie, "hello") == {:ok, "world"}
    end

    test "returns not_found for missing keys" do
      trie = TrieHard.new()

      assert TrieHard.get(trie, "missing") == {:not_found, nil}
    end

    test "deletes keys" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "hello", "world") == :ok
      assert TrieHard.delete(trie, "hello") == :ok
      assert TrieHard.get(trie, "hello") == {:not_found, nil}
      assert TrieHard.count_prefix(trie, "") == {:ok, 0}
    end

    test "deleting a key keeps keys that share its prefix" do
      trie = TrieHard.new()
      Enum.each(["car", "card", "cart"], &TrieHard.insert(trie, &1, &1))

      assert TrieHard.delete(trie, "car") == :ok
      assert TrieHard.auto_complete(trie, "car", 10) == {:ok, ["card", "cart"]}

      assert TrieHard.delete(trie, "card") == :ok
      assert TrieHard.auto_complete(trie, "", 10) == {:ok, ["cart"]}
      assert TrieHard.get(trie, "cart") == {:ok, "cart"}
    end

    test "handles multiple key-value pairs" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "cat", "feline") == :ok
      assert TrieHard.insert(trie, "car", "vehicle") == :ok
      assert TrieHard.insert(trie, "card", "payment") == :ok

      assert TrieHard.get(trie, "cat") == {:ok, "feline"}
      assert TrieHard.get(trie, "car") == {:ok, "vehicle"}
      assert TrieHard.get(trie, "card") == {:ok, "payment"}
    end
  end

  describe "prefix operations" do
    setup do
      trie = TrieHard.new()

      TrieHard.insert(trie, "cat", "feline")
      TrieHard.insert(trie, "car", "vehicle")
      TrieHard.insert(trie, "card", "payment")
      TrieHard.insert(trie, "care", "attention")
      TrieHard.insert(trie, "dog", "canine")

      {:ok, trie: trie}
    end

    test "prefix search finds existing prefixes", %{trie: trie} do
      assert TrieHard.prefix_search(trie, "ca") == {:ok, true}
      assert TrieHard.prefix_search(trie, "car") == {:ok, true}
      assert TrieHard.prefix_search(trie, "do") == {:ok, true}
      assert TrieHard.prefix_search(trie, "") == {:ok, true}
    end

    test "prefix search returns false for non-existing prefixes", %{trie: trie} do
      assert TrieHard.prefix_search(trie, "xyz") == {:ok, false}
      assert TrieHard.prefix_search(trie, "bat") == {:ok, false}
      assert TrieHard.prefix_search(trie, "cards") == {:ok, false}
    end

    test "auto complete returns every match in lexicographic order", %{trie: trie} do
      assert TrieHard.auto_complete(trie, "ca", 10) == {:ok, ["car", "card", "care", "cat"]}
    end

    test "auto complete returns the first matches in lexicographic order", %{trie: trie} do
      assert TrieHard.auto_complete(trie, "ca", 2) == {:ok, ["car", "card"]}
    end

    test "auto complete with a zero limit returns nothing", %{trie: trie} do
      assert TrieHard.auto_complete(trie, "ca", 0) == {:ok, []}
    end

    test "auto complete with empty prefix returns all words", %{trie: trie} do
      assert TrieHard.auto_complete(trie, "", 10) ==
               {:ok, ["car", "card", "care", "cat", "dog"]}
    end

    test "auto complete without a limit returns at most 10 words" do
      trie = TrieHard.new()
      words = for i <- 10..29, do: "w#{i}"
      TrieHard.add_word_list(trie, words)

      assert TrieHard.auto_complete(trie, "w") == {:ok, Enum.take(words, 10)}
    end

    test "auto complete order does not depend on insertion order" do
      words = ["cat", "car", "card", "care", "café", "dog", "ca"]
      forward = TrieHard.new()
      backward = TrieHard.new()
      Enum.each(words, &TrieHard.insert(forward, &1, 1))
      words |> Enum.reverse() |> Enum.each(&TrieHard.insert(backward, &1, 1))

      expected = {:ok, ["ca", "café", "car", "card", "care", "cat"]}
      assert TrieHard.auto_complete(forward, "ca", 10) == expected
      assert TrieHard.auto_complete(backward, "ca", 10) == expected
    end

    test "count_prefix returns correct counts", %{trie: trie} do
      assert TrieHard.count_prefix(trie, "ca") == {:ok, 4}
      assert TrieHard.count_prefix(trie, "car") == {:ok, 3}
      assert TrieHard.count_prefix(trie, "do") == {:ok, 1}
      assert TrieHard.count_prefix(trie, "xyz") == {:ok, 0}
    end
  end

  describe "batch operations" do
    test "add_word_list inserts multiple words with themselves as values" do
      trie = TrieHard.new()
      words = ["apple", "application", "apply", "banana", "band"]

      assert TrieHard.add_word_list(trie, words) == :ok

      for word <- words do
        assert TrieHard.get(trie, word) == {:ok, word}
      end
    end

    test "add_word_list with empty list" do
      trie = TrieHard.new()

      assert TrieHard.add_word_list(trie, []) == :ok
      assert TrieHard.count_prefix(trie, "") == {:ok, 0}
    end

    test "add_word_list enables autocomplete" do
      trie = TrieHard.new()
      words = ["apple", "application", "apply", "banana", "band"]

      assert TrieHard.add_word_list(trie, words) == :ok
      assert TrieHard.auto_complete(trie, "app", 10) == {:ok, ["apple", "application", "apply"]}
      assert TrieHard.auto_complete(trie, "ban", 10) == {:ok, ["banana", "band"]}
    end

    test "add_word_list with a non-string element raises and keeps earlier chunks" do
      trie = TrieHard.new()
      words = for(i <- 1..1_000, do: "w#{i}") ++ ["ok", :not_a_string]

      assert_raise ArgumentError, fn -> TrieHard.add_word_list(trie, words) end
      assert TrieHard.count_prefix(trie, "w") == {:ok, 1_000}
      assert TrieHard.get(trie, "ok") == {:not_found, nil}
    end
  end

  describe "edge cases" do
    test "handles empty strings" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "", "empty") == :ok
      assert TrieHard.get(trie, "") == {:ok, "empty"}
      assert TrieHard.prefix_search(trie, "") == {:ok, true}
      assert TrieHard.auto_complete(trie, "", 10) == {:ok, [""]}
    end

    test "handles unicode characters" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "café", "coffee") == :ok
      assert TrieHard.insert(trie, "naïve", "innocent") == :ok
      assert TrieHard.insert(trie, "🦀", "crab") == :ok

      assert TrieHard.get(trie, "café") == {:ok, "coffee"}
      assert TrieHard.get(trie, "naïve") == {:ok, "innocent"}
      assert TrieHard.get(trie, "🦀") == {:ok, "crab"}
      assert TrieHard.auto_complete(trie, "caf", 5) == {:ok, ["café"]}
      assert TrieHard.auto_complete(trie, "", 5) == {:ok, ["café", "naïve", "🦀"]}
    end

    test "handles very long strings" do
      trie = TrieHard.new()
      long_key = String.duplicate("a", 1000)
      long_value = String.duplicate("b", 1000)

      assert TrieHard.insert(trie, long_key, long_value) == :ok
      assert TrieHard.get(trie, long_key) == {:ok, long_value}
    end

    test "overwrites existing values" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "key", "value1") == :ok
      assert TrieHard.insert(trie, "key", "value2") == :ok
      assert TrieHard.get(trie, "key") == {:ok, "value2"}
      assert TrieHard.count_prefix(trie, "key") == {:ok, 1}
    end

    test "delete non-existing key doesn't error" do
      trie = TrieHard.new()
      TrieHard.insert(trie, "card", 1)

      assert TrieHard.delete(trie, "non-existing") == :ok
      assert TrieHard.delete(trie, "car") == :ok
      assert TrieHard.get(trie, "card") == {:ok, 1}
    end

    test "handles 1000 words" do
      trie = TrieHard.new()
      words = for i <- 1..1000, do: "word#{i}"

      assert TrieHard.add_word_list(trie, words) == :ok
      assert TrieHard.get(trie, "word500") == {:ok, "word500"}
      assert TrieHard.prefix_search(trie, "word1") == {:ok, true}
      assert TrieHard.count_prefix(trie, "word1") == {:ok, 112}

      expected = words |> Enum.filter(&String.starts_with?(&1, "word1")) |> Enum.sort()
      assert TrieHard.auto_complete(trie, "word1", 20) == {:ok, Enum.take(expected, 20)}
    end
  end

  describe "invalid arguments" do
    test "non-binary keys raise FunctionClauseError" do
      trie = TrieHard.new()

      for key <- [nil, :atom, 1, ~c"charlist"] do
        assert_raise FunctionClauseError, fn -> TrieHard.insert(trie, key, 1) end
        assert_raise FunctionClauseError, fn -> TrieHard.get(trie, key) end
        assert_raise FunctionClauseError, fn -> TrieHard.delete(trie, key) end
        assert_raise FunctionClauseError, fn -> TrieHard.prefix_search(trie, key) end
        assert_raise FunctionClauseError, fn -> TrieHard.auto_complete(trie, key, 1) end
        assert_raise FunctionClauseError, fn -> TrieHard.count_prefix(trie, key) end
      end
    end

    test "a handle that is not a trie raises ArgumentError" do
      for handle <- [make_ref(), nil, :trie] do
        assert_raise ArgumentError, fn -> TrieHard.get(handle, "k") end
        assert_raise ArgumentError, fn -> TrieHard.insert(handle, "k", 1) end
      end
    end

    test "non-UTF-8 keys raise ArgumentError" do
      trie = TrieHard.new()
      bad = <<0xFF, 0xFE>>

      assert_raise ArgumentError, fn -> TrieHard.insert(trie, bad, 1) end
      assert_raise ArgumentError, fn -> TrieHard.get(trie, bad) end
      assert_raise ArgumentError, fn -> TrieHard.auto_complete(trie, bad, 1) end
      assert_raise ArgumentError, fn -> TrieHard.add_word_list(trie, [bad]) end
    end

    test "auto_complete rejects a negative limit" do
      assert_raise FunctionClauseError, fn ->
        TrieHard.auto_complete(TrieHard.new(), "x", -1)
      end
    end
  end

  describe "regressions" do
    test "deleting non-ASCII keys works and leaves the trie usable" do
      trie = TrieHard.new()

      for key <- ["café", "🦀", "e\u0301"] do
        assert TrieHard.insert(trie, key, key) == :ok
        assert TrieHard.delete(trie, key) == :ok
        assert TrieHard.get(trie, key) == {:not_found, nil}
        assert TrieHard.insert(trie, key, "again") == :ok
        assert TrieHard.get(trie, key) == {:ok, "again"}
      end
    end

    test "count_prefix is exact beyond 64 matches" do
      trie = TrieHard.new()
      assert TrieHard.add_word_list(trie, for(i <- 1..1000, do: "word#{i}")) == :ok

      assert TrieHard.count_prefix(trie, "word") == {:ok, 1000}
      assert TrieHard.count_prefix(trie, "") == {:ok, 1000}
    end

    test "very deep keys do not overflow the scheduler stack" do
      trie = TrieHard.new()
      key = String.duplicate("a", 10_000)

      assert TrieHard.insert(trie, key, 1) == :ok
      assert TrieHard.auto_complete(trie, "", 1) == {:ok, [key]}
      assert TrieHard.count_prefix(trie, "a") == {:ok, 1}
      assert TrieHard.delete(trie, key) == :ok
      assert TrieHard.get(trie, key) == {:not_found, nil}
    end

    test "prefix_search on an empty trie is false" do
      assert TrieHard.prefix_search(TrieHard.new(), "") == {:ok, false}
    end
  end

  describe "values and bulk loads" do
    test "get after add_word_list returns the word" do
      trie = TrieHard.new()
      assert TrieHard.add_word_list(trie, ["alpha", "beta"]) == :ok
      assert TrieHard.get(trie, "alpha") == {:ok, "alpha"}
    end

    test "add_word_list overwrites a prior insert value" do
      trie = TrieHard.new()
      assert TrieHard.insert(trie, "alpha", %{v: 1}) == :ok
      assert TrieHard.add_word_list(trie, ["alpha"]) == :ok
      assert TrieHard.get(trie, "alpha") == {:ok, "alpha"}
    end

    test "large values round-trip" do
      trie = TrieHard.new()
      big = :binary.copy(<<1, 2, 3, 4>>, 2_500_000)
      deep = Enum.reduce(1..10_000, :leaf, fn i, acc -> %{i => acc} end)

      assert TrieHard.insert(trie, "big", big) == :ok
      assert TrieHard.insert(trie, "deep", deep) == :ok
      assert TrieHard.get(trie, "big") == {:ok, big}
      assert TrieHard.get(trie, "deep") == {:ok, deep}
    end

    test "keys longer than the fast-path limit work" do
      trie = TrieHard.new()
      key = String.duplicate("k", 5_000)

      assert TrieHard.insert(trie, key, :v) == :ok
      assert TrieHard.get(trie, key) == {:ok, :v}
      assert TrieHard.prefix_search(trie, key) == {:ok, true}
      assert TrieHard.count_prefix(trie, key) == {:ok, 1}
      assert TrieHard.auto_complete(trie, key, 5) == {:ok, [key]}
      assert TrieHard.delete(trie, key) == :ok
      assert TrieHard.get(trie, key) == {:not_found, nil}
    end
  end

  describe "concurrent access" do
    test "processes insert and read the same trie" do
      trie = TrieHard.new()
      TrieHard.insert(trie, "shared", "data")

      results =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn ->
            TrieHard.insert(trie, "process#{i}", "data#{i}")
            TrieHard.get(trie, "shared")
          end)
        end)
        |> Task.await_many()

      assert results == List.duplicate({:ok, "data"}, 10)

      for i <- 1..10 do
        assert TrieHard.get(trie, "process#{i}") == {:ok, "data#{i}"}
      end
    end

    test "readers complete while a writer bulk-loads" do
      trie = TrieHard.new()
      assert TrieHard.insert(trie, "shared", :data) == :ok
      words = for i <- 1..200_000, do: "w#{i}"

      writer = Task.async(fn -> TrieHard.add_word_list(trie, words) end)

      readers =
        1..50
        |> Task.async_stream(
          fn i ->
            for _ <- 1..20 do
              {:ok, :data} = TrieHard.get(trie, "shared")
              {:ok, found} = TrieHard.auto_complete(trie, "w#{i}", 5)
              true = Enum.all?(found, &String.starts_with?(&1, "w#{i}"))
            end

            :done
          end,
          max_concurrency: 50,
          timeout: 30_000
        )
        |> Enum.to_list()

      assert Task.await(writer, 30_000) == :ok
      assert readers == List.duplicate({:ok, :done}, 50)
      assert TrieHard.count_prefix(trie, "w") == {:ok, 200_000}
      assert TrieHard.get(trie, "w200000") == {:ok, "w200000"}
    end
  end
end
