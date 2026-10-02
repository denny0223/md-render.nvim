#!/bin/bash
# macOS window captures; --compare also works without a desktop or terminals.
# Usage: ./tests/run_visual_test.sh [--update|--compare]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PLUGIN_ROOT"
SCREENSHOT_DIR="$PLUGIN_ROOT/tests/screenshots"
REFERENCE_DIR="$SCREENSHOT_DIR/reference"
DIFF_DIR="$SCREENSHOT_DIR/diff"
MODE="${1:-capture}"
# A starting tolerance, to calibrate by inspecting local baselines; not SSIM.
MAX_RMSE="${MD_RENDER_VISUAL_MAX_RMSE:-0.05}"
TERMINAL_PID=""
RUN_DIR="$(mktemp -d)"
SIGNAL_FILE="$RUN_DIR/ready"

log() { echo "[visual-test] $*"; }
err() { echo "[visual-test] FAIL: $*" >&2; }

stop_terminal() {
  # The launcher creates this process group. Never search other processes by name.
  if [ -n "$TERMINAL_PID" ]; then
    kill -TERM -- "-$TERMINAL_PID" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-$TERMINAL_PID" 2>/dev/null || true
    wait "$TERMINAL_PID" 2>/dev/null || true
    TERMINAL_PID=""
  fi
}

cleanup() {
  stop_terminal
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "$MODE" in
  capture|--compare|--update) ;;
  *) err "Usage: $0 [--update|--compare]"; exit 2 ;;
esac
[ "$#" -le 1 ] || { err "Too many arguments"; exit 2; }
command -v magick >/dev/null || { err "ImageMagick (magick) is required"; exit 1; }
python3 - "$MAX_RMSE" <<'PY'
import math
import sys
value = float(sys.argv[1])
if not math.isfinite(value) or not 0 <= value <= 1:
    sys.exit("MD_RENDER_VISUAL_MAX_RMSE must be a finite number from 0 to 1")
PY

mkdir -p "$SCREENSHOT_DIR" "$REFERENCE_DIR" "$DIFF_DIR"
TERMINALS=()
for term in wezterm kitty ghostty; do
  if [ "$MODE" = "--compare" ]; then
    if [ -f "$SCREENSHOT_DIR/$term.png" ] || [ -f "$REFERENCE_DIR/$term.png" ]; then
      TERMINALS+=("$term")
    fi
  elif command -v "$term" >/dev/null; then
    TERMINALS+=("$term")
  fi
done
[ "${#TERMINALS[@]}" -gt 0 ] || { err "No terminal captures to compare or supported terminals to launch"; exit 1; }

launch_terminal() {
  # Python's POSIX session primitive is available on macOS, unlike a setsid CLI.
  # exec retains the owned PID; any GUI child inherits this private process group.
  python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" &
  TERMINAL_PID=$!
}

capture_terminal() {
  local term="$1"
  local title="md-render-visual-test-${RUN_DIR##*/}-$term"
  rm -f "$SIGNAL_FILE"
  export VISUAL_TEST_SIGNAL="$SIGNAL_FILE" VISUAL_TEST_TITLE="$title"
  log "Capturing $term"
  case "$term" in
    wezterm) launch_terminal wezterm start --always-new-process --cwd "$PLUGIN_ROOT" -- \
      nvim -u "$SCRIPT_DIR/visual_test_init.lua" ;;
    kitty) launch_terminal kitty --config NONE \
      --override "initial_window_width=120c" --override "initial_window_height=40c" \
      --override "remember_window_size=no" --directory "$PLUGIN_ROOT" \
      nvim -u "$SCRIPT_DIR/visual_test_init.lua" ;;
    ghostty) launch_terminal ghostty -e nvim -u "$SCRIPT_DIR/visual_test_init.lua" ;;
  esac
  local attempts=0
  while [ ! -s "$SIGNAL_FILE" ]; do
    sleep 0.5
    attempts=$((attempts + 1))
    [ "$attempts" -lt 40 ] || { err "$term: preview timed out"; return 1; }
  done
  sleep 3 # Allow the animation placement to settle after the readiness signal.
  python3 "$SCRIPT_DIR/capture_window.py" --title "$title" "$RUN_DIR/$term.png"
  [ -s "$RUN_DIR/$term.png" ] || { err "$term: capture is empty"; return 1; }
  magick identify "$RUN_DIR/$term.png" >/dev/null
  stop_terminal
}

if [ "$MODE" != "--compare" ]; then
  for term in "${TERMINALS[@]}"; do
    capture_terminal "$term"
  done
  # Every capture must succeed before updating any baseline or previous capture.
  for term in "${TERMINALS[@]}"; do
    cp "$RUN_DIR/$term.png" "$SCREENSHOT_DIR/$term.png"
    if [ "$MODE" = "--update" ]; then
      cp "$RUN_DIR/$term.png" "$REFERENCE_DIR/$term.png"
    fi
  done
fi
if [ "$MODE" = "--update" ]; then
  log "Reference images updated from this run's captures."
  exit 0
fi

pass=0
failed=0
for term in "${TERMINALS[@]}"; do
  actual="$SCREENSHOT_DIR/$term.png"
  reference="$REFERENCE_DIR/$term.png"
  if [ ! -s "$actual" ] || [ ! -s "$reference" ]; then
    err "$term: missing capture or reference (create references with --update)"
    failed=$((failed + 1))
    continue
  fi
  # Request a machine-readable normalized distance on stdout. stderr is diagnostic;
  # it must never be mistaken for a metric, including a number in an error message.
  if ! metric=$(magick "$actual" "$reference" -metric RMSE -compare \
      -write "$DIFF_DIR/$term.png" -format '%[distortion]' info:); then
    err "$term: ImageMagick comparison failed"
    failed=$((failed + 1))
    continue
  fi
  if python3 - "$metric" "$MAX_RMSE" <<'PY'
import math
import sys
try:
    value, maximum = map(float, sys.argv[1:])
except ValueError:
    sys.exit(1)
sys.exit(0 if math.isfinite(value) and 0 <= value <= maximum else 1)
PY
  then
    log "PASS $term: normalized RMSE=$metric (maximum=$MAX_RMSE)"
    pass=$((pass + 1))
  else
    err "$term: invalid or excessive normalized RMSE=$metric (maximum=$MAX_RMSE)"
    failed=$((failed + 1))
  fi
done
log "Results: $pass passed, $failed failed"
[ "$failed" -eq 0 ] && [ "$pass" -gt 0 ]
