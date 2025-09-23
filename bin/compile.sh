#!/usr/bin/env bash 

export TRIE_HARD_BUILD=true
rm -rf _build
mix clean
mix compile