#!/usr/bin/env bash
set -euo pipefail

export TRIE_HARD_BUILD=true
export MIX_ENV=test

## check elixir formatting
mix format --check-formatted
## check rust formatting
cargo fmt --manifest-path=native/trie_hard_native/Cargo.toml --all -- --check

## run tests
mix test

## run clippy
cargo clippy --manifest-path=native/trie_hard_native/Cargo.toml --all-targets -- -Dwarnings

## run rust tests
cargo test --manifest-path=native/trie_hard_native/Cargo.toml
