# iOS Simulator Density on EC2 Mac

**How many iOS simulators can one Mac run at once?** This repo answers that
empirically. It boots simulators in increasing waves (N = 1, 2, 4, 8, …),
launches a real SwiftUI app in each, verifies each one actually *rendered*,
samples host resources every second, and records exactly where things break.

## The answer, measured

On an **AWS `mac2-m2pro.metal`** (M2 Pro · 12 cores · 32 GB) running
**iOS 26.5** simulators:

| | |
|---|---|
| **Reliable working point (IDLE)** | **~16 simulators** |
| **Hard ceiling** | **24 — `launchd_sim` cannot bind a session** |
| **Memory per simulator** | **~1,115 MB** over an 11.8 GB base |
| **At the working point** | 15 GB into swap, ~4,200 processes, 315 s boot wall |

**The prediction from free hosted runners said ~90 simulators. The real
box held 16.** That 4× miss is the most useful result here: at N ≤ 3 on a
small runner, simulators share warm OS caches and never carry a full
working set, so extrapolating from that regime is honest math on an
insufficient range. **Free-tier calibration validates your harness, not
your hardware.**

📄 **[Six-page brief](docs/BRIEF.md)** (leadership + engineering) ·
📄 **[White paper](docs/PAPER.md)** (full method and findings) ·
📊 **[Dashboard snapshots](docs/snapshots/)** (per-ladder, self-contained
HTML) · 🗺️ **[Roadmap](ROADMAP.md)**

Raw data lives on orphan branches, append-only:
[`ec2-results`](../../tree/ec2-results) (paid box),
[`ci-results`](../../tree/ci-results) (hosted runners).

## What makes this more than a benchmark

- **Booted ≠ working.** Every simulator must render a verified frame
  (screenshot byte-size check), not merely report `Booted`.
- **Load profiles.** Density is measured under `IDLE`, `ANIMATE`,
  `SCROLL`, and `INFER` — the last running **real on-device neural
  inference** (Vision OCR; the model ships with the OS, nothing bundled),
  because AI-feature test suites have very different capacity needs.
- **Verify before you pay.** Three tiers — mocks (any OS) → free hosted
  macOS runners → one paid 24-hour host. Seven real bugs were caught for
  $0 before the meter ever started.
- **The operations study.** Getting the Mac was harder than measuring it:
  a capacity lottery, an AMI with no Xcode, a disk wall, and a process
  wall that takes the CI runner down with it. All of it is documented and
  guarded in [`aws/RUNDAY.md`](aws/RUNDAY.md) and the scripts here.

---

## Try it right now — no Mac required

The harness has a `--dry-run` mode backed by a mock `simctl`
(`harness/mock/simctl`), so the entire sweep control flow runs on any OS:

```bash
make dryrun       # full sweep against the mock — seconds, zero dependencies
```

Fault injection exercises the failure paths the real experiment exists to find:

```bash
MOCK_BOOT_HANG_AT=4 make dryrun     # boots hang beyond 4 concurrent sims
MOCK_RENDER_FAIL_AT=3 make dryrun   # sims beyond #3 boot but render blank
```

## Phase 0 — run it on a Mac (no AWS)

