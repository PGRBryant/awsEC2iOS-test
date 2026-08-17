# Cloud iOS Testing: What One Mac Can Do — and What It Takes to Get One

**A six-page brief for engineering and business leadership**

> Every number here is measured, not modelled — on one AWS EC2 Mac over a
> 36-hour window in August 2026. Written to stand alone: leadership reads
> pages 1–2 and the tables; engineers read all six and follow the repo
> links. Long companion: `docs/PAPER.md`. Data and code: this repo.

---

## Page 1 — The answer up front

**The question.** iOS simulators are the workhorse of mobile CI: every
pull request runs its tests inside them, and how many you can run at
once sets how fast a phone team gets feedback. Nobody publishes how many
a cloud Mac actually holds. We measured it.

**The answer, on an AWS `mac2-m2pro.metal` (M2 Pro · 12 cores · 32 GB)
running iOS 26.5:**

> ### ~16 simulators reliably. 24 refuses to start.
> **~1,115 MB of memory and ~260 processes per simulator.** At sixteen,
> the machine is 15 GB into swap with five-minute boot waits. At
> twenty-four, `launchd_sim` cannot start at all.

**Three findings a mobile organization can act on Monday:**

1. **Free-tier estimates are off by 4×.** Measurements from free
   GitHub-hosted runners predicted ~90 simulators on this machine. It
   held 16. Small runners never reach the regime where each simulator
   carries its own working set. *If your capacity plan came from a
   small runner, it is wrong — and wrong in the expensive direction.*
2. **AI-feature testing costs ~2× the capacity of ordinary testing.**
   Simulators running real on-device inference need ~1.5 GB each, and
   throughput per simulator peaks at **six** on this box. Plan AI test
   fleets on inference numbers and size for memory, not cores.
3. **More parallelism is not more speed.** Splitting a test suite across
   2 simulators made it **1.65× faster**; across 4 it became **slower
   than not splitting at all**. The limit is per-simulator startup cost,
   not core count — twelve cores bought two-way parallelism.

**The catch, and the opportunity.** Getting the machine took longer than
using it: roughly **half of the first paid 24-hour window** went to
acquiring and preparing hardware — a capacity lottery with no queue, an
image with no Xcode, and failure modes that report the wrong problem
(page 5). AWS is the only hyperscaler renting Apple silicon at all, and
this is what its state of the art costs in engineer-hours. A competitor
that sold *ready parallel simulators* rather than *machines you prepare
yourself* would not need better hardware to win (page 6).

## Page 2 — Why this matters (the business case)

**Developer velocity is bought with simulator density.** Mobile teams
ship at the speed their pull requests get feedback. Test suites are
parallelized across simulators; simulators are constrained by Mac
hardware — the scarcest, oddest resource in CI, and the only one a
hyperscaler still rents by the day rather than the minute.

**The three options a team actually has, with what we measured:**

| | Hosted runners (GitHub) | Dedicated cloud Mac (measured) | Managed Mac cloud |
|---|---|---|---|
| Parallel simulators | ~3 (7 GB cap) | **~16 idle / ~6–12 under AI load** | vendor-defined |
| Purchase unit | per-minute, free for OSS | **24-hour minimum** | per-minute |
| Timing stability | varies >2× run to run | stable | stable |
| Setup burden | none | **~half of our first paid day** | none |
| Best for | correctness signals, small suites | sustained high-volume density | most teams, most of the time |

**Three consequences for planning:**

1. **Batch your density work.** With a 24-hour minimum and a real setup
   tax, a dedicated host only makes sense when a full day of parallel
   testing is queued behind it. Below that, per-minute vendors win even
   after their margin — the arithmetic isn't close.
2. **Budget AI test capacity separately.** Suites exercising on-device
   inference need ~1.5 GB per simulator versus ~1.1 GB idle, and their
   efficiency peaks at six simulators, not sixteen. A fleet sized on
   idle numbers will over-commit AI suites by 2–3× and spend the
   difference in swap.
3. **Measure your own startup cost before buying parallelism.** Our
   suite stopped benefiting from sharding at two simulators because
   boot+install (40–90 s) dominated a 150-second suite. Longer suites
   shard further; the ratio, not the core count, decides. Teams that
   over-shard pay for hardware to make their tests *slower*.

**The strategic read.** Every number above says the same thing: the
constraint in cloud iOS testing is not silicon, it is packaging. The
hardware can do the work; the purchase model, the images, and the
operational surface are what make it expensive (pages 5–6).

## Page 3 — What we measured and how

**The experiment in one paragraph.** Boot N simulators. Install a real
SwiftUI app in each. Verify every one actually *rendered a frame* — not
merely that it reported "Booted," because simulators routinely do the
latter without the former. Sample host memory, load, swap, and process
count every second throughout. Tear the whole set down, repeat for
variance, then step N up and do it again until something breaks — and
record *what* broke. The largest N that is clean across every trial is
the **reliable working point**; the first N that fails is the **hard
ceiling**. Both matter: teams should plan against the former and know
the latter.

**Load profiles, because idle simulators aren't a workload.** The same
ladder runs under `IDLE` (platform floor), `ANIMATE` (continuous
animation plus timer work), `SCROLL` (list churn), and `INFER` — which
runs **real on-device neural inference** via Apple's Vision text
recognizer. The model ships with the OS, so nothing is bundled and the
app stays honest; every inference is verified by requiring real text
back. This matters commercially: AI-feature suites are becoming
standard, and their density is a different number from idle density.

**Verify before you pay — three tiers.**

