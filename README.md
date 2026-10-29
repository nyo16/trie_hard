# TrieHard

A fast, memory-efficient trie (prefix tree) for Elixir with autocomplete, implemented as a Rust NIF via Rustler.

## Features

- **Fast**: sub-microsecond lookups, prefix checks and 10-result autocompletes
- **Compact**: path-compressed (radix) layout by default, ~60–80 bytes per key in the benchmark below
- **Deterministic**: `auto_complete` returns keys in lexicographic (codepoint) order
- **Unicode**: keys are UTF-8 strings, including emoji and combining characters
- **Any value**: store any Erlang term
- **Scheduler-friendly**: concurrent readers; long or contended operations move to dirty schedulers

## Performance

Measured with `bench/trie_bench.exs` (release build) on an Apple M4 Max, macOS, Elixir 1.20.0 / OTP 29.1.1,
against a trie of 100,000 `"word_<n>_suffix"` keys:

| Operation | `:radix` (default) | `:sorted` |
|---|---|---|
| `get/2` (hit) | 0.15 µs | 0.14 µs |
| `prefix?/2` | 0.11 µs | 0.10 µs |
| `delete/2` + `insert/3` | 0.30 µs | 0.50 µs |
| `auto_complete/3`, 10 results | 0.58 µs | 0.98 µs |
| `auto_complete/3`, 100 results | 2.5 µs | 6.4 µs |
| `count_prefix/2`, 111 matches | 0.24 µs | 1.2 µs |
| `count_prefix/2`, 11,112 matches | 24 µs | 149 µs |
| `insert/3`, per key (1,000 into a new trie) | 0.15 µs | 0.41 µs |
| `insert_many/2`, per key | 0.15 µs | 0.42 µs |
| `add_word_list/2`, per key | 0.09 µs | 0.37 µs |

Memory per key (RSS delta for 200,000 keys, fresh VM per layout):

| Keys | `:radix` | `:sorted` |
|---|---|---|
| `"word_<n>_suffix"` | 59–78 B | 764 B |
| `"https://example.com/users/<n>/profile/settings"` | 131–165 B | 2,074 B |

Ranges are the spread over repeated runs (small RSS deltas are noisy).

Run it yourself:

```bash
MIX_ENV=bench TRIE_HARD_BUILD=true mix run bench/trie_bench.exs
```

## Installation

```elixir
def deps do
  [
    {:trie_hard, "~> 0.3.0"}
  ]
end
```

Precompiled NIFs are downloaded for these targets: `aarch64-apple-darwin`, `x86_64-apple-darwin`,
`aarch64-unknown-linux-gnu`, `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-musl`,
`x86_64-unknown-linux-musl`, `x86_64-pc-windows-gnu` (NIF versions 2.16 and 2.17).
On any other target, set `TRIE_HARD_BUILD=true` to compile the NIF from the bundled sources;
this needs Rust 1.91 or newer and the optional `{:rustler, "~> 0.37"}` dependency in your project.

