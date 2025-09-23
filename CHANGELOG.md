# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.5] - 2025-09-22

### Fixed

- Fixed checksum file for precompiled NIFs to match version 0.2.5
- Resolved compilation errors related to missing precompiled NIF checksums

## [0.2.0] - 2025-09-15

### Changed

- **BREAKING**: Renamed project from `trie_again` to `trie_hard` to avoid naming conflicts
- **BREAKING**: Renamed main module from `TrieAgain` to `TrieHard`
- **BREAKING**: Updated package name in Hex.pm to `trie_hard`
- Updated all documentation and examples to reflect new naming
- Updated GitHub repository URL to match new name

### Migration Guide

If upgrading from 0.1.0:

1. Update your `mix.exs` dependency:
   ```elixir
   # Old
   {:trie_again, "~> 0.1.0"}

   # New
   {:trie_hard, "~> 0.2.0"}
   ```

2. Update your code:
   ```elixir
   # Old
   trie = TrieAgain.new()
   TrieAgain.insert(trie, "key", "value")

   # New
   trie = TrieHard.new()
   TrieHard.insert(trie, "key", "value")
   ```

## [0.1.0] - 2025-09-15

### Added

- Initial release of TrieHard (originally named TrieAgain)
- Complete Trie implementation powered by trie_hard_rs Rust library
- Core operations: `new/0`, `insert/3`, `get/2`, `delete/2`
- Search operations: `prefix_search/2`, `auto_complete/3`, `count_prefix/2`
- Batch operations: `add_word_list/2` for efficient bulk insertions
- Thread-safe concurrent access with Rust's safety guarantees
- Full Unicode support including emojis
- High-performance benchmarks:
  - Insert: 0.66μs per word (individual), 0.59μs per word (batch)
  - Lookup: 2μs
  - Autocomplete: 155μs for 100 results
  - Prefix search: 4μs
- Comprehensive test suite with 30+ tests
- Complete API documentation with examples
- Memory-efficient shared prefix storage

### Technical Details

- Requires Rust nightly toolchain for edition 2024 support
- Built with Rustler for seamless Elixir-Rust integration
- Uses `trie_hard_rs` v0.1.0 for core trie functionality
- Elixir 1.18+ compatibility