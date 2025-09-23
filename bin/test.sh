#!/usr/bin/env bash 

export TRIE_HARD_BUILD=true
export MIX_ENV=test

## format elixir
mix format
## format rust
cargo fmt --manifest-path=native/trie_hard_native/Cargo.toml --all

## run tests
mix test

## run clippy
cargo clippy --manifest-path=native/trie_hard_native/Cargo.toml -- -Dwarnings
