#!/usr/bin/env bash
set -euo pipefail

tool=${1:?Expected kitty or tmux}
requested=${2:?Expected a version}
version=$requested
root=${RUNNER_TEMP:?Expected RUNNER_TEMP}/md-terminal
archives=${MD_RENDER_TERMINAL_ARCHIVES:-$RUNNER_TEMP/terminal-archives}

case "$tool:$requested" in
  kitty:0.40.0) checksum=041c6fedd9be2f257d64eee41099a19f1ea525c69214ded5e930ff96ccb6b8a4 ;;
  kitty:0.49.2) checksum=d573618b911e9c461bd421b96c13c74c7f1cb2f1ac9c327818d4ff84366cf5c6 ;;
  kitty:latest)
    release=$(gh api repos/kovidgoyal/kitty/releases/latest)
    version=$(jq -er '.tag_name | ltrimstr("v")' <<< "$release")
    digest=$(jq -er --arg name "kitty-$version-x86_64.txz" \
      '.assets[] | select(.name == $name) | .digest' <<< "$release")
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]
    checksum=${digest#sha256:}
    # Floating downloads never enter the restored fixed-archive cache.
    archives="$root/floating"
    ;;
  tmux:3.4) checksum=551ab8dea0bf505c0ad6b7bb35ef567cdde0ccb84357df142c254f35a23e19aa ;;
  tmux:3.6) checksum=136db80cfbfba617a103401f52874e7c64927986b65b1b700350b6058ad69607 ;;
  *) echo "No verified archive for $tool $requested" >&2; exit 1 ;;
esac

mkdir -p "$archives" "$root"
destination="$root/$tool-$version"
if [[ "$tool" == kitty ]]; then
  archive="$archives/kitty-$version-x86_64.txz"
  url="https://github.com/kovidgoyal/kitty/releases/download/v$version/kitty-$version-x86_64.txz"
else
  archive="$archives/tmux-$version.tar.gz"
  url="https://github.com/tmux/tmux/releases/download/$version/tmux-$version.tar.gz"
fi
if [[ "$requested" == latest || ! -f "$archive" ]]; then
  curl --fail --silent --show-error --location --retry 3 --output "$archive" "$url"
fi
printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check -
echo "Verified $url sha256=$checksum"

# Install into a fresh version directory; a failed version cannot reuse another.
rm -rf "$destination"
mkdir -p "$destination"
if [[ "$tool" == kitty ]]; then
  tar -xJf "$archive" -C "$destination"
  "$destination/bin/kitty" --version
else
  source="$root/tmux-source-$version"
  rm -rf "$source"
  mkdir -p "$source"
  tar -xzf "$archive" -C "$source" --strip-components=1
  (
    cd "$source"
    ./configure --prefix="$destination"
    make -j2
    make install
  )
  [[ $("$destination/bin/tmux" -V) == "tmux $version" ]]
  "$destination/bin/tmux" -V
fi
printf 'bin=%s/bin\nversion=%s\n' "$destination" "$version" >> "${GITHUB_OUTPUT:?Expected GITHUB_OUTPUT}"
