#!/usr/bin/env bash
set -euo pipefail

series=${1:?FFmpeg series required}
suite=${2:?baseline or observation required}
case "$series:$suite" in
  9.0:baseline|9.0:observation) floating=false ;;
  master:observation) floating=true ;;
  *) echo "Unsupported FFmpeg input: $series:$suite" >&2; exit 1 ;;
esac
install_dir="$RUNNER_TEMP/md-render-ffmpeg/$series"
results="$RUNNER_TEMP/md-render-media-results"
mkdir -p "$results"
# A failed install must never leave a usable previous version at this path.
rm -rf "$install_dir"
mkdir -p "$install_dir"

if "$floating"; then
  asset_name=ffmpeg-master-latest-linux64-gpl.tar.xz
  gh api repos/BtbN/FFmpeg-Builds/releases/tags/latest > "$results/ffmpeg-$series-release.json"
  read -r url checksum < <(python3 - "$results/ffmpeg-$series-release.json" "$asset_name" <<'PY'
import json, sys
release = json.load(open(sys.argv[1]))
asset, = [a for a in release["assets"] if a["name"] == sys.argv[2]]
digest = asset["digest"]
assert digest.startswith("sha256:") and len(digest) == 71, "missing asset SHA-256"
print(asset["browser_download_url"], digest.removeprefix("sha256:"))
PY
  )
  archive="$install_dir/download.tar.xz"
else
  read -r _ url checksum < <(awk -F '\t' -v series="$series" '$1 == series { print; found = 1 } END { if (!found) exit 1 }' .github/ci/ffmpeg-archives.tsv)
  mkdir -p "$RUNNER_TEMP/md-render-ffmpeg-archives"
  archive="$RUNNER_TEMP/md-render-ffmpeg-archives/$checksum.tar.xz"
fi
printf 'suite=%s\nseries=%s\nurl=%s\nsha256=%s\ncache=%s\n' \
  "$suite" "$series" "$url" "$checksum" "$([ -f "$archive" ] && echo hit || echo miss)" \
  | tee "$results/ffmpeg-$series-install.txt"
if [ ! -f "$archive" ]; then
  curl --fail --silent --show-error --location --connect-timeout 10 --max-time 240 \
    "$url" --output "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check -
tar -xJf "$archive" -C "$install_dir" --strip-components=1
for tool in ffmpeg ffprobe; do
  test -x "$install_dir/bin/$tool"
  actual=$(PATH="$install_dir/bin:$PATH" command -v "$tool")
  test "$actual" = "$install_dir/bin/$tool"
  printf '%s\n' "$actual" | tee -a "$results/ffmpeg-$series-install.txt"
  "$actual" -version > "$results/$tool-$series-version.txt"
  "$actual" -buildconf > "$results/$tool-$series-buildconf.txt" 2>&1
  head -n 1 "$results/$tool-$series-version.txt"
  if [ "$series" != master ]; then
    grep -Eq "^$tool version n?${series//./\\.}([.-]| )" "$results/$tool-$series-version.txt"
  fi
done
