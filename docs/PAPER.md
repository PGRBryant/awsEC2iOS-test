# How Many iOS Simulators Can One Cloud Mac Actually Run?

**A density, economics, and operations study of iOS simulator CI on AWS EC2 Mac**

> **Status: DRAFT SKELETON.** Sections marked `[EC2-PENDING]` await the
> 24-hour run on the mac2-m2pro.metal box. Everything else can be written
> from data already collected. One author pass at the end for voice.

---

## Abstract

*(Write last. Four sentences: the question, the method, the number, the
surprise.)*

- The question: how many iOS simulators can one Mac reliably run in CI,
  and what breaks first?
- The method: a verified-before-paid pipeline — mock harness → free hosted
  macOS runners → one 24-hour EC2 Mac Dedicated Host window.
- The headline numbers: `[EC2-PENDING]` reliable working point and hard
  ceiling per load profile (predictions: ~90 IDLE / ~63 ANIMATE / ~22
  INFER on 32 GB).
- The operational surprise: getting the Mac was harder than measuring it —
  quota ≠ capacity, and the AMI ships without Xcode.

## 1. Motivation

Why a phone team cares:

- PR feedback latency is bought with parallel simulators; parallel
  simulators are bought with Mac hardware, which is the scarcest and
  weirdest resource in CI.
- Cloud Macs have unusual economics (Dedicated Hosts, 24-hour minimum
  billing) that punish trial-and-error — so the density question is worth
  answering once, carefully, and publishing.
- A modern wrinkle: on-device/edge AI features mean test suites
  increasingly run real neural inference inside simulators. Density under
  inference load is a different (much smaller) number than idle density —
  we measure both.

## 2. Background and constraints

- iOS simulators: user-space processes sharing the host kernel; no hard
  cap, bounded by RAM, CPU, and the ~2,500 processes-per-user wall (each
  sim spawns 15–25 processes).
- "Booted" ≠ "working": a sim can report Booted while unable to render a
  frame. Our harness verifies render via screenshot byte-size, which
  changed the measured ceiling. *(Reference the run where boots_ok >
  renders_ok.)*
- EC2 Mac: Dedicated Hosts only; 24-hour minimum (Apple licensing);
  quota is permission, not inventory — capacity is a separate, scarcer
  thing (Section 6).
- GitHub-hosted macOS runners: free for public repos, 3 cores / 7 GB —
  small, but real Apple silicon + real simulators, which makes them a
  legitimate calibration tier, not just a smoke test.

## 3. Method: verify before you pay

The pipeline's organizing principle — every tier catches bugs the next
tier would have charged for:

| Tier | Hardware | Cost | What it caught |
|---|---|---|---|
| 0 | Mock `simctl`/`xcodebuild` with fault injection | $0 | pipefail boot-detection bug; harness logic |
| 1 | GitHub-hosted macOS runners | $0 | 7 real bugs (Section 5.3); RAM models; device/runtime pairing |
| 2 | EC2 mac2-m2pro.metal, one 24h window | ~$[COST] | the actual answer `[EC2-PENDING]` |

### 3.1 The harness

- Sweep orchestrator: create → boot → install → launch → verify-render →
  sample → teardown; one CSV row per (N, trial); per-second resource
  timeline (RAM, load, swap, process count).
- Load profiles: IDLE, ANIMATE, SCROLL, INFER — selectable per sweep; the
  app renders the profile visibly so a screenshot proves liveness *and*
  the profile.
- Edge-AI profile (INFER): real on-device inference via Vision framework
  OCR — models ship with the OS, zero bundled assets; per-sim
  inferences/sec collected via `simctl get_app_container` +
  `Documents/metrics.json`.
- Shard harness: same suite split across N simulators via
  `xcodebuild test-without-building`; wall-time and per-shard pass/fail →
  speedup curve.
- Definitions: **working point** = largest N with zero failures across
  repeats; **hard ceiling** = first N where any verification fails;
  failure mode logged per trial.

### 3.2 The measurement plan

Ladder design (levels, repeats, timeouts) and why boots are
sequential-waited; how RAM-per-sim is fit (linear model over N with base
offset); how predictions transfer across machines.

