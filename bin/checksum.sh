#!/usr/bin/env bash

## download all precompiled NIFs
# mix rustler_precompiled.download TrieHard.Native --all --print

export TRIE_HARD_BUILD=true
mix rustler_precompiled.download TrieHard.Native --only-local