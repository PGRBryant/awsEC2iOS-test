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

## Phase 2.5 — Developer realism (free hardware)

What a phone team actually buys cloud sims for is faster PR feedback — these
make the demo mirror that use case, still without AWS spend:

- ✅ Load profiles (`IDLE`/`ANIMATE`/`SCROLL`): density measured under
  app-like work, selectable via `--profile`
- ✅ Sharded test suite (12 UI tests) + `harness/shard.sh`: suite wall-time
  vs shard count — the speedup curve (mock-verified ~1.98×/2, ~3.87×/4)
- ✅ Per-second resource timeline (`timeline.csv`) sampled during sweeps
- ✅ HTML dashboard (`harness/dashboard.py`): self-contained, light+dark,
  CVD-validated palette; CI uploads it as an artifact
- ✅ Edge-AI profile (`INFER`): real on-device neural inference via Vision
  OCR (models ship with the OS — zero bundled assets); per-sim rates
  collected via `simctl get_app_container`; dashboard charts aggregate
  inferences/sec vs N
- ✅ Real-Mac validation complete (PR #3 merged): profiles measured at
  ~267/~356/~1080 MB/sim (idle/animate/infer); edge-AI 30→46→88 inf/s at
  N=1–3 (near-linear on 3 cores); shard suite 12/12 green with an honest
  0.15× speedup on 3 cores — sharding is bought with cores
- ✅ OIDC role for GitHub Actions + manual-dispatch host workflow
  (`aws-provision.yml`): status / provision / teardown, no stored secrets

## Phase 3 — AWS provisioning (the 24h clock)

- ✅ `aws/provision.sh` / `aws/teardown.sh` / runbook (SSM-resolved AMI,
  auto AZ, SSH scoped to caller IP, 24h-aware teardown)
- ✅ Mac Dedicated Host quota approved: 1× `mac2-m2pro` (12 cores / 32 GB),
  us-east-1 — see `aws/RUNDAY.md` for the 24-hour run plan
- ✅ Release-at-24h reminders armed (T+22h ≈ 10:50Z, T+24h ≈ 12:50Z Aug 16)
- ✅ Host allocated (h-08263dbbdfa1ed7a5, us-east-1d, ~12:50Z Aug 15 after a
  10-attempt overnight capacity hunt), instance up (i-015e87b4be6932c2c);
  two launch bugs found & fixed on the way: run-instances tenancy belongs
  inside `--placement`, and a pending host must be waited to `available`
- ⬜ SSH verified from the user's machine

## Phase 4 — CI on the paid box

- ✅ Dispatch workflow `sweep.yml` (N / repeats / device inputs, artifacts)
- ⬜ Self-hosted Actions runner registered on the EC2 Mac

## Phase 5 — The experiment

- ⬜ Full N-sweep to failure with repeats; failure mode logged at the ceiling
- ⬜ Process/fd limit tuning if that wall arrives before RAM

## Phase 6 — The answer

- ✅ Report generator (`analyze.py --report`)
- ⬜ Final `report.md` committed: the number, the knee, what broke first
- 🔄 White paper (`docs/PAPER.md`) — skeleton drafted; sections 6–7 await
  EC2 data
- 🔄 Six-page exec/eng brief (`docs/BRIEF.md`) — skeleton drafted; incl.
  competitive analysis ("the GCP-shaped hole")
- ⬜ Dashboard snapshots per ladder, versioned in `docs/snapshots/`

## Phase 6.5 — Publication polish (repo is referenced by the docs)

- ⬜ README rewritten as the repo's front door: the question, headline
  numbers, links to BRIEF/PAPER/dashboard, quickstart per tier
- ⬜ Branch merged to main via PR; stale branches pruned; results branches
  (`ec2-results`, `ci-results*`, `aws-state`) documented in README
- ⬜ Docs pass: RUNDAY updated with today's real lessons (no Xcode on AMI,
  pending-host wait, SSM recovery path); aws/README troubleshooting current
- ⬜ Sanity sweep: no credentials/IPs/account-ids in tracked files; LICENSE
  present; mocks and harness runnable by a stranger (`make dryrun`)

## Phase 7 — Optional extras

- ⬜ Second instance type / laptop-vs-cloud comparison (`compare.py`)
- ⬜ Limit-pushing within the same 24h window
