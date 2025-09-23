defmodule TrieHard.HybridStorageTest do
  use ExUnit.Case

  describe "Hybrid storage - zero overhead strings" do
    test "stores and retrieves strings (zero overhead path)" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "str1", "hello") == :ok
      assert TrieHard.insert(trie, "str2", "world") == :ok

      assert TrieHard.get(trie, "str1") == {:ok, "hello"}
      assert TrieHard.get(trie, "str2") == {:ok, "world"}
    end

    test "handles empty strings" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "empty", "") == :ok
      assert TrieHard.get(trie, "empty") == {:ok, ""}
    end

    test "handles unicode strings" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "unicode", "café 🦀") == :ok
      assert TrieHard.get(trie, "unicode") == {:ok, "café 🦀"}
    end

    test "handles very long strings" do
      trie = TrieHard.new()
      long_string = String.duplicate("a", 1000)

      assert TrieHard.insert(trie, "long", long_string) == :ok
      assert TrieHard.get(trie, "long") == {:ok, long_string}
    end
  end

  describe "Hybrid storage - binary encoded terms" do
    test "stores and retrieves atoms" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "atom1", :hello) == :ok
      assert TrieHard.insert(trie, "atom2", :world) == :ok
      assert TrieHard.insert(trie, "atom3", :"complex-atom") == :ok

      assert TrieHard.get(trie, "atom1") == {:ok, :hello}
      assert TrieHard.get(trie, "atom2") == {:ok, :world}
      assert TrieHard.get(trie, "atom3") == {:ok, :"complex-atom"}
    end

    test "stores and retrieves integers" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "small", 42) == :ok
      assert TrieHard.insert(trie, "large", 1_234_567_890) == :ok
      assert TrieHard.insert(trie, "negative", -123) == :ok
      assert TrieHard.insert(trie, "zero", 0) == :ok

      assert TrieHard.get(trie, "small") == {:ok, 42}
      assert TrieHard.get(trie, "large") == {:ok, 1_234_567_890}
      assert TrieHard.get(trie, "negative") == {:ok, -123}
      assert TrieHard.get(trie, "zero") == {:ok, 0}
    end

    test "stores and retrieves floats" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "pi", 3.14159) == :ok
      assert TrieHard.insert(trie, "negative", -2.5) == :ok
      assert TrieHard.insert(trie, "zero", 0.0) == :ok

      assert TrieHard.get(trie, "pi") == {:ok, 3.14159}
      assert TrieHard.get(trie, "negative") == {:ok, -2.5}
      assert TrieHard.get(trie, "zero") == {:ok, 0.0}
    end

    test "stores and retrieves booleans" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "true_val", true) == :ok
      assert TrieHard.insert(trie, "false_val", false) == :ok

      assert TrieHard.get(trie, "true_val") == {:ok, true}
      assert TrieHard.get(trie, "false_val") == {:ok, false}
    end

    test "stores and retrieves nil" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "nil_value", nil) == :ok
      assert TrieHard.get(trie, "nil_value") == {:ok, nil}
    end

    test "stores and retrieves lists" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "empty_list", []) == :ok
      assert TrieHard.insert(trie, "numbers", [1, 2, 3, 4, 5]) == :ok
      assert TrieHard.insert(trie, "mixed", [:atom, "string", 42, 3.14]) == :ok
      assert TrieHard.insert(trie, "nested", [[1, 2], [3, 4], []]) == :ok

      assert TrieHard.get(trie, "empty_list") == {:ok, []}
      assert TrieHard.get(trie, "numbers") == {:ok, [1, 2, 3, 4, 5]}
      assert TrieHard.get(trie, "mixed") == {:ok, [:atom, "string", 42, 3.14]}
      assert TrieHard.get(trie, "nested") == {:ok, [[1, 2], [3, 4], []]}
    end

    test "stores and retrieves tuples" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "pair", {:ok, "success"}) == :ok
      assert TrieHard.insert(trie, "triple", {:user, 123, "john"}) == :ok
      assert TrieHard.insert(trie, "single", {42}) == :ok
      assert TrieHard.insert(trie, "empty", {}) == :ok
      assert TrieHard.insert(trie, "nested", {{:a, :b}, {:c, :d}}) == :ok

      assert TrieHard.get(trie, "pair") == {:ok, {:ok, "success"}}
      assert TrieHard.get(trie, "triple") == {:ok, {:user, 123, "john"}}
      assert TrieHard.get(trie, "single") == {:ok, {42}}
      assert TrieHard.get(trie, "empty") == {:ok, {}}
      assert TrieHard.get(trie, "nested") == {:ok, {{:a, :b}, {:c, :d}}}
    end

    test "stores and retrieves maps" do
      trie = TrieHard.new()

      assert TrieHard.insert(trie, "empty_map", %{}) == :ok
      assert TrieHard.insert(trie, "simple", %{a: 1, b: 2}) == :ok
      assert TrieHard.insert(trie, "mixed_keys", %{"string" => :atom, :atom => "string"}) == :ok
      assert TrieHard.insert(trie, "nested", %{user: %{id: 123, name: "john"}}) == :ok

      assert TrieHard.get(trie, "empty_map") == {:ok, %{}}
      assert TrieHard.get(trie, "simple") == {:ok, %{a: 1, b: 2}}
      assert TrieHard.get(trie, "mixed_keys") == {:ok, %{"string" => :atom, :atom => "string"}}
      assert TrieHard.get(trie, "nested") == {:ok, %{user: %{id: 123, name: "john"}}}
    end

    test "stores and retrieves binaries" do
      trie = TrieHard.new()

      binary_data = <<1, 2, 3, 4, 255>>
      assert TrieHard.insert(trie, "binary", binary_data) == :ok
      assert TrieHard.get(trie, "binary") == {:ok, binary_data}
    end

    test "stores and retrieves PIDs" do
      trie = TrieHard.new()
      pid = self()

      assert TrieHard.insert(trie, "self", pid) == :ok
      assert TrieHard.get(trie, "self") == {:ok, pid}
    end

    test "stores and retrieves references" do
      trie = TrieHard.new()
      ref = make_ref()

      assert TrieHard.insert(trie, "ref", ref) == :ok
      assert TrieHard.get(trie, "ref") == {:ok, ref}
    end
  end

  describe "Complex hybrid storage scenarios" do
    test "mixed term types in same trie" do
      trie = TrieHard.new()

      test_data = [
        # Zero overhead path
        {"string", "test_string"},
        # Binary encoded
        {"atom", :test_atom},
        # Binary encoded
        {"integer", 42},
        # Binary encoded
        {"float", 3.14},
        # Binary encoded
        {"list", [1, 2, 3]},
        # Binary encoded
        {"tuple", {:ok, "result"}},
        # Binary encoded
        {"map", %{key: "value"}},
        # Binary encoded
        {"pid", self()},
        # Binary encoded
        {"ref", make_ref()},
        # Binary encoded
        {"nil", nil},
        # Binary encoded
        {"bool_true", true},
        # Binary encoded
        {"bool_false", false}
      ]

      # Insert all different types
      for {key, value} <- test_data do
        assert TrieHard.insert(trie, key, value) == :ok
      end

      # Verify all types can be retrieved correctly
      for {key, expected_value} <- test_data do
        assert TrieHard.get(trie, key) == {:ok, expected_value}
      end
    end

    test "handles overwriting with different term types" do
      trie = TrieHard.new()

      # Insert string first (zero overhead)
      assert TrieHard.insert(trie, "key", "string") == :ok
      assert TrieHard.get(trie, "key") == {:ok, "string"}

      # Overwrite with atom (binary encoded)
      assert TrieHard.insert(trie, "key", :atom) == :ok
      assert TrieHard.get(trie, "key") == {:ok, :atom}

      # Overwrite with map (binary encoded)
      assert TrieHard.insert(trie, "key", %{type: "map"}) == :ok
      assert TrieHard.get(trie, "key") == {:ok, %{type: "map"}}

      # Overwrite back to string (zero overhead)
      assert TrieHard.insert(trie, "key", "back_to_string") == :ok
      assert TrieHard.get(trie, "key") == {:ok, "back_to_string"}
    end

    test "deeply nested structures" do
      trie = TrieHard.new()

      complex_data = %{
        users: [
          %{id: 1, name: "alice", active: true},
          %{id: 2, name: "bob", active: false}
        ],
        config: %{
          timeout: 5000,
          retry: true,
          endpoints: ["http://api1.com", "http://api2.com"]
        },
        metadata: {:version, "1.0.0", %{build: 12345}}
      }

      assert TrieHard.insert(trie, "complex", complex_data) == :ok
      assert TrieHard.get(trie, "complex") == {:ok, complex_data}
    end
  end

  describe "Autocomplete compatibility" do
    test "autocomplete works with mixed term types" do
      trie = TrieHard.new()

      # Insert various types with common prefix
      # Zero overhead
      assert TrieHard.insert(trie, "prefix_string", "value") == :ok
      # Binary encoded
      assert TrieHard.insert(trie, "prefix_atom", :value) == :ok
      # Binary encoded
      assert TrieHard.insert(trie, "prefix_number", 42) == :ok
      # Binary encoded
      assert TrieHard.insert(trie, "prefix_map", %{key: "value"}) == :ok

      {:ok, results} = TrieHard.auto_complete(trie, "prefix_", 10)

      assert length(results) == 4
      assert "prefix_string" in results
      assert "prefix_atom" in results
      assert "prefix_number" in results
      assert "prefix_map" in results
    end
  end

  describe "Performance characteristics" do
    test "string operations maintain zero overhead" do
      trie = TrieHard.new()

      # Large number of string operations should be fast
      strings = for i <- 1..1000, do: {"key#{i}", "value#{i}"}

      for {key, value} <- strings do
        assert TrieHard.insert(trie, key, value) == :ok
      end

      for {key, expected_value} <- strings do
        assert TrieHard.get(trie, key) == {:ok, expected_value}
      end

      # Autocomplete should work efficiently
      {:ok, results} = TrieHard.auto_complete(trie, "key1", 50)
      assert length(results) > 0
    end

    test "mixed operations work efficiently" do
      trie = TrieHard.new()

      # Mix of zero-overhead strings and binary-encoded terms
      test_items = [
        # Zero overhead
        {"str1", "hello"},
        # Binary encoded
        {"atom1", :world},
        # Zero overhead
        {"str2", "elixir"},
        # Binary encoded
        {"num1", 42},
        # Zero overhead
        {"str3", "rustler"},
        # Binary encoded
        {"map1", %{lang: "rust"}}
      ]

      for {key, value} <- test_items do
        assert TrieHard.insert(trie, key, value) == :ok
      end

      for {key, expected_value} <- test_items do
        assert TrieHard.get(trie, key) == {:ok, expected_value}
      end

      # Prefix operations should work across types
      {:ok, str_results} = TrieHard.auto_complete(trie, "str", 10)
      assert length(str_results) == 3

      {:ok, all_results} = TrieHard.auto_complete(trie, "", 10)
      assert length(all_results) == 6
    end
  end
end