## 4. Free-tier findings (GitHub-hosted runners)

GitHub's hosted macOS runners (3 cores / 7 GB, real Apple silicon) are
free for public repositories, which makes them a genuine measurement
tier rather than a smoke test — with a ceiling low enough that the
measurements mislead, as Section 6.6 shows.

**Density and the RAM model.** Across profiles, per-simulator memory fit
at **~267 MB (IDLE) / ~356 (ANIMATE) / ~1,080 (INFER)** over a ~5.5 GB
base. N = 1–3 boot, install, launch and render cleanly; the runner's
7 GB stops the ladder there. Feeding those fits through `analyze.py`'s
instance table produced predicted ceilings from ~31 sims (M1 / 16 GB)
to ~135 (M4 Pro / 48 GB), RAM-bound.

**Edge-AI throughput scales with cores, until it doesn't.** The INFER
profile reached 30 → 46 → 88 aggregate inferences/sec at N = 1, 2, 3 —
still climbing when memory, not compute, ended the ladder. On three
cores the interesting question (where does inference throughput
plateau?) is unanswerable; it needs a machine with cores to spare.

**Sharding is bought with cores.** Splitting a 12-test UI suite across
2 shards on a 3-core runner produced a **0.15× speedup** — that is,
running it *sharded* took nearly seven times longer than running it
whole. Boot and install overhead for the second simulator dwarfed the
work saved. This single number reframes the entire CI-economics
argument: parallelism is not free concurrency, it is a trade of fixed
per-simulator overhead against divisible test time, and it only pays
above a core threshold the free tier cannot reach.

**Variance caveat.** Hosted-runner wall times varied by more than 2×
between otherwise identical runs — enough that two of our CI runs timed
out mid-sweep and one shard comparison had to be discarded. Free tiers
are trustworthy for *correctness* signals (does it boot, does it render,
does the suite pass) and unreliable for *timing* signals unless
repeated. Every timing claim in this paper that matters comes from the
dedicated box.

### 4.1 Bugs found on free hardware

Each of these would have consumed paid host time — several would have
silently corrupted results instead of failing loudly:

| Bug | Tier that caught it | Consequence if unseen |
|---|---|---|
| `pipefail` + `grep -q` misreported boot success | mocks | inflated working point |
| Device/runtime pairing taken from the global device list (which ends at iPhone 6s Plus) | hosted CI | nothing boots on modern iOS |
| bash 3.2 lacks `mapfile` | hosted CI | shard harness dies on macOS |
| Container accessibility identifier collapsed children out of the AX tree | hosted CI | UI tests assert against nothing |
| A fully red test suite reported inside a green job | hosted CI | "12/12 passing" that wasn't |
| Concurrent CI runs starved each other's cores | hosted CI | timing data quietly meaningless |
| Artifact blob egress blocked in our environment | hosted CI | results unreachable after the host dies |

The last one changed the architecture: results are now published
append-only to git branches per trial, which is what later made two
crashed ladders recoverable.

### 5.3 Bugs found on free hardware

*(Table: bug → tier that caught it → what it would have cost on the paid
box. Include: pipefail boot detection; device/runtime pairing from
supportedDeviceTypes; bash 3.2 mapfile; AX-identifier collapsing children;
red-suite-in-green-job; concurrent-run core starvation; artifact egress
blocked → results-as-git-branches.)*

## 5. Getting the hardware (the operations study)

This section is a finding, not a diary: **acquiring the Mac was the
hardest engineering of the project.** Each item: symptom → root cause →
fix → time/money cost.

- **No-secrets provisioning**: GitHub OIDC → AWS role. The undocumented
  trap: GitHub stamps immutable numeric IDs into the `sub` claim
  (`repo:ORG@id/REPO@id:ref:...`), so textbook trust policies never
  match; the fix is ID-tolerant `StringLike` patterns. Debug technique:
  a workflow step that decodes and prints the token's public claims.
