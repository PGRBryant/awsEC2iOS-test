# Roadmap — iOS Simulator Density on EC2 Mac

**The question:** how many iOS simulators can one Mac reliably run in CI, and
what breaks first? The deliverable is a number with a graph behind it: the
**reliable working point** and the **hard ceiling**.

Ordering principle: **verify before you pay.** Every phase that can run on free
hardware (mocks, then GitHub's hosted macOS runners) comes before the 24-hour
EC2 Dedicated Host clock ever starts.

Legend: ✅ done · 🔄 in flight · ⬜ not started

## Phase 0 — Local harness (zero hardware)

- ✅ Orchestrator `harness/sweep.sh`: create → boot → install → launch →
  verify-render → sample → teardown; one CSV row per (N, trial)
- ✅ Mock `simctl` with fault injection + `--dry-run` (runs on any OS)
  — caught a `pipefail` boot-detection bug before any paid hardware
- ✅ Analyzer: working point + hard ceiling, MB-per-sim RAM model,
  per-EC2-instance ceiling predictions, `--report` markdown
- ✅ Cross-machine comparison tool `harness/compare.py`

## Phase 1 — App & per-sim verification

- ✅ Trivial SwiftUI app (XcodeGen, no checked-in pbxproj); built once,
  installed into every sim
- ✅ Per-sim render check via screenshot byte-size (booted ≠ working)
- ✅ XCUITest interactivity check (`make uitest`)

## Phase 2 — Real Apple hardware, free (hosted CI)

- ✅ CI on every PR: Linux dry-run gates + real `xcodebuild` + mini
  real-simulator sweep on GitHub-hosted macOS runners
- ✅ Real build proven; device/runtime pairing bug found & fixed (run #1)
- ✅ **Green real-simulator smoke** (run #2): iPhone 17 Pro Max / iOS 26.2,
  N = 1–3 all boot + render on a 7 GB runner. First real RAM model:
  **~267 MB/sim** over a 5.5 GB base → predicted ceilings of ~31 (M1/16 GB)
  up to **~135 sims (M4 Pro/48 GB)** — RAM-bound only; CPU or the ~2,500
  process/user wall may bind first, which is exactly what Phase 5 measures

## Phase 3 — AWS provisioning (the 24h clock)

- ✅ `aws/provision.sh` / `aws/teardown.sh` / runbook (SSM-resolved AMI,
  auto AZ, SSH scoped to caller IP, 24h-aware teardown)
- 🔄 Mac Dedicated Host quota ≥ 1 — requested, awaiting AWS
- ⬜ Billing budget + release-at-24h reminder
- ⬜ Host allocated, instance up, SSH verified

## Phase 4 — CI on the paid box

- ✅ Dispatch workflow `sweep.yml` (N / repeats / device inputs, artifacts)
- ⬜ Self-hosted Actions runner registered on the EC2 Mac

## Phase 5 — The experiment

- ⬜ Full N-sweep to failure with repeats; failure mode logged at the ceiling
- ⬜ Process/fd limit tuning if that wall arrives before RAM

## Phase 6 — The answer

- ✅ Report generator (`analyze.py --report`)
- ⬜ Final `report.md` committed: the number, the knee, what broke first

## Phase 7 — Optional extras

- ⬜ Second instance type / laptop-vs-cloud comparison (`compare.py`)
- ⬜ Limit-pushing within the same 24h window