Documentation: [https://hexdocs.pm/trie_hard](https://hexdocs.pm/trie_hard).

## Requirements

- Elixir 1.18+ (CI covers OTP 26 through 29)
- Building from source only: stable Rust ≥ 1.91 (the repository pins 1.97.1 in `rust-toolchain.toml`)

## Quick Start

```elixir
trie = TrieHard.new()

:ok = TrieHard.insert(trie, "cat", "feline")
:ok = TrieHard.insert_many(trie, [{"car", %{wheels: 4}}, {"card", {:payment, :plastic}}])

{:ok, "feline"} = TrieHard.get(trie, "cat")
:error = TrieHard.get(trie, "dog")

# Lexicographic order; the limit keeps the first matches in that order
["car", "card", "cat"] = TrieHard.auto_complete(trie, "ca", 10)
["car", "card"] = TrieHard.auto_complete(trie, "ca", 2)

true = TrieHard.prefix?(trie, "ca")
false = TrieHard.prefix?(trie, "xyz")

3 = TrieHard.count_prefix(trie, "ca")

:ok = TrieHard.delete(trie, "cat")
:error = TrieHard.delete(trie, "cat")

# Each word is stored with itself as the value
:ok = TrieHard.add_word_list(trie, ["apple", "application", "apply"])
{:ok, "apple"} = TrieHard.get(trie, "apple")

# One node per key byte instead of path compression; same results for every operation
sorted = TrieHard.new(layout: :sorted)
:ok = TrieHard.insert(sorted, "card", 1)
```

## API

| Function | Returns |
|---|---|
| `new/1` | an opaque trie (`TrieHard.t()`); option `layout: :radix` (default) or `:sorted` |
| `insert/3` | `:ok` |
| `insert_many/2` | `:ok` — inserts `{key, value}` pairs from any enumerable |
| `get/2` | `{:ok, value}` or `:error` |
| `delete/2` | `:ok`, or `:error` when the key was absent |
| `prefix?/2` | `boolean` — whether any key starts with the prefix |
| `auto_complete/3` | up to `max_results` (default 10) keys, in lexicographic order |
| `count_prefix/2` | exact number of keys with the prefix |
| `add_word_list/2` | `:ok` — inserts each word with itself as the value |

Keys must be UTF-8 binaries. Single-key functions raise `FunctionClauseError` for a non-binary key;
`insert_many/2` and `add_word_list/2` raise `ArgumentError` for any invalid element; invalid UTF-8
always raises `ArgumentError`.

## Concurrency

A trie can be shared between processes. Reads run concurrently; writes are exclusive. Every
operation first runs on the calling scheduler without blocking; if the trie is locked by a writer,
the key is longer than 4 KiB, the value larger than 64 KiB, or the operation would visit more than
10,000 nodes or copy more than 64 KiB of key bytes (results, or a `:radix` edge split/merge), it is
retried on a dirty CPU scheduler, so normal schedulers are never blocked.

`add_word_list/2` and `insert_many/2` always run on a dirty scheduler and send their input in
chunks of 1,000 entries, so readers interleave with large bulk loads. They are not atomic: an
invalid element raises `ArgumentError`; earlier chunks remain inserted, while entries in the
invalid element's chunk (including those before it) are not inserted.

While a long write holds the lock, readers wait on dirty schedulers. Bound key lengths for
untrusted input: one huge key makes its write long.

## Memory

A trie lives in native memory and is freed when its last reference is garbage collected, on the
scheduler thread that runs that collection. Freeing a trie with millions of keys takes
correspondingly long on that thread.

## Development

```bash
mix deps.get
TRIE_HARD_BUILD=true mix test
cargo test --manifest-path native/trie_hard_native/Cargo.toml
```

`bin/test.sh` runs the same checks as CI (formatting, tests, clippy, `cargo test`).
The Rust toolchain is pinned in `rust-toolchain.toml`; `rustup` installs it automatically.

## Architecture

- **Elixir** (`lib/trie_hard.ex`): public API; encodes values with `:erlang.term_to_binary/1` and
  decodes them with `:erlang.binary_to_term/2` (`:safe`), so large terms are handled by yielding BIFs
  instead of inside the NIF.
- **NIF** (`native/trie_hard_native/src/lib.rs`): a `RwLock`-protected trie in a Rustler resource;
  fast/dirty NIF pairs as described under Concurrency.
- **Tries** (`native/trie_hard_native/src/`): `radix.rs` (path-compressed edges) and `sorted.rs`
  (one node per byte, sorted child arrays), dispatched by `store.rs`. All traversals and frees are
  iterative, so very long keys cannot overflow the stack.

## Contributing

1. Fork the repository
2. Create your feature branch
3. Add tests for new functionality
4. Ensure `bin/test.sh` passes
5. Submit a pull request

## License

Apache-2.0

## Acknowledgments

- Powered by [Rustler](https://github.com/rusterlium/rustler) and
  [rustler_precompiled](https://github.com/philss/rustler_precompiled)
