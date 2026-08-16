# Cloud iOS Testing: What One Mac Can Do — and What It Takes to Get One

**A six-page brief for engineering and business leadership**

> **Status: DRAFT SKELETON.** `[EC2-PENDING]` marks slots for the 24-hour
> run's numbers. Written to stand alone: a VP reads pages 1–2 and the
> tables; an engineer reads all six and follows the repo links. The long
> companion piece is `docs/PAPER.md`; the raw data and code are this repo.

---

## Page 1 — The answer up front

*(One page, no jargon. Boxed headline numbers.)*

- **The question:** how many iOS simulators — the workhorse of mobile CI —
  can one cloud Mac actually run, and what does that mean for how fast a
  mobile team can test?
- **The headline:** `[EC2-PENDING]` N reliable simulators (IDLE) on a
  mid-tier cloud Mac (12 cores / 32 GB); N under realistic app load; N
  when tests exercise on-device AI. Test-suite wall-time improves X× with
  N-way sharding.
- **The catch:** getting and preparing the hardware took ~9 hours of a
  24-hour minimum-billing window. The bottleneck of cloud Mac testing is
  not the Mac — it's the acquisition pipeline.
- **The market gap in one sentence:** AWS is the only hyperscaler that
  rents Mac hardware at all, and even there capacity is scarce,
  provisioning is manual-ish, and images ship without developer tooling —
  the door is open for a competitor (Section: The GCP-shaped hole).

## Page 2 — Why this matters (the business case)

- Mobile PR feedback latency = developer velocity. Sharding a test suite
  across simulators is the lever; simulator density is the fulcrum.
- The economics table: $/parallel-simulator-hour across the options a team
  actually has today — GitHub-hosted runners, EC2 Mac (measured today),
  managed vendors (CircleCI/Bitrise/MacStadium list prices).
  `[EC2-PENDING for our column]`
- The edge-AI wrinkle: suites that test on-device inference (increasingly
  standard) cut density ~4× — capacity planning done on idle numbers will
  be wrong by that factor. We measured it: ~267 MB/sim idle vs ~1080
  MB/sim under real Vision-framework OCR load.
- The 24h-minimum constraint turns "spin up a Mac for an hour" into a
  scheduling discipline: batch density needs into windows. *(Chart:
  cost-per-useful-hour vs setup overhead.)*

## Page 3 — What we measured and how (the method, digestibly)

- Three-tier "verify before you pay" pipeline (diagram): mocks → free
  GitHub macOS runners → one paid 24h EC2 window. Seven real bugs caught
  on free tiers; the paid box ran only proven code.
- The harness in one paragraph: boot N simulators, install a real SwiftUI
  app, verify each one actually *renders* (booted ≠ working), sample
  RAM/CPU/processes every second, tear down, repeat. Load profiles: IDLE /
  ANIMATE (app-like animation) / INFER (real on-device OCR inference).
- Free-tier calibration results: RAM-per-simulator model
  (~267/~356/~1080 MB by profile) → predicted ceilings for every EC2 Mac
  size. Today's run graded those predictions: `[EC2-PENDING scorecard]`.

## Page 4 — Results (the four charts)

*(One chart each, pulled from the dashboard snapshots; two sentences of
takeaway per chart.)*

1. **Density ladder (IDLE):** render success vs N; working point and hard
   ceiling; what broke first. `[EC2-PENDING]`
2. **Density under load (ANIMATE):** the realistic number. `[EC2-PENDING]`
3. **The edge-AI curve (INFER):** aggregate inferences/sec vs N — where
   12 cores plateau. On 3 free cores it was still linear at N=3 (30→46→88
   inf/s). `[EC2-PENDING]`
4. **Shard speedup:** suite wall-time vs shard count vs ideal; on 3 cores
   sharding was a 0.15× *slowdown* — cores buy sharding. Where's the
   crossover on 12? `[EC2-PENDING]`

## Page 5 — The operations reality (what it took to get here)

**The headline for this page: we spent ~12 hours of a 24-hour paid window
getting to the first data row.** Not because the experiment was hard —
because acquiring and preparing a cloud Mac is. Every item below cost a
failed run or an hour of a billing meter, and every one is now encoded in
this repo's scripts, so the next team pays none of it.

