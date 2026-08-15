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

*(The condensed Section-5 story from PAPER.md — as a timeline graphic +
a "traps" table. This is the page engineers forward to each other.)*

- Timeline: quota request → 10-attempt overnight capacity hunt
  (quota ≠ capacity) → host allocated 12:50Z → 50-min 'pending' before
  launches accepted → lost-credential recovery via SSM → **no Xcode on
  the AMI** (~1.5h install via an authenticated-browser workaround) →
  first data at `[T+Xh]`. Setup tax: **~X of 24 paid hours.**
  `[EC2-PENDING exact figures]`
- The traps table: symptom → root cause → fix (placement syntax; pending
  host reported as "does not exist"; double-allocation guard; missing sshd
  host keys; headless LaunchAgent failure). Each cost a failed run or an
  hour; all are now encoded in this repo's scripts so they cost nothing
  next time.
- No stored secrets anywhere: CI assumes an AWS role via GitHub OIDC
  (including the undocumented numeric-ID `sub` claim trap and its fix).

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

**What a competitor (GCP or anyone) would need to be competitive — each
requirement is a measured pain point from this study:**
1. **Apple-silicon metal with per-hour-or-better effective granularity**
   — VM-slice atop the 24h host lease (as managed vendors do) so
   customers never see the minimum.
2. **Capacity as a product**: reservable/queueable Mac capacity instead
   of an `InsufficientHostCapacity` retry lottery (our hunt: 10 attempts,
   ~6 hours, 2 usable AZs).
3. **Developer-ready images**: Xcode + iOS runtimes preinstalled and
   versioned (our single biggest avoidable time cost; Apple's EULA
   permits preinstallation for licensed use — GitHub's runners prove it).
4. **First-class CI integration**: OIDC-native, runner-registration
   baked in, density-aware instance sizing (RAM/core ratios matched to
   ~[MB/sim measured] per simulator).
5. **Honest failure surfaces**: our "host does not exist" (= pending),
   silent 50-min waits, and quota-vs-capacity confusion each cost real
   money on a running meter.
- **To surpass**: publish density benchmarks per instance type (this
  study, as a product page); offer simulator-farm-as-a-service (sims are
  processes — density is schedulable) so customers buy "N parallel
  simulators," not "a Mac."

---

*Data, code, dashboards: github.com/PGRBryant/awsEC2iOS-test — every
number in this brief is reproducible from a workflow dispatch. Dashboard
snapshots for each run day ladder are versioned in `docs/snapshots/`.*