- **Quota ≠ capacity**: approval for 1× mac2-m2pro ≠ a Mac existing for
  you. `InsufficientHostCapacity` across AZs; the type is only offered in
  2 of 6 us-east-1 AZs. The babysit loop: 10 automated attempts over ~6
  hours (hourly, AZ-hunting) before capacity appeared. *(Chart: attempt
  timeline.)*
- **The three launch traps** (each cost a failed run):
  1. `run-instances` tenancy must live *inside* `--placement`
     (`Tenancy=host,HostId=...`), not as a top-level flag.
  2. A freshly allocated Mac host sits `pending` (~50 min observed)
     before accepting launches — and AWS reports a launch onto a pending
     host as `InvalidHostId: does not exist`, which is a lie.
  3. Rerunning provisioning after a partial failure must *reuse* the
     allocated host (state file + guards), or you double-allocate
     24h-minimum hardware.
- **Recovery without the key**: lost `.pem` → there is no re-download.
  Path back in: attach `AmazonSSMManagedInstanceCore` role to the running
  instance → Session Manager browser shell (≈30 min agent credential
  refresh) → regenerate missing sshd host keys (`ssh-keygen -A`; the AMI
  shipped without them, sshd was crash-looping) → new authorized_key.
  Never stop a Mac instance to fix access: stop triggers host scrubbing.
- **The AMI has no Xcode** (Apple licensing). Hosted runners hide this;
  the paid box does not. Install path that worked: browser login on a
  trusted machine → DevTools "Copy as cURL" of the authenticated `.xip`
  URL → datacenter-speed download on the box → `xip --expand` (~20 min,
  silent) → `-runFirstLaunch` (needs sudo) → `-downloadPlatform iOS`.
  The `xcodes` CLI failed twice first: Homebrew tried to compile it from
  source (which requires Xcode — circular), and its CLI auth rejected a
  password that worked in the browser. Budget: **~1–1.5 h of the 24h
  window.**
