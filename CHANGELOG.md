# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.8] - 2026-10-28

### Fixed

- `delete/2` no longer panics on keys containing non-ASCII characters (e.g. `"café"`, `"🦀"`);
  a panic previously also poisoned the trie so every later call returned `:error`.
  Deletion is now iterative and linear in the key length.
- Very long keys (10,000+ characters) no longer overflow the scheduler stack in
  `auto_complete/3`, `count_prefix/2`, `delete/2`, or when the trie is garbage collected
  (previously crashed the VM with SIGBUS).
- `count_prefix/2` returns the exact count; it was capped at 64.
- `prefix_search(trie, "")` returns `{:ok, false}` on an empty trie.
- `auto_complete/3` raises `FunctionClauseError` for a negative `max_results` instead of
  an `ArgumentError` from the NIF.
- A panic inside the NIF can no longer leave the trie permanently locked.

### Removed

- `legacy_cpu` precompiled artifact variants and the `TRIE_HARD_USE_LEGACY_ARTIFACTS`
  environment variable / `:use_legacy_artifacts` config. x86_64 artifacts now target
  baseline x86-64 and run on every x86_64 CPU; the CPU detection that selected the
  variant never worked.

### Changed

- Precompiled NIFs are built with a pinned Rust toolchain (`rust-toolchain.toml`,
  1.97.1); the crate declares MSRV 1.91.
- macOS artifacts are built on `macos-15` runners (`macos-13` was retired).

## [0.2.7] - 2025-09-23

### Added

- Values may be any Erlang term (atoms, numbers, tuples, maps, lists, PIDs, references,
  binaries). Strings are stored as-is; other terms are stored in external term format.
- Precompiled NIFs for NIF version 2.16 alongside 2.15.

## [0.2.6] - 2025-09-23

### Added

- Precompiled NIFs for `aarch64-unknown-linux-musl` and `x86_64-unknown-linux-musl`.

### Changed

- CI caches Rust and Mix dependencies.

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