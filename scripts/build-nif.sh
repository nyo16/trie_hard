#!/usr/bin/env bash
# Builds and packages one precompiled NIF the way rustler_precompiled expects.
#
# Replaces philss/rustler-precompiled-action, whose cross install pulls in a
# tag-pinned third-party action and an unhashed download. Same artifact names.
#
# Usage: scripts/build-nif.sh <target> <nif-version> <use-cross:true|false> <project-version>
#
# Prints the tarball path (relative to the repo root) on the last line of
# stdout and, under GitHub Actions, writes file-name/file-path/file-sha256
# to $GITHUB_OUTPUT.

set -euo pipefail

target=$1
nif_version=$2
use_cross=$3
project_version=$4

crate=trie_hard_native
crate_dir=native/trie_hard_native
root=$(pwd)

tool=cargo
if [[ "$use_cross" == "true" ]]; then
  tool=cross
fi

# rustler >= 0.30 selects the NIF version by cargo feature; the highest
# enabled feature wins, so adding it on top of the default is enough.
feature="nif_version_${nif_version//./_}"

(
  cd "$crate_dir"
  set -x
  "$tool" build --release --locked --target "$target" --features "$feature"
)

lib_prefix=lib
lib_suffix=.so
final_suffix=.so
case "$target" in
  *-pc-windows-*) lib_prefix=""; lib_suffix=.dll; final_suffix=.dll ;;
  *-apple-*) lib_suffix=.dylib ;; # loaded by the BEAM as .so
esac

lib_dir="$crate_dir/target/$target/release"
final_name="${lib_prefix}${crate}-v${project_version}-nif-${nif_version}-${target}${final_suffix}"
tarball="${final_name}.tar.gz"

cp "$lib_dir/${lib_prefix}${crate}${lib_suffix}" "$lib_dir/$final_name"
tar -C "$lib_dir" -czf "$root/$tarball" "$final_name"

if command -v sha256sum >/dev/null; then
  sha=$(sha256sum "$tarball" | cut -d' ' -f1)
else
  sha=$(shasum -a 256 "$tarball" | cut -d' ' -f1)
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "file-name=$tarball"
    echo "file-path=$tarball"
    echo "file-sha256=$sha"
  } >> "$GITHUB_OUTPUT"
fi

echo "$tarball"
