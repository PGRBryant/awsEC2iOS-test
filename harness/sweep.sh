#!/usr/bin/env bash
# sweep.sh — the density experiment.
#
# For each level N (concurrent booted simulators) it: creates N sims, boots them,
# installs + launches the app in each, verifies each actually rendered, samples
# host resources, then tears everything down. One CSV row per (level, repeat).
#
# Runs on any Mac with Xcode. Deliberately does NOT `set -e`: failures at the
# ceiling are the data we're collecting, so every step is guarded and recorded.
set -uo pipefail

# ---------------------------------------------------------------------------
# defaults / args
# ---------------------------------------------------------------------------
LEVELS="1 2 4 8 16"           # values of N to sweep
DEVICE=""                     # device type; empty/"auto" = newest iPhone available
RUNTIME=""                   # iOS runtime id; auto-detected (newest) if empty
APP=""                       # path to prebuilt .app (from bootstrap.sh)
REPEATS=3                     # trials per level (for variance)
BOOT_TIMEOUT=180              # seconds to wait for a sim to reach Booted
LAUNCH_TIMEOUT=30             # seconds to wait for app launch + render
OUT_DIR=""                   # results dir; auto-timestamped if empty
BUNDLE_ID="com.simdensity.app"
KEEP_GOING=1                  # keep sweeping to higher N after a level fails
SHOT_MIN_BYTES=8000           # a screenshot smaller than this ~= nothing rendered
DRY_RUN=0                     # 1 = use harness/mock/simctl (no Mac needed)
MOCK_SIMCTL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mock/simctl"
PROFILE="IDLE"                # app load profile: IDLE | ANIMATE | SCROLL
SAMPLE_INTERVAL=2             # seconds between timeline samples (0 = off)

usage() {
  cat <<EOF
Usage: sweep.sh --app <path-to-.app> [options]

  --app PATH           Prebuilt .app to install (required). See scripts/bootstrap.sh
  --levels "1 2 4 8"   Space-separated N values to sweep      (default: "$LEVELS")
  --device NAME        Simulator device type      (default: auto — newest iPhone)
  --runtime ID         iOS runtime id (e.g. com.apple.CoreSimulator.SimRuntime.iOS-17-5)
                       Auto-detects newest available iOS if omitted.
  --repeats N          Trials per level                       (default: $REPEATS)
  --boot-timeout S     Per-sim boot deadline, seconds         (default: $BOOT_TIMEOUT)
  --launch-timeout S   Per-sim launch/render deadline         (default: $LAUNCH_TIMEOUT)
  --out DIR            Results directory                      (default: results/<timestamp>)
  --profile P          App load profile: IDLE | ANIMATE | SCROLL   (default: IDLE)
  --sample-interval S  Seconds between timeline.csv samples; 0=off (default: $SAMPLE_INTERVAL)
  --stop-on-fail       Stop the sweep at the first level that isn't 100% clean
  --dry-run            Use the mock simctl (harness/mock/simctl); runs on any OS.
                       --app becomes optional. Fault-injection via MOCK_* env vars.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app)            APP="$2"; shift 2;;
    --levels)         LEVELS="$2"; shift 2;;
    --device)         DEVICE="$2"; shift 2;;
    --runtime)        RUNTIME="$2"; shift 2;;
    --repeats)        REPEATS="$2"; shift 2;;
    --boot-timeout)   BOOT_TIMEOUT="$2"; shift 2;;
    --launch-timeout) LAUNCH_TIMEOUT="$2"; shift 2;;
    --out)            OUT_DIR="$2"; shift 2;;
    --profile)        PROFILE="$2"; shift 2;;
    --sample-interval) SAMPLE_INTERVAL="$2"; shift 2;;
    --stop-on-fail)   KEEP_GOING=0; shift;;
    --dry-run)        DRY_RUN=1; shift;;
    -h|--help)        usage; exit 0;;
    *) echo "unknown arg: $1" >&2; usage; exit 2;;
  esac
done

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
c_info() { printf '\033[36m[sweep]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m[sweep]\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m[sweep]\033[0m %s\n' "$*" >&2; }

if [ "$DRY_RUN" -eq 1 ]; then
  [ -x "$MOCK_SIMCTL" ] || { c_err "mock simctl missing/not executable: $MOCK_SIMCTL"; exit 1; }
  # --app is optional in dry-run: fabricate one so the install path still executes
  if [ -z "$APP" ]; then
    APP="${TMPDIR:-/tmp}/simdensity-dryrun.app"
    mkdir -p "$APP"
  fi
  c_warn "DRY RUN — using mock simctl ($MOCK_SIMCTL); results are synthetic"
