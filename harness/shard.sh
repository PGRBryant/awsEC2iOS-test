#!/usr/bin/env bash
# shard.sh — the throughput experiment: split a UI-test suite across N parallel
# simulators and measure suite wall-time vs N. The speedup curve is what a
# phone team actually buys cloud simulators for (faster PR feedback); the
# density sweep (sweep.sh) is the capacity behind it.
#
# Real mode needs a prior `xcodebuild build-for-testing` (make bootstrap-tests);
# --dry-run runs the whole orchestration against mocks on any OS.
#
# One CSV row per level: results/<run>/speedup.csv
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

LEVELS="1 2 4"                # shard counts to measure
MANIFEST="$REPO_ROOT/app/UITests/tests.txt"
XCTESTRUN=""                 # auto-discovered under app/build if empty
OUT_DIR=""
BOOT_TIMEOUT=420
DRY_RUN=0
MOCK_SIMCTL="$HERE/mock/simctl"
MOCK_XCODEBUILD="$HERE/mock/xcodebuild"

usage() {
  cat <<EOF
Usage: shard.sh [options]
  --levels "1 2 4"     Shard counts to measure           (default: "$LEVELS")
  --manifest FILE      Test-id manifest, one per line    (default: app/UITests/tests.txt)
  --xctestrun FILE     .xctestrun from build-for-testing (default: newest under app/build)
  --boot-timeout S     Per-sim boot deadline             (default: $BOOT_TIMEOUT)
  --out DIR            Results directory                 (default: results/<timestamp>-shard)
  --dry-run            Mock simctl + xcodebuild; runs on any OS
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --levels)       LEVELS="$2"; shift 2;;
    --manifest)     MANIFEST="$2"; shift 2;;
    --xctestrun)    XCTESTRUN="$2"; shift 2;;
    --boot-timeout) BOOT_TIMEOUT="$2"; shift 2;;
    --out)          OUT_DIR="$2"; shift 2;;
    --dry-run)      DRY_RUN=1; shift;;
    -h|--help)      usage; exit 0;;
    *) echo "unknown arg: $1" >&2; usage; exit 2;;
  esac
done

c_info() { printf '\033[36m[shard]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m[shard]\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m[shard]\033[0m %s\n' "$*" >&2; }

simctl() {
  if [ "$DRY_RUN" -eq 1 ]; then "$MOCK_SIMCTL" "$@"; else xcrun simctl "$@"; fi
}
xcb() {
  if [ "$DRY_RUN" -eq 1 ]; then "$MOCK_XCODEBUILD" "$@"; else xcodebuild "$@"; fi
}
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

[ -f "$MANIFEST" ] || { c_err "manifest not found: $MANIFEST"; exit 2; }
# no mapfile: macOS ships bash 3.2
TESTS=()
while IFS= read -r _line; do
  [ -n "$_line" ] && TESTS+=("$_line")
done < "$MANIFEST"
TOTAL="${#TESTS[@]}"
[ "$TOTAL" -gt 0 ] || { c_err "manifest is empty"; exit 2; }

if [ "$DRY_RUN" -eq 0 ]; then
  command -v xcrun >/dev/null 2>&1 || { c_err "xcrun not found"; exit 1; }
  if [ -z "$XCTESTRUN" ]; then
    XCTESTRUN="$(ls -t "$REPO_ROOT"/app/build/Build/Products/*.xctestrun 2>/dev/null | head -1)"
  fi
  [ -n "$XCTESTRUN" ] && [ -f "$XCTESTRUN" ] || {
    c_err "no .xctestrun found — run 'make bootstrap-tests' first"; exit 1; }
fi

# runtime + device via the same supported-pairing logic as sweep.sh
RUNTIME="$(simctl list runtimes --json | python3 -c '
import json,sys
d=json.load(sys.stdin)
ios=[r for r in d.get("runtimes",[]) if r.get("isAvailable") and "iOS" in r.get("name","")]
ios.sort(key=lambda r: r.get("version",""))
print(ios[-1]["identifier"] if ios else "")
')"
[ -n "$RUNTIME" ] || { c_err "no iOS runtime available"; exit 1; }
DEVICE="$(simctl list runtimes --json | RUNTIME="$RUNTIME" python3 -c '
import json,os,re,sys
rt=os.environ["RUNTIME"]
d=json.load(sys.stdin)
sdt=[]
for r in d.get("runtimes",[]):
    if r.get("identifier")==rt: sdt=r.get("supportedDeviceTypes",[])