Requires: a Mac, Xcode + command line tools, an installed iOS simulator runtime.
[Homebrew](https://brew.sh) is used to fetch `xcodegen` if it isn't present.

```bash
make bootstrap    # install xcodegen, generate the project, build the app once
make smoke        # fastest end-to-end check: N=1 and N=2, one trial each
make uitest       # optional: one-time XCUITest interactivity check on one sim
make sweep        # the real sweep (default N = 1 2 4 8, 3 repeats)
make analyze      # headline numbers + RAM model + report.md
```

`analyze` fits **MB-per-booted-sim** from your run and predicts the RAM-bound
ceiling for every EC2 Mac instance type — so even a sweep on a small machine
(or your laptop) gives a directional answer for the big ones before you pay
for a Dedicated Host.

## The developer-realism layer

Density is the capacity story; what a phone team actually buys cloud sims for
is **faster PR feedback**. Two additions make the demo mirror that use case:

```bash
make sweep PROFILE=ANIMATE        # density under load: IDLE | ANIMATE | SCROLL | INFER
make bootstrap-tests && make shard SHARDS="1 2 4"   # suite wall-time vs shard count
make dashboard                    # self-contained HTML dashboard from the results
```

`PROFILE=INFER` is the edge-AI case: each sim runs a continuous loop of real
on-device neural inference (Vision OCR on generated images — the models ship
inside iOS, so nothing is bundled or downloaded). Per-sim inferences/sec are
written to the app sandbox and collected via `simctl get_app_container`, giving
the sweep an **aggregate edge-AI throughput vs N** curve: does total inference
scale with more sims, plateau at core saturation, or collapse?

- **Load profiles** — the app renders realistic work (animation churn,
  auto-scrolling lists) selected via `SD_PROFILE`, so the ceiling is measured
  under app-like load, not an idle screen.
- **Sharding** — `shard.sh` splits the 12-test UI suite across N parallel
  simulators; `speedup.csv` captures the wall-time curve, the number that
  translates density into developer minutes saved.
- **Dashboard** — `dashboard.py` renders everything (curves, RAM fit, per-second
  resource timelines from `timeline.csv`, speedup vs ideal) into one
  dependency-free HTML file; CI uploads it as an artifact on every PR.

Push further once the small runs are green:

```bash
./harness/sweep.sh --app app/build/Build/Products/Debug-iphonesimulator/SimDensity.app \
  --levels "1 2 4 8 16 24 32" --repeats 3
```

## What's here

| Path | What it is |
|------|------------|
| `app/` | Trivial SwiftUI app (one full-bleed screen) + XcodeGen `project.yml`. Kept trivial on purpose — we measure the platform, not the app. |
| `scripts/bootstrap.sh` | One-time prep: installs tooling, generates the Xcode project, builds the `.app` once. |
| `harness/sweep.sh` | The experiment. Creates/boots/installs/launches/verifies N sims per trial and writes one CSV row per trial. `--dry-run` swaps in the mock. |
| `harness/mock/simctl` | Mock `simctl` with fault injection (`MOCK_*` env vars) so the sweep logic is testable anywhere, including Linux CI. |
| `harness/analyze.py` | Headline numbers, RAM model + per-instance ceiling predictions, `--report` markdown (+ charts if matplotlib is present). |
| `harness/compare.py` | Cross-machine comparison: `compare.py laptop=a.csv ec2=b.csv` — one row per machine with measured vs predicted ceilings. |
| `harness/shard.sh` | The throughput experiment: splits the UI-test suite across N parallel sims and measures suite wall-time vs N (`speedup.csv`). `--dry-run` mocks both simctl and xcodebuild. |
| `harness/dashboard.py` | Self-contained HTML dashboard (inline SVG, no deps, light+dark): stat tiles, density curves, RAM fit, resource timelines, speedup curve, trials table. |
| `ROADMAP.md` | Phase-by-phase deliverables ledger with live status. |
| `app/UITests/` | One-assertion XCUITest (`make uitest`) — single-sim interactivity check before a paid run. |
| `aws/` | Provisioning runbook for the EC2 Mac dedicated host (Phase 1). |

## How the measurement works

Each trial at level **N**:

1. **create** N fresh simulators of one fixed device type + runtime,
2. **boot** them together and wait for each to reach `Booted` (with a deadline),
3. **install** the prebuilt app and **launch** it in every booted sim,
4. **verify render** — a booted-but-blank sim produces a tiny screenshot, so a
   screenshot below a byte threshold counts as *not actually rendered*
   (guards against "booted ≠ working" under load),
5. **sample** host memory, load average, process count, and swap,
6. **tear down** — shut down and delete every sim it created.

Two numbers fall out (see `analyze.py`):

- **Reliable working point** — largest N where *every* trial booted, launched,
  and rendered all N sims with no failure mode.
- **Hard ceiling** — smallest N where any sim failed to boot.

### Why "how many" is a real question

There's no fixed CoreSimulator limit — density is bound by **RAM first**, then
the per-user process (~2,500 by default) and open-file limits. So the ceiling is
hardware-dependent and worth measuring, and it's expected to scale with a box's
memory. That's exactly what the sweep quantifies.

## Notes / knobs

- `--stop-on-fail` halts the sweep at the first level that isn't 100% clean.
- `--device` / `--runtime` hold the rest of the experiment fixed; vary only N.
- The harness never leaves simulators behind — it deletes what it creates, even
  on Ctrl-C, so repeated runs start clean.
