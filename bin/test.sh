#!/usr/bin/env bash 

export TRIE_HARD_BUILD=true
export MIX_ENV=test
mix format
mix compile
mix test
