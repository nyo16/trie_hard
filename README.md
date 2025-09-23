# TrieHard

A blazing fast, memory-efficient Trie (prefix tree) implementation for Elixir with autocomplete support, powered by the high-performance `trie_hard_rs` Rust library via Rustler.

## Features

- **🚀 Blazing Fast**: Sub-microsecond autocomplete performance (155μs for 100 results)
- **💾 Memory Efficient**: Shared prefix storage minimizes memory usage
- **🌐 Unicode Support**: Full UTF-8 character support including emojis
- **🔄 Thread-Safe**: Concurrent access support with Rust's safety guarantees
- **📦 Batch Operations**: Efficient bulk insertions (0.586μs per word)
- **🔍 Rich API**: Insert, lookup, delete, prefix search, autocomplete, and counting

## Performance

Based on benchmarks with 10,000 words:

- **Insert**: 0.66μs per word (individual), 0.59μs per word (batch)
- **Lookup**: 2μs
- **Autocomplete**: 155μs for 100 results
- **Prefix Search**: 4μs

## Installation

Add `trie_hard` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:trie_hard, "~> 0.2.0"}
  ]
end
```

Documentation can be found at [https://hexdocs.pm/trie_hard](https://hexdocs.pm/trie_hard).

## Requirements

- Rust nightly toolchain (for edition 2024 support)
- Elixir 1.18+

## Quick Start

```elixir
# Create a new trie
trie = TrieHard.new()

# Insert key-value pairs
TrieHard.insert(trie, "cat", "feline")
TrieHard.insert(trie, "car", "vehicle")
TrieHard.insert(trie, "card", "payment")

# Lookup values
{:ok, "feline"} = TrieHard.get(trie, "cat")
{:not_found, nil} = TrieHard.get(trie, "dog")

# Autocomplete
{:ok, suggestions} = TrieHard.auto_complete(trie, "ca", 10)
# Returns: ["car", "card", "cat"] (order may vary)

# Prefix search
{:ok, true} = TrieHard.prefix_search(trie, "ca")
{:ok, false} = TrieHard.prefix_search(trie, "xyz")

# Count words with prefix
{:ok, 3} = TrieHard.count_prefix(trie, "ca")

# Batch operations
words = ["apple", "application", "apply"]
:ok = TrieHard.add_word_list(trie, words)
```

## API Reference

### Core Operations

- `new/0` - Create a new empty trie
- `insert/3` - Insert a key-value pair
- `get/2` - Retrieve a value by key
- `delete/2` - Remove a key and its value

### Search Operations

- `prefix_search/2` - Check if any words start with prefix
- `auto_complete/3` - Get words starting with prefix (with limit)
- `count_prefix/2` - Count words with given prefix

### Batch Operations

- `add_word_list/2` - Insert multiple words efficiently

## Advanced Usage

### Unicode Support

```elixir
trie = TrieHard.new()

TrieHard.insert(trie, "café", "coffee")
TrieHard.insert(trie, "🦀", "crab emoji")
TrieHard.insert(trie, "こんにちは", "hello in Japanese")

{:ok, "coffee"} = TrieHard.get(trie, "café")
{:ok, results} = TrieHard.auto_complete(trie, "caf", 5)
```

### Large Datasets

```elixir
trie = TrieHard.new()

# Efficient batch insertion
words = for i <- 1..10_000, do: "word_#{i}"
TrieHard.add_word_list(trie, words)

# Fast autocomplete even with large datasets
{:ok, suggestions} = TrieHard.auto_complete(trie, "word_", 20)
```

### Concurrent Access

```elixir
trie = TrieHard.new()

# Multiple processes can safely access the same trie
tasks = for i <- 1..100 do
  Task.async(fn ->
    TrieHard.insert(trie, "process_#{i}", "data_#{i}")
    TrieHard.get(trie, "process_#{i}")
  end)
end

results = Task.await_many(tasks)
```

## Development

### Setup

1. Install Rust nightly toolchain:
```bash
rustup toolchain install nightly
rustup override set nightly  # In project directory
```

2. Install Elixir dependencies:
```bash
mix deps.get
```

3. Compile:
```bash
mix compile
```

### Testing

```bash
# Run all tests
mix test

# Run with benchmarks
mix test --include benchmark
```

## Architecture

TrieHard uses Rustler to bridge Elixir with the high-performance `trie_hard_rs` Rust library:

- **Elixir Layer**: Provides idiomatic Elixir API and documentation
- **Rustler Bridge**: Manages memory-safe resource handling and type conversion
- **Rust Core**: Leverages `trie_hard_rs` for optimal performance and memory efficiency

The trie data structure is stored as a Rustler resource, ensuring thread-safety and efficient memory management while providing seamless integration with Elixir processes.

## Contributing

1. Fork the repository
2. Create your feature branch
3. Add tests for new functionality
4. Ensure all tests pass: `mix test`
5. Submit a pull request

## License

Apache-2.0

## Acknowledgments

- Built on the excellent [`trie_hard_rs`](https://crates.io/crates/trie_hard_rs) library by GhostVox
- Powered by [Rustler](https://github.com/rusterlium/rustler) for seamless Rust-Elixir integration