| Tier | Hardware | Cost | What it caught |
|---|---|---|---|
| Mocks | any OS, fake `simctl` with fault injection | $0 | harness logic; a `pipefail` bug that silently misreported boots |
| Hosted macOS runners | 3 cores / 7 GB, real Apple silicon | $0 | 7 real bugs — device/runtime pairing, a red suite hiding in a green job, bash-3.2 incompatibilities, artifact-egress limits |
| EC2 Mac | M2 Pro / 12 cores / 32 GB, one 24 h host | ~$1.5–2/h | the actual answer — and four platform walls the free tiers cannot reach |

The paid box only ever ran code that was already proven, which is why
every failure it produced was a *finding* rather than a bug.

**The calibration scorecard — the method's own report card.** The free
tier predicted ~90 IDLE simulators on this machine from a 267 MB/sim
fit. The machine held **16**, at **1,115 MB/sim**. The free tier was not
wrong about the harness; it was wrong about the hardware, because at
N ≤ 3 on a 7 GB runner simulators share warm OS caches and never carry a
full working set. **Cheap tiers prove your pipeline. Only the target
hardware sizes your fleet.** The same pattern held elsewhere: the free
tier could not reach the edge-AI knee (it ran out of memory at N=3, three
simulators short of the peak) and it got the sharding answer backwards —
0.15× where the real machine delivers 1.65×.

## Page 4 — Results

*Charts: `docs/snapshots/01-idle.html`, `03-infer.html`, `04-shard.html`
— each self-contained, with the underlying table included.*

**1 · Density ladder (IDLE) — the ceiling.** N = 1–16 render perfectly;
N = 24 will not boot. Memory grows at ~1,115 MB per simulator over an
11.8 GB base, processes at ~260 per simulator. At the working point the
machine is already 15 GB into swap with 315-second boot waits — it is
working, but the next step is a refusal, not a slowdown.

| N | 1 | 2 | 4 | 8 | 16 | 24 |
|---|---|---|---|---|---|---|
| renders | 100% | 100% | 100% | 100% | 100% | **fails to boot** |
| memory | 9.4 GB | 13.9 GB | 19.0 GB | 25.7 GB | 27.3 GB | — |
| swap | 0 | 0 | 0 | ~0 | 15 GB | — |

**2 · The prediction scorecard — the free tier missed by 4×.** Hosted
runners fit 267 MB/simulator and predicted ~90 on this machine.
Measured: 1,115 MB and 16. Not a modelling error but a sampling one —
three simulators on a 7 GB box never enter the regime that binds.

**3 · Edge-AI curve (INFER) — density is superlinear before it is
sublinear.** Aggregate on-device inference rises 45.6 → 523.9 inf/s from
N=1 to N=12 (11.5×), but *per-simulator* throughput peaks at **N=6**
(55.2/sim — 21% better than a lone simulator, because one simulator
cannot saturate the machine). Past N=6 the marginal return halves,
exactly where swap begins. It never plateaued: edge-AI density here is
bound by memory, not by the 12 cores.

**4 · Shard speedup — parallelism stops paying at 2.** The same 12-test
suite split N ways, every shard passing:

| shards | 1 | **2** | 4 | 6 | 8 |
|---|---|---|---|---|---|
| wall time | 149 s | **90 s** | 213 s | 370 s | 685 s |
| speedup | 1.00× | **1.65×** | 0.70× | 0.40× | 0.22× |

On three free cores this was a 0.15× *slowdown*; twelve real cores make
2-way sharding a genuine 1.65× win — and 4-way slower than not sharding
at all. Each shard pays 40–90 s of simulator startup before running a
test, so sharding pays only while `suite_time / n` exceeds that cost.
**Twelve cores bought two-way parallelism, not twelve-way.**

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
- **~16 parallel simulators** on a 32 GB machine (~6–12 under edge-AI
  load), **1.65×** suite speedup from 2-way sharding, **523 inferences/s**
  aggregate at N=12 — all of it behind a quota request, a capacity
  lottery, a 24-hour minimum, and a setup tax that consumed roughly half
  the first paid day.

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

**Where the actual white space is.** Be clear-eyed about who already
occupies this market: MacStadium (with Orka) and the CI vendors —
CircleCI, Bitrise, Codemagic — have solved VM-slicing on Mac metal and
hide the 24-hour lease behind per-minute pricing. Rebuilding that is
late and undifferentiated. AWS, meanwhile, owns the only hyperscaler
Apple-silicon fleet and packages it worst.

The unclaimed layer is one step up: **nobody sells parallel simulator
capacity as a product.** Every vendor sells a machine or a VM and leaves
the customer to discover — as we did, expensively — how many simulators
fit and where the returns stop. A service where a team requests "40 iOS
26 simulators for 20 minutes," billed by simulator-minute against a
published density model, sells the outcome teams want (fast PR feedback)
rather than the hardware they must first learn to operate.

**The GCP-specific wedge** is what a specialist structurally cannot
match: native IAM/VPC/artifact integration, data-residency guarantees,
and *reservable* capacity at hyperscaler scale — turning the capacity
lottery documented on page 5 into an SLA.

**The counterweight a serious review must state.** Apple's licensing
terms (macOS on Apple hardware, minimum lease durations) cap the
achievable margin; Mac fleets are capex-heavy and refresh on Apple's
schedule, not the provider's; and the fact that the specialist incumbent
has not scaled to hyperscale is evidence either of a limited TAM or of
an unclaimed seat. This study cannot settle which — but it does quantify
the customer pain precisely enough to price the bet.

---

*Data, code, dashboards: github.com/PGRBryant/awsEC2iOS-test — every
number in this brief is reproducible from a workflow dispatch. Dashboard
snapshots for each run day ladder are versioned in `docs/snapshots/`.*