else
  command -v xcrun >/dev/null 2>&1 || { c_err "xcrun not found — need Xcode command line tools"; exit 1; }
  [ -n "$APP" ] || { c_err "--app is required"; usage; exit 2; }
fi
[ -d "$APP" ] || { c_err "app not found: $APP"; exit 2; }

simctl() {
  if [ "$DRY_RUN" -eq 1 ]; then "$MOCK_SIMCTL" "$@"; else xcrun simctl "$@"; fi
}

# byte size of a file, macOS (stat -f) or GNU (stat -c)
filesize() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

# Newest iPhone SUPPORTED BY the chosen runtime. Pairing matters: an
# unsupported device+runtime pair creates fine but never boots (found the hard
# way on a hosted runner: global devicetypes list ends at iPhone 6s Plus, which
# iOS 26 can't boot). Falls back to the global list, sorted by model number.
detect_device() {
  simctl list runtimes --json | RUNTIME="$RUNTIME" python3 -c '
import json,os,re,sys
rt=os.environ["RUNTIME"]
d=json.load(sys.stdin)
sdt=[]
for r in d.get("runtimes",[]):
    if r.get("identifier")==rt:
        sdt=r.get("supportedDeviceTypes",[])
def pick(types):
    ph=[t for t in types if "iPhone" in t.get("name","") and "SE" not in t.get("name","")]
    def key(t):
        m=re.search(r"iPhone (\d+)",t.get("name",""))
        return (int(m.group(1)) if m else 0, t.get("name",""))
    ph.sort(key=key)
    return ph[-1]["identifier"] if ph else ""
print(pick(sdt))
'
}

detect_device_fallback() {
  simctl list devicetypes --json | python3 -c '
import json,re,sys
d=json.load(sys.stdin)
ph=[t for t in d.get("devicetypes",[]) if "iPhone" in t.get("name","") and "SE" not in t.get("name","")]
def key(t):
    m=re.search(r"iPhone (\d+)",t.get("name",""))
    return (int(m.group(1)) if m else 0, t.get("name",""))
ph.sort(key=key)
print(ph[-1]["identifier"] if ph else "")
'
}

# Newest available iOS runtime id, via python3 JSON parse (robust vs text scraping).
detect_runtime() {
  simctl list runtimes --json | python3 -c '
import json,sys
d=json.load(sys.stdin)
ios=[r for r in d.get("runtimes",[]) if r.get("isAvailable") and "iOS" in r.get("name","")]
ios.sort(key=lambda r: r.get("version",""))
print(ios[-1]["identifier"] if ios else "")
'
}

# ms since epoch (python3 avoids GNU-date dependency)
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

# NB: capture-then-match, NOT `| grep -q`: grep -q exits on first match and the
# resulting SIGPIPE to simctl + pipefail reads as failure whenever N>1.
is_booted() {
  local out; out="$(simctl list devices booted 2>/dev/null)"
  case "$out" in *"$1"*) return 0;; *) return 1;; esac
}

# Poll until a sim reports Booted or the deadline passes. Echoes boot ms or "timeout".
wait_booted() {
  local udid="$1" deadline=$(( $(date +%s) + BOOT_TIMEOUT )) start
  start="$(now_ms)"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if is_booted "$udid"; then echo $(( $(now_ms) - start )); return 0; fi
    sleep 1
  done
  echo "timeout"; return 1
}

