# trie_hard_native

Rust NIF behind `TrieHard.Native` (loaded via `rustler_precompiled`, see `lib/trie_hard/native.ex`).

- `src/lib.rs` — NIF entry points (fast/dirty pairs) and the `RwLock`-protected resource
- `src/sorted.rs` — byte-keyed trie with sorted child arrays
- `src/value.rs` — stored value representation

```bash
cargo test    # unit + property tests
cargo clippy --all-targets -- -Dwarnings
```

The toolchain is pinned in the repository's `rust-toolchain.toml`; MSRV is 1.91.
