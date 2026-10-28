defmodule TrieHard.ValueStorageTest do
  use ExUnit.Case, async: true

  defp round_trip(pairs) do
    trie = TrieHard.new()

    for {key, value} <- pairs do
      assert TrieHard.insert(trie, key, value) == :ok
    end

    for {key, value} <- pairs do
      assert TrieHard.get(trie, key) == {:ok, value}
    end

    trie
  end

  describe "strings" do
    test "plain, empty, unicode and long strings" do
      round_trip([
        {"str", "hello"},
        {"empty", ""},
        {"unicode", "café 🦀"},
        {"long", String.duplicate("a", 1000)}
      ])
    end

    test "a string that is itself valid external term format is returned as-is" do
      etf = :erlang.term_to_binary(:surprise)
      round_trip([{"etf", etf}])
    end
  end

  describe "other terms" do
    test "atoms" do
      round_trip([{"a1", :hello}, {"a2", :"complex-atom"}, {"a3", true}, {"a4", nil}])
    end

    test "numbers" do
      round_trip([
        {"small", 42},
        {"large", 1_234_567_890_123_456_789_012},
        {"negative", -123},
        {"zero", 0},
        {"pi", 3.14159},
        {"negative_float", -2.5}
      ])
    end

    test "lists" do
      round_trip([
        {"empty_list", []},
        {"numbers", [1, 2, 3, 4, 5]},
        {"mixed", [:atom, "string", 42, 3.14]},
        {"nested", [[1, 2], [3, 4], []]},
        {"improper", [1 | 2]}
      ])
    end

    test "tuples" do
      round_trip([
        {"pair", {:ok, "success"}},
        {"triple", {:user, 123, "john"}},
        {"single", {42}},
        {"empty", {}},
        {"nested", {{:a, :b}, {:c, :d}}}
      ])
    end

    test "maps" do
      round_trip([
        {"empty_map", %{}},
        {"simple", %{a: 1, b: 2}},
        {"mixed_keys", %{"string" => :atom, :atom => "string"}},
        {"nested", %{user: %{id: 123, name: "john"}}}
      ])
    end

    test "non-UTF-8 binaries" do
      round_trip([{"binary", <<1, 2, 3, 4, 255>>}])
    end

    test "pids, references and functions" do
      fun = fn x -> x + 1 end
      round_trip([{"self", self()}, {"ref", make_ref()}, {"fun", fun}])
    end

    test "deeply nested structures" do
      round_trip([
        {"complex",
         %{
           users: [
             %{id: 1, name: "alice", active: true},
             %{id: 2, name: "bob", active: false}
           ],
           config: %{timeout: 5000, retry: true, endpoints: ["http://api1.com"]},
           metadata: {:version, "1.0.0", %{build: 12345}}
         }}
      ])
    end
  end

  describe "mixed values" do
    test "overwriting changes the value type" do
      trie = TrieHard.new()

      for value <- ["string", :atom, %{type: "map"}, "back_to_string"] do
        assert TrieHard.insert(trie, "key", value) == :ok
        assert TrieHard.get(trie, "key") == {:ok, value}
      end
    end

    test "value types do not affect prefix operations" do
      trie =
        round_trip([
          {"prefix_string", "value"},
          {"prefix_atom", :value},
          {"prefix_number", 42},
          {"prefix_map", %{key: "value"}},
          {"other", self()}
        ])

      assert TrieHard.auto_complete(trie, "prefix_", 10) ==
               {:ok, ["prefix_atom", "prefix_map", "prefix_number", "prefix_string"]}

      assert TrieHard.count_prefix(trie, "") == {:ok, 5}
    end

    test "1000 string values" do
      pairs = for i <- 1..1000, do: {"key#{i}", "value#{i}"}
      trie = round_trip(pairs)

      assert TrieHard.count_prefix(trie, "key1") == {:ok, 112}
    end
  end
end
