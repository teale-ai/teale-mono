#!/usr/bin/env bash
set -euo pipefail

# Record a docked Android supply run on a connected Pixel.
# This script does not generate inference load by itself. Use it while the
# phone is already running Teale supply or alongside a separate request driver.

DEVICE="${DEVICE:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}"
DURATION_MIN="${DURATION_MIN:-${1:-15}}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-30}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/.context/android-supply-bench/$(date +%Y%m%d-%H%M%S)}"
LOGCAT_FILE="$OUT_DIR/logcat.txt"
SUMMARY_FILE="$OUT_DIR/summary.txt"

if [[ -z "$DEVICE" ]]; then
    echo "no adb device connected" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

cleanup() {
    if [[ -n "${LOGCAT_PID:-}" ]]; then
        kill "$LOGCAT_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "device=$DEVICE" | tee "$SUMMARY_FILE"
echo "duration_min=$DURATION_MIN" | tee -a "$SUMMARY_FILE"
echo "sample_seconds=$SAMPLE_SECONDS" | tee -a "$SUMMARY_FILE"
echo "out_dir=$OUT_DIR" | tee -a "$SUMMARY_FILE"

adb -s "$DEVICE" reverse tcp:11436 tcp:11436 >/dev/null 2>&1 || true
adb -s "$DEVICE" logcat -c
adb -s "$DEVICE" logcat -v threadtime -s SupplyService SupplyPM llama-server teale-node >"$LOGCAT_FILE" &
LOGCAT_PID=$!

adb -s "$DEVICE" shell dumpsys battery >"$OUT_DIR/battery-start.txt"
adb -s "$DEVICE" shell dumpsys thermalservice >"$OUT_DIR/thermal-start.txt" 2>/dev/null || true
adb -s "$DEVICE" shell dumpsys activity services com.teale.android/.service.SupplyService \
    >"$OUT_DIR/service-start.txt" 2>/dev/null || true

end_ts=$(( $(date +%s) + DURATION_MIN * 60 ))
sample_idx=0
while [[ "$(date +%s)" -lt "$end_ts" ]]; do
    stamp="$(date +%Y%m%d-%H%M%S)"
    adb -s "$DEVICE" shell dumpsys battery >"$OUT_DIR/battery-$stamp.txt"
    adb -s "$DEVICE" shell dumpsys thermalservice >"$OUT_DIR/thermal-$stamp.txt" 2>/dev/null || true
    adb -s "$DEVICE" shell dumpsys activity services com.teale.android/.service.SupplyService \
        >"$OUT_DIR/service-$stamp.txt" 2>/dev/null || true
    if curl -fsS --max-time 5 http://127.0.0.1:11436/health >"$OUT_DIR/health-$stamp.txt"; then
        echo "[$stamp] health=ok" | tee -a "$SUMMARY_FILE"
    else
        echo "[$stamp] health=fail" | tee -a "$SUMMARY_FILE"
    fi
    sample_idx=$((sample_idx + 1))
    sleep "$SAMPLE_SECONDS"
done

adb -s "$DEVICE" shell dumpsys battery >"$OUT_DIR/battery-end.txt"
adb -s "$DEVICE" shell dumpsys thermalservice >"$OUT_DIR/thermal-end.txt" 2>/dev/null || true
adb -s "$DEVICE" shell dumpsys activity services com.teale.android/.service.SupplyService \
    >"$OUT_DIR/service-end.txt" 2>/dev/null || true

echo "samples=$sample_idx" | tee -a "$SUMMARY_FILE"
echo "logcat=$LOGCAT_FILE" | tee -a "$SUMMARY_FILE"