- **Disk is a wall nobody models**: booted sims materialize ~0.5–1+ GB
  each; the default 100 GB volume filled at N=16 and the resulting
  ENOSPC killed the *runner itself* (its logs couldn't be written), so
  the job died before results could publish. Fixes that are now
  permanent: a disk-floor guard in the harness (`failure_mode=disk`,
  graceful stop), a rescue-stranded-results maintenance action, and —
  the undocumented kicker — **an EBS volume grow is invisible to macOS
  until the instance reboots** (the Thunderbolt/Nitro path caches
  capacity; `diskutil` reports "new size must be different" until then).
- **The process wall kills the observer too**: the ANIMATE ladder
  exhausted the per-user process table (~4,200 seen at N=16 IDLE;
  ANIMATE crossed the limit near N≈16–20) — at which point `fork()`
  fails for *everything*, including the CI runner trying to report the
  failure and any recovery job dispatched afterwards. The box accepts
  work but cannot execute a single step; the only recovery is a console
  reboot. Density experiments must assume the harness dies *with* the
  patient — hence results streamed per-trial to durable storage, not
  collected at the end.
- **Headless service management**: `svc.sh` installs a LaunchAgent,
  which requires a GUI login session a headless box never has; `nohup`
  dies on reboot. A system LaunchDaemon (RunAtLoad + KeepAlive) is the
  working answer — with the trap that daemons get a bare system PATH,
  silently hiding every Homebrew tool from workflows.
- **Total overhead accounting**: `[EC2-PENDING]` wall-clock from
  allocation to first data row; the honest "setup tax" on a 24h window.

### Sidebar: the fixture-fidelity trap (what killed the Not-Hotdog test)

We added a fifth profile — classify a rendered hotdog-or-decoy image
with Vision's built-in ~1,300-label classifier, scored against known
ground truth, to measure *accuracy* under density, not just throughput.
It validated at exactly 50% accuracy: the classifier never said hotdog.
The label log told a two-act story: (1) Apple Color Emoji is a bitmap
font and a 320 pt draw silently rendered **nothing** — the classifier
was labeling a blank canvas ("night_sky", "moon"); (2) after fixing the
render, the classifier *still* returned byte-identical label sets for
every input — `VNClassifyImageRequest` does not produce meaningful
output in this headless-simulator pipeline, though the OCR network
(`VNRecognizeTextRequest`) demonstrably does. Four validation rounds,
all on free hosted runners, $0 of paid time. Two lessons: **an AI test
is only as real as the pixels that reach the model** (the neural cousin
of "booted ≠ working"), and **not every on-device model that works on
hardware works in the simulator — verify per-API before betting a test
suite on it.**

## 6. Results on the EC2 Mac `[EC2-PENDING]`

- 6.1 IDLE ladder — **measured** (mac2-m2pro.metal, iPhone-17e sims,
  iOS 26.5): N=1–16 all boot, install, launch, and render across both
  trials; N=24 never boots (`launchd_sim` cannot bind a session). RAM:
  **~1,115 MB per booted sim over an 11.8 GB base** (vs 267 MB/sim
  predicted from the hosted tier — a 4× miss, see 6.6). At N=16 the box
  is already 15 GB into swap with 315 s boot walls and ~4,200 processes.
  Reliable working point ~12–16; hard ceiling < 24; the RAM and process
  walls arrive together on this configuration.
- 6.2 ANIMATE ladder.
- 6.3 INFER ladder: aggregate inf/s vs N — where inference throughput
  plateaus with 12 real cores (it never plateaued on 3).
- 6.4 Shard speedup with real cores: the crossover the 3-core runner
  couldn't show; wall-time vs shard count vs ideal.
- 6.5 Timelines at the ceiling: what dying looks like (RAM exhaustion
  pattern vs boot-storm pattern).
- 6.6 Predictions vs reality — **the calibration transfer FAILED, and
  that is the finding**: the hosted-runner model (267 MB/sim, ceiling
  ~90) missed by 4× (1,115 MB/sim, ceiling <24). Why: at N≤3 on a 7 GB
  runner, sims share warm OS caches and never carry full working sets;
  extrapolating from that regime is honest math on an insufficient
  range. The method lesson: **free-tier calibration validates the
  harness, not the hardware** — real capacity planning needs at least
  one measurement in the target density regime. `[EC2-PENDING: ANIMATE/
  INFER scorecard rows]`

## 7. Analysis: CI economics `[EC2-PENDING]`

- $/parallel-simulator-hour: hosted runners vs EC2 Mac at measured
  densities; where the break-even sits for a team's PR volume.
- Sharding economics: cores per shard for >1× speedup; when N cheap small
  runners beat one dense box.
- The 24h minimum as a scheduling problem: batch your density needs.
- Edge-AI testing implication: INFER density is ~4× more expensive than
  IDLE density; capacity planning for AI-feature test suites must use the
  inference number, not the idle number.

## 8. Limitations

- One box, one 24h window, one macOS/Xcode version; no mac1/mac-m4
  comparison points (predictions only).
- Simulator ≠ device: no thermal/battery/neural-engine fidelity; Vision
  OCR exercises CPU/GPU paths, not the ANE.
- Hosted-runner variance; single-region capacity observations.
- `[Add anything the run day surprises us with.]`

## 9. Reproducibility

- Repo: harness, app, workflows, mocks — everything dispatchable; no
  stored secrets (OIDC only).
- The three-tier pipeline is re-runnable by anyone: Tier 0 on any OS,
  Tier 1 free on a public repo, Tier 2 with one quota request and
  ~$[COST].
- Data: all CSVs/timelines on results branches; dashboard is a single
  self-contained HTML file.
- Cost table: `[EC2-PENDING]` final bill breakdown (host-hours, EBS,
  nothing else).

## 10. Conclusion

*(Write after 6/7. Shape: the number, the wall that arrived first, the
free-tier calibration verdict, and the operations lesson — the cloud Mac
bottleneck is acquisition and setup, not simulation.)*

---

## Appendix A — Run-day timeline

*(Annotated wall-clock log of the 24h window: allocation 12:50Z Aug 15,
pending-wait, launch, SSM recovery, Xcode install, smoke, ladders,
teardown. Source material for Section 5's cost accounting.)*

## Appendix B — Harness reference

*(CSV schemas, profile definitions, mock fault-injection knobs, workflow
inputs. Mostly exists in README/RUNDAY — link, don't duplicate.)*
