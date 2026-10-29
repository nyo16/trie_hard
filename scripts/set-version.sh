#!/usr/bin/env bash
# Validates a release version and writes it into mix.exs, Cargo.toml and
# Cargo.lock. Used by the release workflow, where the pushed tag is the source
# of truth for the version.
#
# Usage: scripts/set-version.sh [--check] <version>
#   --check   only validate; print the version and change nothing

set -euo pipefail

check_only=false
if [[ "${1:-}" == "--check" ]]; then
  check_only=true
  shift
fi
version=${1:-}

# The version comes from a tag name, which anyone who can push a tag controls,
# and it is interpolated into sed/awk below. The glob rejects anything outside
# [0-9A-Za-z.+-] (including newlines, which a line-oriented grep would let
# through); the regex then requires strict semver.
case "$version" in
  '' | *[!0-9A-Za-z.+-]*)
    echo "error: version '${version}' has characters outside [0-9A-Za-z.+-]" >&2
    exit 1
    ;;
esac
if ! printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'; then
  echo "error: version '${version}' is not semver" >&2
  exit 1
fi

if [[ "$check_only" == "true" ]]; then
  echo "$version"
  exit 0
fi

sed -i.bak -e "s/^  @version \".*\"/  @version \"${version}\"/" mix.exs
rm mix.exs.bak
grep -q "^  @version \"${version}\"" mix.exs

cargo_toml=native/trie_hard_native/Cargo.toml
awk -v v="$version" '!done && /^version = / { print "version = \"" v "\""; done = 1; next } { print }' \
  "$cargo_toml" > "$cargo_toml.tmp"
mv "$cargo_toml.tmp" "$cargo_toml"

# Record the crate's own version in Cargo.lock (builds use --locked).
(cd native/trie_hard_native && cargo update --workspace --quiet)

echo "$version"
