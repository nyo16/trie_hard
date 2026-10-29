# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - Unreleased

0.2.8 and 0.2.9 were prepared but never published; everything since 0.2.7 ships in 0.3.0.

### Breaking changes

Lookups follow `Map`: `fetch/2` returns `{:ok, value}` or `{:error, :not_found}`, and `get/3`
returns the value or a default. Other functions return plain values instead of `{:ok, _}`
tuples; internal failures (none are reachable) raise instead of returning `:error` tuples.

| 0.2.x | 0.3.0 |
|---|---|
| `get(t, k)` → `{:ok, v}` \| `{:not_found, nil}` | `fetch(t, k)` → `{:ok, v}` \| `{:error, :not_found}` |
| — | `get(t, k, default \\ nil)` → `v` \| `default` (like `Map.get/3`) |
| `prefix_search(t, p)` → `{:ok, boolean}` | `prefix?(t, p)` → `boolean` (`prefix_search/2` removed) |
| `auto_complete(t, p, n)` → `{:ok, [key]}` | `auto_complete(t, p, n)` → `[key]` |
| `count_prefix(t, p)` → `{:ok, n}` | `count_prefix(t, p)` → `n` |
| `delete(t, k)` → `:ok` always | `delete(t, k)` → `:ok` if the key existed, `{:error, :not_found}` otherwise |
| `insert/3`, `add_word_list/2` → `:ok` | unchanged |
| `@type trie :: reference()` | `@opaque t` (`TrieHard.t()`); don't rely on it being a reference |

`get/2` keeps its name but now returns the value itself: code matching `{:ok, v}` on `get/2`
must switch to `fetch/2` (or use the value directly).

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
case TrieHard.fetch(trie, key) do
  {:ok, value} -> value
  {:error, :not_found} -> default
end
# or, when stored values are never `default`:
value = TrieHard.get(trie, key, default)
words = TrieHard.auto_complete(trie, prefix, 5)
count = TrieHard.count_prefix(trie, prefix)
found? = TrieHard.prefix?(trie, prefix)
```

### Fixed

- `delete/2` no longer panics on keys containing non-ASCII characters (e.g. `"café"`, `"🦀"`);
  a panic previously also poisoned the trie so every later call returned `:error`.
  Deletion is iterative and linear in the key length.
- Very long keys (10,000+ characters) no longer overflow the scheduler stack in
  `auto_complete/3`, `count_prefix/2`, `delete/2`, or when the trie is garbage collected
  (previously crashed the VM with SIGBUS).
- `count_prefix/2` returns the exact count; it was capped at 64.
- `prefix?/2` (formerly `prefix_search/2`) is false on an empty trie, including for `""`.
- `auto_complete/3` raises `FunctionClauseError` for a negative `max_results` (was an
  `ArgumentError` from the NIF) and accepts limits beyond 64 bits.
- A panic inside the NIF can no longer leave the trie permanently locked.
- A string value that happened to be valid external term format is no longer decoded by
  mistake on lookup.
- NIF calls no longer block normal schedulers (0.2.7 ran every call on the caller's scheduler
  under a `Mutex`; a large `count_prefix/2` or bulk load stalled it for hundreds of ms).

### Changed

- **Default layout is `:radix`** (path-compressed): ~12x less memory than a byte-per-node layout
  (~50 vs ~600 bytes per key for 200,000 `"word_<n>_suffix"` keys; 0.2.7 used ~2,800) and
  faster for writes, `auto_complete/3` and `count_prefix/2`; point lookups (`fetch/2`,
  `prefix?/2`) are 20–35 ns slower than `layout: :sorted`. Results are identical in both.
- `auto_complete/3` returns keys in lexicographic (codepoint) order, and a limit keeps the
  first matches in that order. Previously the order was arbitrary and could differ between runs.
- Concurrency: reads run concurrently (`RwLock` instead of `Mutex`). Each call runs on the
  caller's scheduler without blocking. Calls whose key exceeds 4 KiB, value exceeds 64 KiB, or
  that would visit more than 10,000 nodes or copy more than 64 KiB move to a dirty CPU scheduler.
  Calls that find the lock taken yield and retry before waiting on a dirty scheduler (reads for
  about 50 ms, writes only briefly), so waiting readers don't starve bulk writers of dirty
  schedulers.
- `add_word_list/2` runs on a dirty scheduler in chunks of at most 1,000 words or 1 MiB, so
  readers interleave with bulk loads, and accepts any enumerable. It is not atomic: an invalid
  element raises `ArgumentError`; earlier chunks stay inserted, words in its chunk are not.
- Values are always stored in external term format, encoded and decoded in Elixir
  (`binary_to_term/2` with `:safe`).
- Minimum `rustler_precompiled` is 0.10 (drops the `castore` dependency); `rustler` (optional)
  is `~> 0.37`.
- Precompiled NIF versions are 2.16 and 2.17; 2.15 is dropped (unused by OTP 26+).
- The Hex package includes the NIF sources, so `TRIE_HARD_BUILD=true` works for Hex installs.
- Precompiled NIFs are built with a pinned Rust toolchain (`rust-toolchain.toml`, 1.97.1) by a
  vendored build script, with `cross` installed from a hash-verified release and its images
  pinned by digest; macOS artifacts are built on `macos-15` (`macos-13` was retired).
  Artifacts are attested in a separate publish job, and `scripts/release.sh` publishes only a
  checksum file that matches the attested bytes of the tagged release workflow.
- The crate declares MSRV 1.91.

### Added

- `new/1` with `layout: :radix | :sorted`. Unknown options or layouts raise `ArgumentError`.
- `insert_many/2`: inserts `{key, value}` pairs from any enumerable, in chunks of at most 1,000
  pairs or 1 MiB on a dirty scheduler; not atomic (an invalid element raises `ArgumentError`;
  earlier chunks stay inserted, entries in its chunk are not).

### Removed

- `prefix_search/2` (replaced by `prefix?/2`, see above).
- `legacy_cpu` precompiled artifact variants and the `TRIE_HARD_USE_LEGACY_ARTIFACTS`
  environment variable / `:use_legacy_artifacts` config. x86_64 artifacts target baseline
  x86-64 and run on every x86_64 CPU; the CPU detection that selected the variant never worked.
- The wall-clock `:benchmark` test module; use `bench/trie_bench.exs` (`MIX_ENV=bench`).

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
- Benchmarks (measured on a debug NIF build; superseded by the release-build numbers in the README since 0.3.0):
  - Insert: 0.66μs per word (individual), 0.59μs per word (batch)
  - Lookup: 2μs
  - Autocomplete: 155μs for 100 results
  - Prefix search: 4μs
- Comprehensive test suite with 30+ tests
- Complete API documentation with examples
- Memory-efficient shared prefix storage

### Technical Details

- Requires Rust nightly toolchain for edition 2024 support (no longer true: stable Rust, edition 2021,
  MSRV 1.91 since 0.3.0)
- Built with Rustler for seamless Elixir-Rust integration
- Uses `trie_hard_rs` v0.1.0 for core trie functionality (removed in 0.2.x)
- Elixir 1.18+ compatibility