| # | Symptom | Root cause | Cost |
|---|---|---|---|
| 1 | `InsufficientHostCapacity`, repeatedly | **Quota ≠ capacity.** Approval grants permission, not inventory; the type existed in only 2 of 6 AZs | 10 automated attempts over ~6 h |
| 2 | `InvalidHostId: does not exist` on a host we just allocated | A fresh Mac host sits `pending` ~50 min; AWS reports launches onto it with a misleading error | 1 failed run + 50 min |
| 3 | `Unknown options: --tenancy` | Tenancy belongs *inside* `--placement`, not as a flag | 1 failed run |
| 4 | Second host nearly allocated after a partial failure | No reuse guard — would have doubled a 24 h minimum bill | caught before spend |
| 5 | No SSH possible at all | Lost `.pem`; AWS cannot re-issue. Recovered via SSM Session Manager (~30 min for the agent to see its new role) — plus the AMI shipped with **no sshd host keys**, so sshd was crash-looping | ~1 h |
| 6 | `xcodebuild: requires Xcode` | **The AMI has no Xcode** (Apple licensing). The `xcodes` CLI installer compiles from source — which needs Xcode — and its login rejected credentials that worked in a browser. Solved by copying an authenticated download as cURL | ~1.5 h |
| 7 | Ladder died at N=16; runner died with it | **Disk is a wall nobody models**: booted sims materialize ~0.5–1 GB each; ENOSPC killed the CI agent before results could publish | 1 lost ladder |
| 8 | Grown EBS volume invisible to macOS | On EC2 Mac the capacity is cached until the instance **reboots** (never *stop* — that scrubs the host) | ~40 min |
| 9 | Runner vanished after reboot | `svc.sh` installs a LaunchAgent, which needs a GUI login a headless box lacks; `nohup` dies on reboot. A system LaunchDaemon works — but starts with a bare PATH that hides every Homebrew tool | ~30 min |
| 10 | Box accepted jobs, executed nothing, for 13 h | **The process wall takes the harness with it.** Failed boots leak simulator processes `simctl` won't reap; they accumulate until `fork()` fails for everything — the sweep, the CI runner, and any recovery job. Only a console reboot recovers it | ~13 h of billed idle |

Two structural lessons for anyone building this:

- **Results must be durable per trial, not collected at the end.** Twice
  the host died holding data; both times a rescue path (publish to a git
  branch, salvage before checkout cleans the workspace) is what saved the
  run.
- **The rig must survive the failure it measures.** A density experiment
  drives hardware to collapse by design; if the collapse also kills the
  observer, you get an outage instead of a data point.

No stored secrets exist anywhere in this system: CI assumes an AWS role
via GitHub OIDC, credentials expire in minutes, and revoking access means
deleting one role. (Trap worth knowing: GitHub now stamps numeric IDs
into the token's `sub` claim, so the textbook trust policy never matches.)

## Page 6 — What's possible today, and the GCP-shaped hole

**What we just proved possible today** (with AWS + GitHub, list prices):
- `[EC2-PENDING]` parallel simulators / $X.XX per hour / suite speedup X×
  — but behind a quota request, a capacity lottery, a 24h minimum, and
  ~Xh of setup tax.

**What today's offerings actually are:**
- AWS EC2 Mac: real Apple silicon metal, Dedicated Host only, 24h
  minimum (Apple licensing), no Xcode preinstalled, capacity scarce.
- GitHub/Microsoft hosted macOS runners: zero setup, free for public
  repos — but 3 cores / 7 GB caps density at toy scale; huge speed
  variance.
- Managed Mac clouds (MacStadium, CircleCI, Bitrise, Codemagic):
  per-minute macOS VMs on top of their own Mac fleets — they solved the
  slicing problem commercially; you pay the margin.

**What a competitor (GCP or anyone) would need to be competitive.** Each
requirement below is not a wish — it is a specific, measured failure we
hit, with the cost attached (page 5):

1. **Capacity as a product, not a lottery.** Reservable or queueable Mac
   capacity with a published wait, instead of `InsufficientHostCapacity`
   polling. *We burned 10 automated attempts over ~6 hours to get one
   machine we already had quota for.* This is the single clearest
   differentiator available: a "your Mac is ready at 14:00" guarantee
   beats AWS outright.
2. **Effective granularity better than 24 hours.** Slice the host lease
   (as the managed Mac clouds already do commercially) so customers buy
   the hour they need. *Our 24-hour minimum meant a ~12-hour setup tax
   consumed half the window we paid for.*
3. **Developer-ready images.** Xcode and iOS runtimes preinstalled and
   versioned. *Our single largest avoidable cost (~1.5 h of paid time),
   and GitHub's hosted runners prove it is licensable and doable.*
   Ship images that are ready to run a test suite, not to install one.
4. **Honest, actionable failure surfaces.** A pending host that reports
   "does not exist"; a volume grow that silently requires a reboot; a
   process-exhausted box that accepts jobs and runs nothing. *Each of
   these read as "broken" and cost hours of diagnosis on a live meter.*
   Surface state truthfully and the platform sells itself on trust.
5. **CI-native integration.** OIDC-first auth (no stored keys), runner
   registration built in, and **density-aware sizing guidance** —
   because the naïve RAM math is off by 4× (page 3), customers cannot
   size these machines correctly without vendor-published numbers.

**To surpass, not just match:** sell **parallel simulators, not
machines.** Simulators are processes; density is schedulable. A service
where a phone team requests "40 iOS 26 simulators for 20 minutes" —
billed by simulator-minute, spread across whatever metal the provider
owns — matches what teams actually want (fast PR feedback) instead of
what hardware happens to be. The measurements in this study are the
capacity model such a service would need, and the fact that they were
*this hard to obtain* is precisely why nobody has published them.

---

*Data, code, dashboards: github.com/PGRBryant/awsEC2iOS-test — every
number in this brief is reproducible from a workflow dispatch. Dashboard
snapshots for each run day ladder are versioned in `docs/snapshots/`.*
