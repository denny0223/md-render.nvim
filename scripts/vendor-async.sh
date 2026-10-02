#!/usr/bin/env bash
# Re-sync the vendored copy of vim.async from a Neovim checkout.
#
# The copy exists so Neovim 0.12 — the floor this plugin supports — gets the
# same async runtime 0.13 has built in. It is upstream's code unmodified apart
# from require paths, so re-syncing is a copy plus a substitution; see
# lua/md-render/vendor/README.md.
#
# Usage: scripts/vendor-async.sh <path-to-neovim-checkout> [ref]
set -euo pipefail

nvim_repo=${1:?usage: $0 <path-to-neovim-checkout> [ref]}
ref=${2:-origin/master}
root=$(cd "$(dirname "$0")/.." && pwd)
vendor=$root/lua/md-render/vendor

# Stage every upstream file before touching the working copy. Invalid refs or
# upstream layout changes must not leave the plugin with a partial runtime.
revision=$(git -C "$nvim_repo" rev-parse --verify "$ref^{commit}")
stage=$(mktemp -d "$root/lua/md-render/.vendor-async.XXXXXX")
published=0
cleanup() {
  local status=$?
  if [ -d "$stage/previous" ] && [ "$published" -eq 0 ]; then
    if [ -e "$vendor" ] || ! mv "$stage/previous" "$vendor"; then
      echo "error: rollback failed; previous vendor tree preserved at $stage/previous" >&2
      return 1
    fi
  fi
  rm -rf "$stage"
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp -a "$vendor" "$stage/vendor"
dest=$stage/vendor/async
mkdir -p "$dest"

show() { git -C "$nvim_repo" show "$revision:runtime/lua/vim/$1"; }

files=("$dest.lua")
show async.lua >"$dest.lua"
for mod in _core _event _future _queue _runtime _semaphore; do
  files+=("$dest/$mod.lua")
  show "async/$mod.lua" >"$dest/$mod.lua"
done

# vim.async reaches outside its own tree for two error helpers, which upstream
# keeps in a marked block inside an otherwise unrelated grab bag of a file.
# Take the block, not the file.
# The marker contains slashes, so address it with sed's \%...% delimiter form.
marker='Generated from async.nvim/lua/async/_errors.lua'
helpers=$(show _core/util.lua | sed -n "\%$marker: start%,\%$marker: end%p")
if ! grep -Fq "$marker: end" <<<"$helpers" ||
   ! grep -q 'function M._normalize_error' <<<"$helpers" ||
   ! grep -q 'function M._stringify_error' <<<"$helpers"; then
  echo "error: the _errors block in _core/util.lua no longer looks as expected" >&2
  exit 1
fi
{
  echo "-- Extracted from runtime/lua/vim/_core/util.lua; see ../README.md."
  echo
  echo "local M = {}"
  echo
  echo "$helpers"
  echo
  echo "return M"
} >"$dest/_util.lua"
files+=("$dest/_util.lua")

# Point the copy's requires at where it now lives.
perl -pi -e "
  s{require\('vim\.async\.}{require('md-render.vendor.async.}g;
  s{require\('vim\._core\.util'\)}{require('md-render.vendor.async._util')}g;
" "${files[@]}"

for file in "${files[@]}"; do
  [ -s "$file" ] || { echo "error: empty upstream file: $file" >&2; exit 1; }
done
printf '%s\n' "$revision" >"$dest/REVISION"
# ponytail: two renames allow a crash gap; atomic exchange is needed for crash safety.
mv "$vendor" "$stage/previous"
mv "$stage/vendor" "$vendor"
published=1
echo "Vendored vim.async from $nvim_repo at $revision"
