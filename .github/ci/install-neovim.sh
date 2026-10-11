#!/usr/bin/env bash
set -euo pipefail

version=${1:?Neovim version required}
case "$version" in
  v0.12.0|v0.12.5) fixed=true ;;
  stable|nightly) fixed=false ;;
  *) echo "Unsupported Neovim version: $version" >&2; exit 1 ;;
esac
case "$(uname -s):$(uname -m)" in
  Linux:x86_64) platform=linux-x86_64 ;;
  Darwin:arm64) platform=macos-arm64 ;;
  *) echo "Unsupported Neovim platform" >&2; exit 1 ;;
esac
: "${RUNNER_TEMP:?RUNNER_TEMP required}" "${GITHUB_PATH:?GITHUB_PATH required}"
install_dir="$RUNNER_TEMP/md-render-tools/neovim/$version"
results="$RUNNER_TEMP/md-render-neovim-results"
mkdir -p "$results"
# A failed install must never leave a usable previous version at this path.
rm -rf "$install_dir"
mkdir -p "$install_dir"
download=$(mktemp "$RUNNER_TEMP/md-render-neovim-download.XXXXXX")
trap 'status=$?; rm -f "$download"; if [ "$status" -ne 0 ]; then rm -rf "$install_dir"; fi' EXIT

sha256() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

asset="nvim-$platform.tar.gz"
if "$fixed"; then
  manifest="$(dirname "$0")/neovim-archives.tsv"
  entry=$(awk -F '\t' -v version="$version" -v platform="$platform" \
    '$1 == version && $2 == platform { print; count++ } END { if (count != 1) exit 1 }' "$manifest")
  IFS=$'\t' read -r _ _ url checksum <<< "$entry"
  resolved_tag="$version"
  commit=archive-pinned
  digest="sha256:$checksum"
  mkdir -p "$RUNNER_TEMP/md-render-cache/neovim"
  archive="$RUNNER_TEMP/md-render-cache/neovim/$checksum.tar.gz"
else
  metadata=$(gh api "repos/neovim/neovim/releases/tags/$version" --jq \
    ". as \$release | .assets | map(select(.name == \"$asset\")) | if length != 1 then error(\"expected one Neovim asset\") else [\$release.tag_name, \$release.target_commitish, .[0].browser_download_url, (.[0].digest // \"unavailable\")] | @tsv end")
  IFS=$'\t' read -r resolved_tag commit url digest <<< "$metadata"
  test "$resolved_tag" = "$version"
  checksum=${digest#sha256:}
  archive="$download"
fi
test "$url" = "https://github.com/neovim/neovim/releases/download/$version/$asset"
if [ "$digest" != unavailable ] && ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "Invalid Neovim asset digest: $digest" >&2
  exit 1
fi
printf 'requested=%s\nresolved_tag=%s\ncommit=%s\nplatform=%s\nurl=%s\nupstream_digest=%s\ncache=%s\n' \
  "$version" "$resolved_tag" "$commit" "$platform" "$url" "$digest" \
  "$([ "$fixed" = true ] && [ -f "$archive" ] && echo hit || echo miss)" \
  | tee "$results/install.txt"
if [ "$fixed" = false ] || [ ! -f "$archive" ]; then
  curl --fail --silent --show-error --location --connect-timeout 10 --max-time 240 \
    "$url" --output "$download"
  archive_to_check="$download"
else
  archive_to_check="$archive"
fi
actual_checksum=$(sha256 "$archive_to_check")
printf 'sha256=%s\n' "$actual_checksum" | tee -a "$results/install.txt"
if [ "$digest" != unavailable ]; then
  test "$actual_checksum" = "$checksum"
fi
if [ "$fixed" = true ] && [ "$archive_to_check" = "$download" ]; then
  mv "$download" "$archive"
fi
tar -xzf "$archive" -C "$install_dir" --strip-components=1
test -x "$install_dir/bin/nvim"
actual=$(PATH="$install_dir/bin:$PATH" command -v nvim)
test "$actual" = "$install_dir/bin/nvim"
"$actual" --version > "$results/version.txt"
version_line=$(head -n 1 "$results/version.txt")
if "$fixed"; then
  test "$version_line" = "NVIM $version"
elif [ "$version" = stable ]; then
  [[ "$version_line" =~ ^NVIM\ v[0-9]+\.[0-9]+\.[0-9]+$ ]]
else
  [[ "$version_line" =~ ^NVIM\ v[0-9]+\.[0-9]+\.[0-9]+-dev ]]
fi
printf 'executable=%s\nversion=%s\n' "$actual" "$version_line" | tee -a "$results/install.txt"
printf '%s\n' "$install_dir/bin" >> "$GITHUB_PATH"
