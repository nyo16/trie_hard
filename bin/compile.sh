#!/usr/bin/env bash
set -euo pipefail

export TRIE_HARD_BUILD=true
rm -rf _build
mix clean
mix compile
