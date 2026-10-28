# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - Unreleased

### Breaking changes

Return values no longer wrap results in `{:ok, _}` or use sentinel tuples. Internal failures
(none are reachable) raise instead of returning `:error` tuples.

| 0.2.x | 0.3.0 |
|---|---|
| `get(t, k)` → `{:ok, v}` \| `{:not_found, nil}` | `get(t, k)` → `{:ok, v}` \| `:error` |
| `prefix_search(t, p)` → `{:ok, boolean}` | `prefix?(t, p)` → `boolean` (`prefix_search/2` removed) |
| `auto_complete(t, p, n)` → `{:ok, [key]}` | `auto_complete(t, p, n)` → `[key]` |
| `count_prefix(t, p)` → `{:ok, n}` | `count_prefix(t, p)` → `n` |
| `delete(t, k)` → `:ok` always | `delete(t, k)` → `:ok` if the key existed, `:error` otherwise |
| `insert/3`, `add_word_list/2` → `:ok` | unchanged |
| `@type trie :: reference()` | `@opaque t` (`TrieHard.t()`); don't rely on it being a reference |

Migration:

```elixir
# 0.2.x
case TrieHard.get(trie, key) do
  {:ok, value} -> value
  {:not_found, nil} -> default
end
{:ok, words} = TrieHard.auto_complete(trie, prefix, 5)
{:ok, count} = TrieHard.count_prefix(trie, prefix)
{:ok, found?} = TrieHard.prefix_search(trie, prefix)

# 0.3.0
case TrieHard.get(trie, key) do
  {:ok, value} -> value
  :error -> default
end
words = TrieHard.auto_complete(trie, prefix, 5)
count = TrieHard.count_prefix(trie, prefix)
found? = TrieHard.prefix?(trie, prefix)
```

### Added

- `TrieHard.new(layout: :radix)`: a path-compressed layout with identical results for every
  operation. `new/0` keeps the `:sorted` layout. Unknown options or layouts raise `ArgumentError`.
- `insert_many/2`: inserts `{key, value}` pairs from any enumerable, in chunks of 1,000 on a dirty
  scheduler; not atomic (an invalid element raises `ArgumentError`, earlier chunks stay inserted).

## [0.2.9] - Unreleased

### Changed

- `auto_complete/3` returns keys in lexicographic (codepoint) order, and a limit keeps the
  first matches in that order. Previously the order was arbitrary and could differ between runs.
- Nodes are byte-keyed with sorted child arrays instead of per-character hash maps:
  memory per key drops from ~2,800 to ~760 bytes (200,000-key benchmark).
- Reads run concurrently (`RwLock` instead of `Mutex`). Calls never block a normal scheduler:
  when the trie is locked, the key exceeds 4 KiB, the value exceeds 64 KiB, or a traversal
  exceeds 10,000 node visits, the call is retried on a dirty CPU scheduler.
- `add_word_list/2` runs on a dirty scheduler and sends the list in chunks of 1,000 words, so
  readers interleave with bulk loads. It is not atomic: a non-UTF-8 or non-binary element raises
  `ArgumentError` and earlier chunks stay inserted.
- Values are always stored in external term format, encoded and decoded in Elixir
  (`binary_to_term/2` with `:safe`). A string value that happened to be valid external term
  format is no longer decoded by mistake on `get/2`.
- Minimum `rustler_precompiled` is 0.10 (drops the `castore` dependency); `rustler` (optional)
  is `~> 0.37`.
- Precompiled NIF versions are 2.16 and 2.17; 2.15 is dropped (unused by OTP 26+).
- The Hex package now includes the NIF sources, so `TRIE_HARD_BUILD=true` works for Hex installs.
- Release artifacts are built by a read-only job and attested in a separate publish job;
  `scripts/release.sh` verifies attestations before generating checksums.

### Removed

- The wall-clock `:benchmark` test module; use `bench/trie_bench.exs` (`MIX_ENV=bench`).

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
  (replaced by an in-house implementation in `src/trie.rs` in 0.2.x; trie_hard_rs is no longer used)
- Core operations: `new/0`, `insert/3`, `get/2`, `delete/2`
- Search operations: `prefix_search/2`, `auto_complete/3`, `count_prefix/2`
- Batch operations: `add_word_list/2` for efficient bulk insertions
- Thread-safe concurrent access with Rust's safety guarantees
- Full Unicode support including emojis
- Benchmarks (measured on a debug NIF build; superseded by the release-build numbers in the README since 0.2.9):
  - Insert: 0.66μs per word (individual), 0.59μs per word (batch)
  - Lookup: 2μs
  - Autocomplete: 155μs for 100 results
  - Prefix search: 4μs
- Comprehensive test suite with 30+ tests
- Complete API documentation with examples
- Memory-efficient shared prefix storage

### Technical Details

- Requires Rust nightly toolchain for edition 2024 support (no longer true: stable Rust, edition 2021,
  MSRV 1.91 since 0.2.8)
- Built with Rustler for seamless Elixir-Rust integration
- Uses `trie_hard_rs` v0.1.0 for core trie functionality (removed in 0.2.x)
- Elixir 1.18+ compatibility