ph=[t for t in sdt if "iPhone" in t.get("name","") and "SE" not in t.get("name","")]
def key(t):
    m=re.search(r"iPhone (\d+)",t.get("name",""))
    return (int(m.group(1)) if m else 0, t.get("name",""))
ph.sort(key=key)
print(ph[-1]["identifier"] if ph else "")
')"
[ -n "$DEVICE" ] || { c_err "no supported iPhone device type"; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
[ -n "$OUT_DIR" ] || OUT_DIR="$REPO_ROOT/results/$TS-shard"
mkdir -p "$OUT_DIR/logs"
CSV="$OUT_DIR/speedup.csv"
echo "shards,total_tests,wall_ms,passed_shards,failed_shards" > "$CSV"
c_info "suite: $TOTAL tests  levels: [$LEVELS]  out: $OUT_DIR"

CREATED=()
cleanup() {
  for u in "${CREATED[@]:-}"; do
    [ -n "$u" ] || continue
    simctl shutdown "$u" >/dev/null 2>&1
    simctl delete   "$u" >/dev/null 2>&1
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

is_booted() {
  local out; out="$(simctl list devices booted 2>/dev/null)"
  case "$out" in *"$1"*) return 0;; *) return 1;; esac
}

for n in $LEVELS; do
  c_info "level: $n shard(s)"
  udids=()
  for i in $(seq 1 "$n"); do
    u="$(simctl create "shard-$n-$i" "$DEVICE" "$RUNTIME" 2>/dev/null)"
    [ -n "$u" ] || { c_err "sim create failed at shard $i"; break; }
    udids+=("$u"); CREATED+=("$u")
  done
  for u in "${udids[@]}"; do simctl boot "$u" >/dev/null 2>&1; done
  deadline=$(( $(date +%s) + BOOT_TIMEOUT )); ready=0
  while [ "$(date +%s)" -lt "$deadline" ] && [ "$ready" -lt "${#udids[@]}" ]; do
    ready=0
    for u in "${udids[@]}"; do is_booted "$u" && ready=$((ready+1)); done
    [ "$ready" -lt "${#udids[@]}" ] && sleep 2
  done
  if [ "$ready" -lt "${#udids[@]}" ]; then
    c_warn "only $ready/${#udids[@]} sims booted — recording level as failed"
    echo "$n,$TOTAL,0,0,$n" >> "$CSV"
    for u in "${udids[@]}"; do simctl shutdown "$u" >/dev/null 2>&1; simctl delete "$u" >/dev/null 2>&1; done
    continue
  fi

  # round-robin the manifest into n shards, run all shards in parallel
  t0="$(now_ms)"
  pids=()
  for s in $(seq 0 $((n-1))); do
    only_args=()
    for idx in $(seq "$s" "$n" $((TOTAL-1))); do
      only_args+=("-only-testing:${TESTS[$idx]}")
    done
    [ "${#only_args[@]}" -gt 0 ] || continue
    (
      xcb test-without-building \
        ${XCTESTRUN:+-xctestrun "$XCTESTRUN"} \
        -destination "platform=iOS Simulator,id=${udids[$s]}" \
        "${only_args[@]}" \
        > "$OUT_DIR/logs/n${n}-shard${s}.log" 2>&1
    ) &
    pids+=($!)
  done
  passed=0; failed=0
  for p in "${pids[@]}"; do
    if wait "$p"; then passed=$((passed+1)); else failed=$((failed+1)); fi
  done
  wall=$(( $(now_ms) - t0 ))
  echo "$n,$TOTAL,$wall,$passed,$failed" >> "$CSV"
  c_info "  $n shard(s): ${wall}ms  (${passed} passed / ${failed} failed)"

  for u in "${udids[@]}"; do
    simctl shutdown "$u" >/dev/null 2>&1
    simctl delete   "$u" >/dev/null 2>&1
  done
  CREATED=()
done

c_info "speedup data: $CSV"
echo "$CSV"
