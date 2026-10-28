defmodule TrieHardTest do
  use ExUnit.Case
  doctest TrieHard

  describe "basic operations" do
    test "creates a new trie" do
      trie = TrieHard.new()
      assert is_reference(trie)
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
      assert TrieHard.get(trie, "hello") == {:ok, "world"}

      assert TrieHard.delete(trie, "hello") == :ok
      assert TrieHard.get(trie, "hello") == {:not_found, nil}
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
    end

    test "prefix search returns false for non-existing prefixes", %{trie: trie} do
      assert TrieHard.prefix_search(trie, "xyz") == {:ok, false}
      assert TrieHard.prefix_search(trie, "bat") == {:ok, false}
    end

    test "auto complete returns matching words", %{trie: trie} do
      {:ok, results} = TrieHard.auto_complete(trie, "ca", 10)

      # Results should contain words starting with "ca"
      assert is_list(results)
      # at least "car", "card", "care", "cat"
      assert length(results) >= 3

      # All results should start with "ca"
      Enum.each(results, fn word ->
        assert String.starts_with?(word, "ca")
      end)
    end

    test "auto complete respects max results limit", %{trie: trie} do
      {:ok, results} = TrieHard.auto_complete(trie, "ca", 2)

      assert is_list(results)
      assert length(results) <= 2
    end

    test "auto complete with empty prefix", %{trie: trie} do
      {:ok, results} = TrieHard.auto_complete(trie, "", 10)

      # Should return all words
      assert is_list(results)
      assert length(results) == 5
    end

    test "count_prefix returns correct counts", %{trie: trie} do
      # car, card, care, cat
      assert TrieHard.count_prefix(trie, "ca") == {:ok, 4}
      # car, card, care
      assert TrieHard.count_prefix(trie, "car") == {:ok, 3}
      # dog
      assert TrieHard.count_prefix(trie, "do") == {:ok, 1}
      # none
      assert TrieHard.count_prefix(trie, "xyz") == {:ok, 0}
    end
  end

  describe "batch operations" do
    test "add_word_list inserts multiple words" do
      trie = TrieHard.new()
      words = ["apple", "application", "apply", "banana", "band"]

      assert TrieHard.add_word_list(trie, words) == :ok

      # Each word should be inserted with itself as value
      Enum.each(words, fn word ->
        assert TrieHard.get(trie, word) == {:ok, word}
      end)
    end

    test "add_word_list with empty list" do
      trie = TrieHard.new()

      assert TrieHard.add_word_list(trie, []) == :ok
    end

    test "add_word_list enables autocomplete" do
      trie = TrieHard.new()
      words = ["apple", "application", "apply", "banana", "band"]

      assert TrieHard.add_word_list(trie, words) == :ok

      {:ok, results} = TrieHard.auto_complete(trie, "app", 10)
      # apple, application, apply
      assert length(results) == 3

      {:ok, results} = TrieHard.auto_complete(trie, "ban", 10)
      # banana, band
      assert length(results) == 2
    end
  end

  describe "edge cases and error handling" do
    test "handles empty strings" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "", "empty") == :ok
      assert TrieHard.get(trie, "") == {:ok, "empty"}

      assert TrieHard.prefix_search(trie, "") == {:ok, true}
    end

    test "handles unicode characters" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "café", "coffee") == :ok
      assert TrieHard.insert(trie, "naïve", "innocent") == :ok
      assert TrieHard.insert(trie, "🦀", "crab") == :ok

      assert TrieHard.get(trie, "café") == {:ok, "coffee"}
      assert TrieHard.get(trie, "naïve") == {:ok, "innocent"}
      assert TrieHard.get(trie, "🦀") == {:ok, "crab"}

      {:ok, results} = TrieHard.auto_complete(trie, "caf", 5)
      assert "café" in results
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
      assert TrieHard.get(trie, "key") == {:ok, "value1"}

      assert TrieHard.insert(trie, "key", "value2") == :ok
      assert TrieHard.get(trie, "key") == {:ok, "value2"}
    end

    test "delete non-existing key doesn't error" do
      trie = TrieHard.new()

      assert TrieHard.delete(trie, "non-existing") == :ok
    end

    test "handles large datasets efficiently" do
      trie = TrieHard.new()

      # Insert 1000 words
      words = for i <- 1..1000, do: "word#{i}"
      assert TrieHard.add_word_list(trie, words) == :ok

      # Test random access
      assert TrieHard.get(trie, "word500") == {:ok, "word500"}
      assert TrieHard.get(trie, "word999") == {:ok, "word999"}

      # Test prefix search
      assert TrieHard.prefix_search(trie, "word1") == {:ok, true}

      # Test autocomplete with limits
      {:ok, results} = TrieHard.auto_complete(trie, "word1", 20)
      assert length(results) <= 20
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

    test "auto_complete rejects a negative limit" do
      assert_raise FunctionClauseError, fn ->
        TrieHard.auto_complete(TrieHard.new(), "x", -1)
      end
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

  describe "concurrent access" do
    test "multiple processes can access same trie safely" do
      trie = TrieHard.new()

      # Insert initial data
      TrieHard.insert(trie, "shared", "data")

      # Spawn multiple processes to access the trie
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            TrieHard.insert(trie, "process#{i}", "data#{i}")
            TrieHard.get(trie, "shared")
          end)
        end

      # Wait for all tasks and collect results
      results = Task.await_many(tasks)

      # All should successfully read the shared data
      Enum.each(results, fn result ->
        assert result == {:ok, "data"}
      end)

      # Verify all individual inserts worked
      for i <- 1..10 do
        assert TrieHard.get(trie, "process#{i}") == {:ok, "data#{i}"}
      end
    end
  end
end
