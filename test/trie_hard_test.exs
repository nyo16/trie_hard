defmodule TrieHardTest do
  use ExUnit.Case, async: true
  doctest TrieHard

  alias TrieHard.Native

  @layouts [:sorted, :radix]

  describe "new/1" do
    test "rejects unknown layouts and options" do
      assert_raise ArgumentError, ~r/:layout/, fn -> TrieHard.new(layout: :hash) end
      assert_raise ArgumentError, fn -> TrieHard.new(bogus: true) end
    end
  end

  describe "invalid handles" do
    test "a handle that is not a trie raises ArgumentError in every NIF-backed function" do
      for handle <- [make_ref(), nil, :trie] do
        assert_raise ArgumentError, fn -> TrieHard.fetch(handle, "k") end
        assert_raise ArgumentError, fn -> TrieHard.insert(handle, "k", 1) end
        assert_raise ArgumentError, fn -> TrieHard.delete(handle, "k") end
        assert_raise ArgumentError, fn -> TrieHard.prefix?(handle, "k") end
        assert_raise ArgumentError, fn -> TrieHard.auto_complete(handle, "k") end
        assert_raise ArgumentError, fn -> TrieHard.count_prefix(handle, "k") end
        assert_raise ArgumentError, fn -> TrieHard.add_word_list(handle, ["k"]) end
        assert_raise ArgumentError, fn -> TrieHard.insert_many(handle, [{"k", 1}]) end
      end
    end
  end

  describe "layout cross-check" do
    test "both layouts return identical results for the same operation sequence" do
      :rand.seed(:exsss, {20, 26, 10})
      # é/è and 🦀/🦁 share leading UTF-8 bytes: radix edges split mid-character.
      alphabet = ["a", "b", "é", "è", "🦀", "🦁"]
      random_key = fn -> Enum.map_join(1..:rand.uniform(6), fn _ -> Enum.random(alphabet) end) end
      tries = Enum.map(@layouts, &TrieHard.new(layout: &1))

      for step <- 1..3_000 do
        key = random_key.()

        {op, call} =
          case :rand.uniform(7) do
            1 -> {:insert, &TrieHard.insert(&1, key, step)}
            2 -> {:delete, &TrieHard.delete(&1, key)}
            3 -> {:get, &TrieHard.fetch(&1, key)}
            4 -> {:count_prefix, &TrieHard.count_prefix(&1, key)}
            5 -> {:prefix?, &TrieHard.prefix?(&1, key)}
            6 -> {:auto_complete, &TrieHard.auto_complete(&1, String.slice(key, 0, 2), 5)}
            7 -> {:add_word_list, &TrieHard.add_word_list(&1, [key, "", String.reverse(key)])}
          end

        [sorted, radix] = Enum.map(tries, call)
        assert sorted == radix, "step #{step}: #{op}(#{inspect(key)}) diverged"
      end

      [sorted, radix] = Enum.map(tries, &TrieHard.auto_complete(&1, "", 10_000))
      assert sorted == radix
      assert sorted == Enum.sort(sorted)
    end
  end

  for layout <- @layouts do
    @layout layout

    describe "#{layout}: basic operations" do
      test "a new trie is empty" do
        trie = TrieHard.new(layout: @layout)

        assert TrieHard.count_prefix(trie, "") == 0
        assert TrieHard.auto_complete(trie, "", 10) == []
        assert TrieHard.fetch(trie, "") == {:error, :not_found}
      end

      test "inserts and retrieves values" do
        trie = TrieHard.new(layout: @layout)

        assert TrieHard.insert(trie, "hello", "world") == :ok
        assert TrieHard.fetch(trie, "hello") == {:ok, "world"}
      end

      test "fetch returns {:error, :not_found} for missing keys" do
        trie = TrieHard.new(layout: @layout)

        assert TrieHard.fetch(trie, "missing") == {:error, :not_found}
      end

      test "get returns the value, nil, or the given default" do
        trie = TrieHard.new(layout: @layout)
        TrieHard.insert(trie, "k", "v")
        TrieHard.insert(trie, "nil", nil)

        assert TrieHard.get(trie, "k") == "v"
        assert TrieHard.get(trie, "k", :default) == "v"
        assert TrieHard.get(trie, "missing") == nil
        assert TrieHard.get(trie, "missing", :default) == :default
        # A stored nil is a value: get/3 returns it, fetch/2 tells it apart.
        assert TrieHard.get(trie, "nil", :default) == nil
        assert TrieHard.fetch(trie, "nil") == {:ok, nil}
      end

      test "deletes keys" do
        trie = TrieHard.new(layout: @layout)

        assert TrieHard.insert(trie, "hello", "world") == :ok
        assert TrieHard.delete(trie, "hello") == :ok
        assert TrieHard.fetch(trie, "hello") == {:error, :not_found}
        assert TrieHard.count_prefix(trie, "") == 0
      end

      test "deleting a key keeps keys that share its prefix" do
        trie = TrieHard.new(layout: @layout)
        Enum.each(["car", "card", "cart"], &TrieHard.insert(trie, &1, &1))

        assert TrieHard.delete(trie, "car") == :ok
        assert TrieHard.auto_complete(trie, "car", 10) == ["card", "cart"]

        assert TrieHard.delete(trie, "card") == :ok
        assert TrieHard.auto_complete(trie, "", 10) == ["cart"]
        assert TrieHard.fetch(trie, "cart") == {:ok, "cart"}
      end

      test "handles multiple key-value pairs" do
        trie = TrieHard.new(layout: @layout)

        assert TrieHard.insert(trie, "cat", "feline") == :ok
        assert TrieHard.insert(trie, "car", "vehicle") == :ok
        assert TrieHard.insert(trie, "card", "payment") == :ok

        assert TrieHard.fetch(trie, "cat") == {:ok, "feline"}
        assert TrieHard.fetch(trie, "car") == {:ok, "vehicle"}
        assert TrieHard.fetch(trie, "card") == {:ok, "payment"}
      end
    end

    describe "#{layout}: prefix operations" do
      setup do
        trie = TrieHard.new(layout: @layout)

        TrieHard.insert(trie, "cat", "feline")
        TrieHard.insert(trie, "car", "vehicle")
        TrieHard.insert(trie, "card", "payment")
        TrieHard.insert(trie, "care", "attention")
        TrieHard.insert(trie, "dog", "canine")

        {:ok, trie: trie}
      end

      test "prefix search finds existing prefixes", %{trie: trie} do
        assert TrieHard.prefix?(trie, "ca")
        assert TrieHard.prefix?(trie, "car")
        assert TrieHard.prefix?(trie, "do")
        assert TrieHard.prefix?(trie, "")
      end

      test "prefix search returns false for non-existing prefixes", %{trie: trie} do
        refute TrieHard.prefix?(trie, "xyz")
        refute TrieHard.prefix?(trie, "bat")
        refute TrieHard.prefix?(trie, "cards")
      end

      test "auto complete returns every match in lexicographic order", %{trie: trie} do
        assert TrieHard.auto_complete(trie, "ca", 10) == ["car", "card", "care", "cat"]
      end

      test "auto complete returns the first matches in lexicographic order", %{trie: trie} do
        assert TrieHard.auto_complete(trie, "ca", 2) == ["car", "card"]
      end

      test "auto complete with a zero limit returns nothing", %{trie: trie} do
        assert TrieHard.auto_complete(trie, "ca", 0) == []
      end

      test "auto complete with empty prefix returns all words", %{trie: trie} do
        assert TrieHard.auto_complete(trie, "", 10) == ["car", "card", "care", "cat", "dog"]
      end

      test "auto complete without a limit returns at most 10 words" do
        trie = TrieHard.new(layout: @layout)
        words = for i <- 10..29, do: "w#{i}"
        TrieHard.add_word_list(trie, words)

        assert TrieHard.auto_complete(trie, "w") == Enum.take(words, 10)
      end

      test "auto complete order does not depend on insertion order" do
        words = ["cat", "car", "card", "care", "café", "dog", "ca"]
        forward = TrieHard.new(layout: @layout)
        backward = TrieHard.new(layout: @layout)
        Enum.each(words, &TrieHard.insert(forward, &1, 1))
        words |> Enum.reverse() |> Enum.each(&TrieHard.insert(backward, &1, 1))

        expected = ["ca", "café", "car", "card", "care", "cat"]
        assert TrieHard.auto_complete(forward, "ca", 10) == expected
        assert TrieHard.auto_complete(backward, "ca", 10) == expected
      end

      test "count_prefix returns correct counts", %{trie: trie} do
        assert TrieHard.count_prefix(trie, "ca") == 4
        assert TrieHard.count_prefix(trie, "car") == 3
        assert TrieHard.count_prefix(trie, "do") == 1
        assert TrieHard.count_prefix(trie, "xyz") == 0
      end
    end

    describe "#{layout}: batch operations" do
      test "add_word_list inserts multiple words with themselves as values" do
        trie = TrieHard.new(layout: @layout)
        words = ["apple", "application", "apply", "banana", "band"]

        assert TrieHard.add_word_list(trie, words) == :ok

        for word <- words do
          assert TrieHard.fetch(trie, word) == {:ok, word}
        end
      end

      test "add_word_list with empty list" do
        trie = TrieHard.new(layout: @layout)

        assert TrieHard.add_word_list(trie, []) == :ok
        assert TrieHard.count_prefix(trie, "") == 0
      end

      test "add_word_list enables autocomplete" do
        trie = TrieHard.new(layout: @layout)
        words = ["apple", "application", "apply", "banana", "band"]

        assert TrieHard.add_word_list(trie, words) == :ok
        assert TrieHard.auto_complete(trie, "app", 10) == ["apple", "application", "apply"]
        assert TrieHard.auto_complete(trie, "ban", 10) == ["banana", "band"]
      end

      test "add_word_list with a non-string element raises and keeps earlier chunks" do
        trie = TrieHard.new(layout: @layout)
        words = for(i <- 1..1_000, do: "w#{i}") ++ ["ok", :not_a_string]

        assert_raise ArgumentError, fn -> TrieHard.add_word_list(trie, words) end
        assert TrieHard.count_prefix(trie, "w") == 1_000
        assert TrieHard.fetch(trie, "ok") == {:error, :not_found}
      end

      test "bulk chunks are also bounded by bytes" do
        trie = TrieHard.new(layout: @layout)
        big = String.duplicate("b", 1_100_000)

        # `big` alone exceeds the 1 MiB chunk bound, so it is sent (and kept)
        # before the chunk holding the invalid element fails.
        assert_raise ArgumentError, fn -> TrieHard.add_word_list(trie, [big, "ok", :bad]) end
        assert TrieHard.fetch(trie, big) == {:ok, big}
        assert TrieHard.fetch(trie, "ok") == {:error, :not_found}

        assert_raise ArgumentError, fn ->
          TrieHard.insert_many(trie, [{"v", big}, {"ok", 1}, :bad])
        end

        assert TrieHard.fetch(trie, "v") == {:ok, big}
        assert TrieHard.fetch(trie, "ok") == {:error, :not_found}
      end

      test "add_word_list accepts any enumerable" do
        trie = TrieHard.new(layout: @layout)
        assert TrieHard.add_word_list(trie, Stream.map(1..3, &"s#{&1}")) == :ok
        assert TrieHard.add_word_list(trie, MapSet.new(["m"])) == :ok
        assert TrieHard.auto_complete(trie, "") == ["m", "s1", "s2", "s3"]
      end
    end

    describe "#{layout}: edge cases" do
      test "handles empty strings" do
        trie = TrieHard.new(layout: @layout)

        assert TrieHard.insert(trie, "", "empty") == :ok
        assert TrieHard.fetch(trie, "") == {:ok, "empty"}
        assert TrieHard.prefix?(trie, "")
        assert TrieHard.auto_complete(trie, "", 10) == [""]
      end

      test "handles unicode characters" do
        trie = TrieHard.new(layout: @layout)

        assert TrieHard.insert(trie, "café", "coffee") == :ok
        assert TrieHard.insert(trie, "naïve", "innocent") == :ok
        assert TrieHard.insert(trie, "🦀", "crab") == :ok

        assert TrieHard.fetch(trie, "café") == {:ok, "coffee"}
        assert TrieHard.fetch(trie, "naïve") == {:ok, "innocent"}
        assert TrieHard.fetch(trie, "🦀") == {:ok, "crab"}
        assert TrieHard.auto_complete(trie, "caf", 5) == ["café"]
        assert TrieHard.auto_complete(trie, "", 5) == ["café", "naïve", "🦀"]
      end

      test "handles very long strings" do
        trie = TrieHard.new(layout: @layout)
        long_key = String.duplicate("a", 1000)
        long_value = String.duplicate("b", 1000)

        assert TrieHard.insert(trie, long_key, long_value) == :ok
        assert TrieHard.fetch(trie, long_key) == {:ok, long_value}
      end

      test "overwrites existing values" do
        trie = TrieHard.new(layout: @layout)

        assert TrieHard.insert(trie, "key", "value1") == :ok
        assert TrieHard.insert(trie, "key", "value2") == :ok
        assert TrieHard.fetch(trie, "key") == {:ok, "value2"}
        assert TrieHard.count_prefix(trie, "key") == 1
      end

      test "delete returns {:error, :not_found} for absent keys and keeps the rest" do
        trie = TrieHard.new(layout: @layout)
        TrieHard.insert(trie, "card", 1)

        assert TrieHard.delete(trie, "non-existing") == {:error, :not_found}
        assert TrieHard.delete(trie, "car") == {:error, :not_found}
        assert TrieHard.delete(trie, "cards") == {:error, :not_found}
        assert TrieHard.fetch(trie, "card") == {:ok, 1}
        assert TrieHard.delete(trie, "card") == :ok
        assert TrieHard.delete(trie, "card") == {:error, :not_found}
      end

      test "handles 1000 words" do
        trie = TrieHard.new(layout: @layout)
        words = for i <- 1..1000, do: "word#{i}"

        assert TrieHard.add_word_list(trie, words) == :ok
        assert TrieHard.fetch(trie, "word500") == {:ok, "word500"}
        assert TrieHard.prefix?(trie, "word1")
        assert TrieHard.count_prefix(trie, "word1") == 112

        expected = words |> Enum.filter(&String.starts_with?(&1, "word1")) |> Enum.sort()
        assert TrieHard.auto_complete(trie, "word1", 20) == Enum.take(expected, 20)
      end
    end

    describe "#{layout}: invalid arguments" do
      test "non-binary keys raise FunctionClauseError" do
        trie = TrieHard.new(layout: @layout)

        for key <- [nil, :atom, 1, ~c"charlist"] do
          assert_raise FunctionClauseError, fn -> TrieHard.insert(trie, key, 1) end
          assert_raise FunctionClauseError, fn -> TrieHard.fetch(trie, key) end
          assert_raise FunctionClauseError, fn -> TrieHard.delete(trie, key) end
          assert_raise FunctionClauseError, fn -> TrieHard.prefix?(trie, key) end
          assert_raise FunctionClauseError, fn -> TrieHard.auto_complete(trie, key, 1) end
          assert_raise FunctionClauseError, fn -> TrieHard.count_prefix(trie, key) end
        end
      end

      test "non-UTF-8 keys raise ArgumentError" do
        trie = TrieHard.new(layout: @layout)
        bad = <<0xFF, 0xFE>>

        assert_raise ArgumentError, fn -> TrieHard.insert(trie, bad, 1) end
        assert_raise ArgumentError, fn -> TrieHard.fetch(trie, bad) end
        assert_raise ArgumentError, fn -> TrieHard.delete(trie, bad) end
        assert_raise ArgumentError, fn -> TrieHard.prefix?(trie, bad) end
        assert_raise ArgumentError, fn -> TrieHard.count_prefix(trie, bad) end
        assert_raise ArgumentError, fn -> TrieHard.auto_complete(trie, bad, 1) end
        assert_raise ArgumentError, fn -> TrieHard.add_word_list(trie, [bad]) end
        assert_raise ArgumentError, fn -> TrieHard.insert_many(trie, [{bad, 1}]) end
      end

      test "auto_complete rejects a negative limit" do
        assert_raise FunctionClauseError, fn ->
          TrieHard.auto_complete(TrieHard.new(layout: @layout), "x", -1)
        end
      end

      test "auto_complete accepts limits beyond 64 bits" do
        trie = TrieHard.new(layout: @layout)
        TrieHard.insert(trie, "a", 1)
        assert TrieHard.auto_complete(trie, "", 2 ** 70) == ["a"]
      end
    end

    describe "#{layout}: regressions" do
      test "deleting non-ASCII keys works and leaves the trie usable" do
        trie = TrieHard.new(layout: @layout)

        for key <- ["café", "🦀", "e\u0301"] do
          assert TrieHard.insert(trie, key, key) == :ok
          assert TrieHard.delete(trie, key) == :ok
          assert TrieHard.fetch(trie, key) == {:error, :not_found}
          assert TrieHard.insert(trie, key, "again") == :ok
          assert TrieHard.fetch(trie, key) == {:ok, "again"}
        end
      end

      test "count_prefix is exact beyond 64 matches" do
        trie = TrieHard.new(layout: @layout)
        assert TrieHard.add_word_list(trie, for(i <- 1..1000, do: "word#{i}")) == :ok

        assert TrieHard.count_prefix(trie, "word") == 1000
        assert TrieHard.count_prefix(trie, "") == 1000
      end

      test "a deep branching chain does not overflow the scheduler stack" do
        trie = TrieHard.new(layout: @layout)
        # "a", "aa", ..., one node per key in both layouts.
        keys = for n <- 1..3_000, do: String.duplicate("a", n)

        assert TrieHard.add_word_list(trie, keys) == :ok
        assert TrieHard.count_prefix(trie, "") == 3_000
        assert TrieHard.auto_complete(trie, "", 2) == ["a", "aa"]
        assert TrieHard.delete(trie, List.last(keys)) == :ok
        assert TrieHard.count_prefix(trie, "a") == 2_999
      end

      test "very deep keys do not overflow the scheduler stack" do
        trie = TrieHard.new(layout: @layout)
        key = String.duplicate("a", 10_000)

        assert TrieHard.insert(trie, key, 1) == :ok
        assert TrieHard.auto_complete(trie, "", 1) == [key]
        assert TrieHard.count_prefix(trie, "a") == 1
        assert TrieHard.delete(trie, key) == :ok
        assert TrieHard.fetch(trie, key) == {:error, :not_found}
      end

      test "prefix? on an empty trie is false" do
        refute TrieHard.prefix?(TrieHard.new(layout: @layout), "")
      end
    end

    # Contract (C001): every fast NIF returns :dirty just past each bound and
    # does the work itself at the bound; the public API retries the twin.
    describe "#{layout}: fast NIFs hand off to dirty twins" do
      setup do
        {:ok, trie: TrieHard.new(layout: @layout), etf: :erlang.term_to_binary(1)}
      end

      test "keys and prefixes over 4 KiB", %{trie: trie, etf: etf} do
        at_limit = String.duplicate("k", 4_096)
        over = at_limit <> "k"

        assert Native.insert(trie, at_limit, etf) == :ok
        assert Native.get(trie, at_limit) == {:ok, etf}
        assert Native.prefix_search(trie, at_limit) == true
        assert Native.count_prefix(trie, at_limit) == 1
        assert Native.auto_complete(trie, at_limit, 1) == [at_limit]
        assert Native.delete(trie, at_limit) == true

        assert Native.insert(trie, over, etf) == :dirty
        assert Native.get(trie, over) == :dirty
        assert Native.delete(trie, over) == :dirty
        assert Native.prefix_search(trie, over) == :dirty
        assert Native.count_prefix(trie, over) == :dirty
        assert Native.auto_complete(trie, over, 1) == :dirty
      end

      test "the key size gate runs before UTF-8 validation", %{trie: trie} do
        assert Native.get(trie, :binary.copy(<<0xFF>>, 5_000)) == :dirty

        assert_raise ArgumentError, fn ->
          Native.get_dirty(trie, :binary.copy(<<0xFF>>, 5_000))
        end

        assert_raise ArgumentError, fn -> Native.get(trie, <<0xFF>>) end
      end

      test "values over 64 KiB", %{trie: trie} do
        at_limit = :erlang.term_to_binary(:binary.copy(<<0>>, 65_530))
        over = :erlang.term_to_binary(:binary.copy(<<0>>, 65_531))
        assert {byte_size(at_limit), byte_size(over)} == {65_536, 65_537}

        assert Native.insert(trie, "a", at_limit) == :ok
        assert Native.get(trie, "a") == {:ok, at_limit}
        assert Native.insert(trie, "b", over) == :dirty
        assert Native.insert_dirty(trie, "b", over) == :ok
        assert Native.get(trie, "b") == :dirty
        assert Native.get_dirty(trie, "b") == {:ok, over}
      end

      test "traversals over 10,000 node visits", %{trie: trie} do
        TrieHard.add_word_list(trie, for(i <- 1..20_000, do: "w#{i}"))

        assert Native.count_prefix(trie, "w1234") == 11
        assert Native.count_prefix(trie, "") == :dirty
        assert Native.count_prefix_dirty(trie, "") == 20_000
        assert Native.auto_complete(trie, "", 20_000) == :dirty
        assert length(Native.auto_complete_dirty(trie, "", 20_000)) == 20_000
      end

      test "copying a long stored key", %{trie: trie, etf: etf} do
        long = String.duplicate("a", 200_000)
        assert TrieHard.insert(trie, long, 1) == :ok

        # Sorted: 200k node visits. Radix: 2 visits, but 200 KB copied.
        assert Native.auto_complete(trie, "", 1) == :dirty
        assert TrieHard.auto_complete(trie, "", 1) == [long]

        if @layout == :radix do
          # "ab" splits the 200 KB edge; deleting it merges the edge back.
          assert Native.insert(trie, "ab", etf) == :dirty
          assert Native.insert_dirty(trie, "ab", etf) == :ok
          assert Native.delete(trie, "ab") == :dirty
          assert Native.delete_dirty(trie, "ab") == true
        else
          assert Native.insert(trie, "ab", etf) == :ok
          assert Native.delete(trie, "ab") == true
        end

        assert TrieHard.fetch(trie, "ab") == {:error, :not_found}
        assert TrieHard.fetch(trie, long) == {:ok, 1}
      end
    end

    describe "#{layout}: values and bulk loads" do
      test "insert_many round-trips mixed values across chunks" do
        trie = TrieHard.new(layout: @layout)
        mixed = [{"atom", :v}, {"map", %{a: [1, 2]}}, {"tuple", {1, "x"}}, {"pid", self()}]
        many = for i <- 1..2_500, do: {"k#{i}", i}

        assert TrieHard.insert_many(trie, mixed ++ many) == :ok

        for {key, value} <- mixed ++ many do
          assert TrieHard.fetch(trie, key) == {:ok, value}
        end

        assert TrieHard.count_prefix(trie, "k") == 2_500
      end

      test "insert_many accepts any enumerable and overwrites existing keys" do
        trie = TrieHard.new(layout: @layout)
        TrieHard.insert(trie, "a", :old)
        TrieHard.add_word_list(trie, ["b"])

        assert TrieHard.insert_many(trie, %{"a" => :new, "b" => 2}) == :ok
        assert TrieHard.insert_many(trie, Stream.map(1..3, &{"s#{&1}", &1})) == :ok
        assert TrieHard.insert_many(trie, [{"c", 1}, {"c", 2}]) == :ok

        assert TrieHard.fetch(trie, "a") == {:ok, :new}
        assert TrieHard.fetch(trie, "b") == {:ok, 2}
        assert TrieHard.fetch(trie, "c") == {:ok, 2}
        assert TrieHard.auto_complete(trie, "s") == ["s1", "s2", "s3"]
      end

      test "insert_many raises ArgumentError on invalid elements, keeping earlier chunks" do
        trie = TrieHard.new(layout: @layout)
        valid = for i <- 1..1_000, do: {"k#{i}", i}

        for bad <- [{:atom_key, 1}, :not_a_tuple, {"a", 1, 2}, {<<0xFF>>, 1}] do
          assert_raise ArgumentError, fn -> TrieHard.insert_many(trie, valid ++ [bad]) end
        end

        assert TrieHard.count_prefix(trie, "k") == 1_000
      end

      test "get after add_word_list returns the word" do
        trie = TrieHard.new(layout: @layout)
        assert TrieHard.add_word_list(trie, ["alpha", "beta"]) == :ok
        assert TrieHard.fetch(trie, "alpha") == {:ok, "alpha"}
      end

      test "add_word_list overwrites a prior insert value" do
        trie = TrieHard.new(layout: @layout)
        assert TrieHard.insert(trie, "alpha", %{v: 1}) == :ok
        assert TrieHard.add_word_list(trie, ["alpha"]) == :ok
        assert TrieHard.fetch(trie, "alpha") == {:ok, "alpha"}
      end

      test "large values round-trip" do
        trie = TrieHard.new(layout: @layout)
        big = :binary.copy(<<1, 2, 3, 4>>, 2_500_000)
        deep = Enum.reduce(1..10_000, :leaf, fn i, acc -> %{i => acc} end)

        assert TrieHard.insert(trie, "big", big) == :ok
        assert TrieHard.insert(trie, "deep", deep) == :ok
        assert TrieHard.fetch(trie, "big") == {:ok, big}
        assert TrieHard.fetch(trie, "deep") == {:ok, deep}
      end

      test "keys longer than the fast-path limit work" do
        trie = TrieHard.new(layout: @layout)
        key = String.duplicate("k", 5_000)

        assert TrieHard.insert(trie, key, :v) == :ok
        assert TrieHard.fetch(trie, key) == {:ok, :v}
        assert TrieHard.prefix?(trie, key)
        assert TrieHard.count_prefix(trie, key) == 1
        assert TrieHard.auto_complete(trie, key, 5) == [key]
        assert TrieHard.delete(trie, key) == :ok
        assert TrieHard.fetch(trie, key) == {:error, :not_found}
      end
    end

    describe "#{layout}: concurrent access" do
      test "processes insert and read the same trie" do
        trie = TrieHard.new(layout: @layout)
        TrieHard.insert(trie, "shared", "data")

        results =
          1..10
          |> Enum.map(fn i ->
            Task.async(fn ->
              TrieHard.insert(trie, "process#{i}", "data#{i}")
              TrieHard.fetch(trie, "shared")
            end)
          end)
          |> Task.await_many()

        assert results == List.duplicate({:ok, "data"}, 10)

        for i <- 1..10 do
          assert TrieHard.fetch(trie, "process#{i}") == {:ok, "data#{i}"}
        end
      end

      test "readers see whole chunks, in order, while a writer bulk-loads" do
        trie = TrieHard.new(layout: @layout)
        assert TrieHard.insert(trie, "shared", :data) == :ok
        words = for i <- 1..200_000, do: "w#{i}"
        parent = self()

        writer =
          Task.async(fn ->
            send(parent, :writer_started)
            TrieHard.add_word_list(trie, words)
          end)

        assert_receive :writer_started, 5_000

        # Readers poll until the load is done. Five of them also count the
        # loaded words (an O(n) traversal) to check chunk atomicity and order.
        observations =
          1..50
          |> Task.async_stream(
            fn i ->
              observe = fn ->
                count = if i <= 5, do: TrieHard.count_prefix(trie, "w")

                {TrieHard.fetch(trie, "shared"), TrieHard.auto_complete(trie, "w#{i}", 5), count,
                 TrieHard.fetch(trie, "w200000") != {:error, :not_found}}
              end

              obs =
                Enum.reduce_while(1..100_000, [], fn _, acc ->
                  {_, _, _, done?} = latest = observe.()
                  acc = [latest | acc]
                  if done?, do: {:halt, acc}, else: {:cont, acc}
                end)

              {i, Enum.reverse(obs)}
            end,
            max_concurrency: 50,
            timeout: 60_000
          )
          |> Enum.map(fn {:ok, result} -> result end)

        assert Task.await(writer, 60_000) == :ok

        counts =
          for {i, obs} <- observations, {shared, found, count, _} <- obs, count != nil do
            assert shared == {:ok, :data}
            assert Enum.all?(found, &String.starts_with?(&1, "w#{i}"))
            # Each chunk is inserted under one write lock.
            assert rem(count, 1_000) == 0
            count
          end

        for {i, obs} <- observations, i <= 5 do
          reader_counts = Enum.map(obs, &elem(&1, 2))
          assert reader_counts == Enum.sort(reader_counts), "counts went backwards"
        end

        assert Enum.any?(counts, &(&1 < 200_000)), "no read overlapped the bulk load"
        assert TrieHard.count_prefix(trie, "w") == 200_000
        assert TrieHard.fetch(trie, "w200000") == {:ok, "w200000"}
      end
    end
  end
end