# Host resource snapshot -> "mem_used_mb,mem_total_mb,load1,proc_count,swap_used_mb"
sample_metrics() {
  if [ "$DRY_RUN" -eq 1 ]; then
    # synthetic but shaped like reality: ~900MB per booted sim over a 4GB base
    local b; b="$(simctl list devices booted 2>/dev/null | grep -c Booted || true)"
    echo "$(( 4000 + b * 900 )),24576,$b.5,$(( 400 + b * 60 )),0"
    return
  fi
  python3 - <<'PY'
import subprocess, re
def sh(c): return subprocess.run(c, shell=True, capture_output=True, text=True).stdout
total = int(sh("sysctl -n hw.memsize") or 0)
# vm_stat: active + wired + compressed pages ~= memory in use
vs = sh("vm_stat")
m = re.search(r"page size of (\d+)", vs); page = int(m.group(1)) if m else 16384
def pages(k):
    mm = re.search(k + r":\s+(\d+)", vs); return int(mm.group(1)) if mm else 0
used = (pages("Pages active") + pages("Pages wired down") + pages("Pages occupied by compressor")) * page
load1 = (sh("sysctl -n vm.loadavg").strip().strip("{}").split() or ["0"])[0]
proc = sh("ps -ax | wc -l").strip()
sw = sh("sysctl -n vm.swapusage")
swm = re.search(r"used = ([\d.]+)M", sw); swap = swm.group(1) if swm else "0"
print(f"{used//1048576},{total//1048576},{load1},{proc},{swap}")
PY
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------
if [ -z "$RUNTIME" ]; then
  c_info "detecting newest iOS runtime..."
  RUNTIME="$(detect_runtime)"
  [ -n "$RUNTIME" ] || { c_err "no available iOS runtime found (open Xcode > Settings > Platforms)"; exit 1; }
fi
c_info "runtime: $RUNTIME"

[ "$DEVICE" = "auto" ] && DEVICE=""
if [ -z "$DEVICE" ]; then
  DEVICE="$(detect_device)"
  [ -n "$DEVICE" ] || DEVICE="$(detect_device_fallback)"
  [ -n "$DEVICE" ] || { c_err "no iPhone device type found via simctl"; exit 1; }
fi
c_info "device: $DEVICE"

TS="$(date +%Y%m%d-%H%M%S)"
[ -n "$OUT_DIR" ] || OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results/$TS"
mkdir -p "$OUT_DIR/screens"
CSV="$OUT_DIR/results.csv"
echo "level,repeat,device,runtime,profile,boots_ok,installs_ok,launches_ok,renders_ok,boot_wall_ms,mem_used_mb,mem_total_mb,load1,proc_count,swap_used_mb,failure_mode" > "$CSV"
c_info "writing results to $CSV (profile=$PROFILE)"

# the app reads SD_PROFILE from its environment; simctl forwards SIMCTL_CHILD_* vars
export SIMCTL_CHILD_SD_PROFILE="$PROFILE"

# ---- timeline sampler: background loop writing per-interval host samples ----
TIMELINE="$OUT_DIR/timeline.csv"
echo "ts_ms,level,repeat,mem_used_mb,mem_total_mb,load1,proc_count,swap_used_mb,booted" > "$TIMELINE"
SAMPLER_PID=""
booted_count() { simctl list devices booted 2>/dev/null | grep -c Booted || true; }
start_sampler() { # $1=level $2=repeat
  [ "$SAMPLE_INTERVAL" -gt 0 ] || return 0
  (
    while :; do
      printf '%s,%s,%s,%s,%s\n' "$(now_ms)" "$1" "$2" "$(sample_metrics)" "$(booted_count)" >> "$TIMELINE"
      sleep "$SAMPLE_INTERVAL"
    done
  ) &
  SAMPLER_PID=$!
}
stop_sampler() {
  [ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null && wait "$SAMPLER_PID" 2>/dev/null
  SAMPLER_PID=""
}

CREATED=()  # udids created this run (for cleanup on exit)
cleanup() {
  stop_sampler
  c_warn "cleaning up ${#CREATED[@]} simulators..."
  for u in "${CREATED[@]:-}"; do
    [ -n "$u" ] || continue
    simctl shutdown "$u"  >/dev/null 2>&1
    simctl delete   "$u"  >/dev/null 2>&1
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM   # triggers the EXIT trap exactly once

# ---------------------------------------------------------------------------
# one trial at level N
# ---------------------------------------------------------------------------
run_trial() {
  local n="$1" rep="$2"
  local udids=() boots_ok=0 installs_ok=0 launches_ok=0 renders_ok=0
  local failure="" boot_wall=0

  # -- create N sims --
  local i name u
  for i in $(seq 1 "$n"); do
    name="sd-${n}-${rep}-${i}"
    u="$(simctl create "$name" "$DEVICE" "$RUNTIME" 2>/dev/null)"
    if [ -z "$u" ]; then failure="create"; break; fi
    udids+=("$u"); CREATED+=("$u")
  done
  [ -z "$failure" ] || { record_row "$n" "$rep" 0 0 0 0 0 "$failure"; teardown "${udids[@]:-}"; return; }

  # -- boot all N, then wait for each (boots overlap; wall = slowest) --
  local t0; t0="$(now_ms)"
  # keep boot stderr: unsupported pairings and runtime problems surface here
  for u in "${udids[@]}"; do simctl boot "$u" >/dev/null 2>>"$OUT_DIR/boot-errors.log"; done
  for u in "${udids[@]}"; do
    if [ "$(wait_booted "$u")" != "timeout" ]; then
      boots_ok=$((boots_ok+1))
    else
      [ -n "$failure" ] || failure="boot_timeout"
    fi
  done
  boot_wall=$(( $(now_ms) - t0 ))

  # -- install + launch + verify render on every booted sim --
  for u in "${udids[@]}"; do
    is_booted "$u" || continue
    if simctl install "$u" "$APP" >/dev/null 2>&1; then
      installs_ok=$((installs_ok+1))
    else
      [ -n "$failure" ] || failure="install"; continue
    fi
    if simctl launch "$u" "$BUNDLE_ID" >/dev/null 2>&1; then
      launches_ok=$((launches_ok+1))
    else
      [ -n "$failure" ] || failure="launch"; continue
    fi
    # render check: a real screen produces a non-trivial screenshot. Retry up
    # to LAUNCH_TIMEOUT — a loaded host can take a while to first-paint.
    local shot="$OUT_DIR/screens/n${n}-r${rep}-${u:0:6}.png"
    local sz=0 rdeadline=$(( $(date +%s) + LAUNCH_TIMEOUT ))
    while [ "$(date +%s)" -lt "$rdeadline" ]; do
      simctl io "$u" screenshot "$shot" >/dev/null 2>&1
      sz="$(filesize "$shot")"
      [ "$sz" -ge "$SHOT_MIN_BYTES" ] && break
      sleep 2
    done
    if [ "$sz" -ge "$SHOT_MIN_BYTES" ]; then
      renders_ok=$((renders_ok+1))
    else
      [ -n "$failure" ] || failure="no_render"
    fi
  done

  [ "$boots_ok" -eq "$n" ] || : # failure already set above
  if [ -z "$failure" ] && [ "$renders_ok" -lt "$n" ]; then failure="partial_render"; fi

  local metrics; metrics="$(sample_metrics)"
  record_row "$n" "$rep" "$boots_ok" "$installs_ok" "$launches_ok" "$renders_ok" "$boot_wall" "$failure" "$metrics"
  teardown "${udids[@]}"
}

record_row() {
  # level repeat boots installs launches renders boot_wall failure [metrics]
  local metrics="${9:-0,0,0,0,0}"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$1" "$2" "$DEVICE" "$RUNTIME" "$PROFILE" "$3" "$4" "$5" "$6" "$7" "$metrics" "${8:-}" >> "$CSV"
}

teardown() {
  for u in "$@"; do
    [ -n "$u" ] || continue
    simctl shutdown "$u" >/dev/null 2>&1
    simctl delete   "$u" >/dev/null 2>&1
    # drop from CREATED so the EXIT trap doesn't re-handle it
    local nc=() x
    for x in "${CREATED[@]:-}"; do
      [ -n "$x" ] && [ "$x" != "$u" ] && nc+=("$x")
    done
    CREATED=()
    [ "${#nc[@]}" -eq 0 ] || CREATED=("${nc[@]}")
  done
}

# ---------------------------------------------------------------------------
# sweep
# ---------------------------------------------------------------------------
c_info "device=$DEVICE  levels=[$LEVELS]  repeats=$REPEATS"
for n in $LEVELS; do
  level_clean=1
  for rep in $(seq 1 "$REPEATS"); do
    c_info "level N=$n  trial $rep/$REPEATS"
    start_sampler "$n" "$rep"
    run_trial "$n" "$rep"
    stop_sampler
    # was the last row clean? (renders_ok == n and no failure mode)
    last="$(tail -1 "$CSV")"
    renders="$(echo "$last" | cut -d, -f9)"
    fmode="$(echo "$last" | cut -d, -f16)"
    if [ "$renders" != "$n" ] || [ -n "$fmode" ]; then
      level_clean=0
      c_warn "N=$n trial $rep degraded (renders=$renders/$n, mode='${fmode:-none}')"
    fi
  done
  if [ "$level_clean" -eq 0 ] && [ "$KEEP_GOING" -eq 0 ]; then
    c_warn "stopping: level N=$n was not clean and --stop-on-fail is set"
    break
  fi
done

c_info "sweep complete. Analyze with: python3 harness/analyze.py \"$CSV\""
echo "$CSV"
