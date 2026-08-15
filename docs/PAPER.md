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

*(All data in hand — write from ci-results branches / dashboard run-11.)*

- RAM per simulator by profile: **~267 MB (IDLE) / ~356 (ANIMATE) /
  ~1080 (INFER)** over a ~5.5 GB base.
- Predicted ceilings by instance type (table from `analyze.py`
  `EC2_TYPES`): ~31 (M1/16 GB) … ~135 (M4 Pro/48 GB) — RAM-bound only.
- Edge-AI scaling on 3 cores: 30 → 46 → 88 aggregate inf/s at N=1,2,3 —
  still linear when RAM ran out before CPU did.
- Sharding on 3 cores: **0.15× "speedup"** (i.e., slower) at 2 shards —
  sharding is bought with cores, not wished into existence. This is the
  CI-economics teaser the EC2 box resolves.
- Runner variance caveat: hosted-runner speed varied wildly run-to-run;
  what that does and doesn't invalidate.

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
- **Total overhead accounting**: `[EC2-PENDING]` wall-clock from
  allocation to first data row; the honest "setup tax" on a 24h window.

## 6. Results on the EC2 Mac `[EC2-PENDING]`

- 6.1 IDLE ladder: the headline curve; working point and hard ceiling;
  what broke first (RAM vs process wall vs CPU).
- 6.2 ANIMATE ladder.
- 6.3 INFER ladder: aggregate inf/s vs N — where inference throughput
  plateaus with 12 real cores (it never plateaued on 3).
- 6.4 Shard speedup with real cores: the crossover the 3-core runner
  couldn't show; wall-time vs shard count vs ideal.
- 6.5 Timelines at the ceiling: what dying looks like (RAM exhaustion
  pattern vs boot-storm pattern).
- 6.6 Predictions vs reality: the hosted-runner RAM model said ~90/~63/~22
  — how close was free-tier calibration? *(This is the paper's
  methodological payoff.)*

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
