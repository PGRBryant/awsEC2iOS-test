# How Many iOS Simulators Can One Cloud Mac Actually Run?

**A density, economics, and operations study of iOS simulator CI on AWS EC2 Mac**

> All results below are measured on real hardware: one AWS
> `mac2-m2pro.metal` Dedicated Host, allocated 2026-08-15 12:50 UTC and
> released 2026-08-17 01:24 UTC. Raw data: the `ec2-results` branch of
> this repository. Companion executive brief: `docs/BRIEF.md`.

---

## Abstract

We measured how many iOS simulators one cloud Mac can reliably run, and
what breaks first, using a three-tier pipeline that validated every
component on free hardware before allocating a paid AWS EC2 Mac
Dedicated Host. On a `mac2-m2pro.metal` (M2 Pro, 12 cores, 32 GB)
running iOS 26.5, the reliable working point is **~16 simulators** and
the hard ceiling is **24**, where `launchd_sim` can no longer bind a
session; each simulator costs **~1,115 MB** over an 11.8 GB base and
spawns ~260 processes, so the memory and process-table walls arrive
together. Free GitHub-hosted runners had predicted ~90 simulators from a
267 MB/sim fit — **a 4× miss**, because at N ≤ 3 on a 7 GB runner
simulators share warm caches and never carry a full working set; the
central methodological finding is that cheap tiers validate a harness
but cannot size hardware. Under real on-device neural inference,
aggregate throughput scaled to 11.5× at N=12 while *per-simulator*
efficiency peaked at N=6, and splitting a test suite across simulators
paid only to 2-way (1.65×) before per-simulator startup overhead made
4-way sharding slower than not sharding at all. Finally, acquiring and
preparing the hardware proved harder than measuring it: quota is not
capacity, the AMI ships without Xcode, disk and process-table limits
kill the CI runner along with the experiment, and roughly half of the
first paid window went to setup — an operations profile we document in
full because it, not the density number, is what makes cloud Mac testing
expensive today.

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
| 2 | EC2 mac2-m2pro.metal, ~36 h (24 h minimum + extension) | on-demand host rate | the density answer, plus four platform walls free tiers cannot reach |

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
- **Total overhead accounting**: host allocated 2026-08-15 12:50 UTC;
  first usable data row ~2026-08-16 00:30 UTC. **Roughly half the first
  paid 24-hour window went to acquisition and preparation**, before a
  single density measurement existed. A further ~13 hours were lost to
  the process-wall wedge, during which the host billed and executed
  nothing.

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

## 6. Results on the EC2 Mac

- 6.1 IDLE ladder — **measured** (mac2-m2pro.metal, iPhone-17e sims,
  iOS 26.5): N=1–16 all boot, install, launch, and render across both
  trials; N=24 never boots (`launchd_sim` cannot bind a session). RAM:
  **~1,115 MB per booted sim over an 11.8 GB base** (vs 267 MB/sim
  predicted from the hosted tier — a 4× miss, see 6.6). At N=16 the box
  is already 15 GB into swap with 315 s boot walls and ~4,200 processes.
  Reliable working point ~12–16; hard ceiling < 24; the RAM and process
  walls arrive together on this configuration.
- 6.2 ANIMATE ladder — **not measured; the run became a finding
  instead.** The ladder executed on a host still holding ~4,600 leaked
  processes and 29 GB of swap from the previous ladder's failed N=24
  boot (26.5 GB in use at N=1, versus 9.4 GB for a clean IDLE N=1). The
  numbers describe contamination, not ANIMATE, and are reported only as
  evidence for the process-leak finding in Section 5.

### 6.3 INFER ladder — the edge-AI curve

Complete and clean: N = 1–12, every simulator booted, installed,
launched and rendered across both trials, zero failures.

| N | aggregate inf/s | per-sim | vs N=1 | marginal per added sim | mem | swap | procs |
|---|---|---|---|---|---|---|---|
| 1 | 45.6 | 45.6 | 1.0× | — | 10.2 GB | 0 | 540 |
| 2 | 97.7 | 48.9 | 2.1× | 52.1 | 15.8 GB | 0 | 817 |
| 4 | 214.3 | 53.6 | 4.7× | 58.3 | 17.9 GB | 0 | 1,298 |
| **6** | **331.0** | **55.2** | 7.3× | 58.4 | 22.9 GB | 0 | 1,860 |
| 8 | 394.0 | 49.3 | 8.6× | 31.5 | 25.3 GB | 1.7 GB | 2,332 |
| 10 | 456.1 | 45.6 | 10.0× | 31.0 | 26.8 GB | 4.0 GB | 2,820 |
| 12 | 523.9 | 43.7 | 11.5× | 33.9 | 27.1 GB | 9.4 GB | 3,154 |

Three results:

1. **Density is superlinear before it is sublinear.** Per-simulator
   throughput *rises* from 45.6 to 55.2 inf/s between N=1 and N=6 — a
   single simulator cannot saturate the machine because inference has
   serial phases (image synthesis, request setup) that overlap across
   processes. Six simulators do more than six times the work of one.
2. **The knee is at N=6 and it is memory, not compute.** Marginal return
   holds near 58 inf/s per added simulator through N=6, then halves to
   ~32 — and the inflection coincides exactly with swap onset at N=8.
   Beyond the knee you continue buying throughput at roughly half price.
3. **It never plateaued.** Even at N=12 under 9.4 GB of swap, aggregate
   throughput was still climbing. The binding constraint on *edge-AI
   density* is memory, not the 12 cores — a higher-RAM machine would
   keep going. INFER costs ~1.5 GB/sim against IDLE's ~1.1 GB/sim.

Practical guidance: **~6 simulators per 12-core/32 GB Mac for peak
efficiency; up to 12 for maximum absolute throughput if swap is
acceptable.**

### 6.4 Shard speedup — where parallel testing stops paying

The same 12-test UI suite, split across N simulators. Every shard passed
at every level, so the timings are trustworthy.

| shards | wall time | speedup | efficiency vs ideal |
|---|---|---|---|
| 1 | 149.3 s | 1.00× | 100% |
| **2** | **90.5 s** | **1.65×** | **83%** |
| 4 | 213.2 s | 0.70× | 18% |
| 6 | 369.9 s | 0.40× | 7% |
| 8 | 685.3 s | 0.22× | 3% |

**The crossover exists, and it is far below the core count.** On three
free cores, 2-way sharding was a 0.15× *slowdown*; on twelve real cores
it is a genuine 1.65× win. But 4-way sharding is already slower than not
sharding at all, and 8-way adds 536 seconds to a 149-second suite.
Twelve cores did not buy twelve-way parallelism — it bought two-way.

The mechanism is fixed cost: every shard pays simulator boot, install
and launch (40–90 s here, worse under boot-storm contention) before
running a single test. Sharding pays only while `suite_time / n` still
exceeds that tax. **The optimal shard count is set by the ratio of suite
runtime to per-simulator startup cost, not by how many cores you own.**
A 30-minute suite would shard profitably much further; a 150-second
suite peaks at two. This is precisely the calculation teams skip when
they buy "one big Mac" and expect linear returns.

### 6.5 What dying looks like

The per-second timelines separate two distinct failure signatures:

- **Boot storm (slow, recoverable).** Boot wall-time grows
  superlinearly — 0.8 s at N=1, 83 s at N=8, 315 s at N=16 IDLE — while
  memory climbs smoothly. Nothing fails; the ladder simply becomes
  expensive. This is what a "reliable working point" looks like from the
  inside.
- **Exhaustion (fast, terminal).** At the ceiling, memory flattens
  against the physical limit, swap takes over (9.4 GB at N=12 INFER;
  15 GB at N=16 IDLE), and the process count marches toward the
  per-user limit at ~260 processes per simulator. The next level does
  not degrade — it refuses: `launchd_sim` cannot bind a session, and
  every subsequent operation on the host fails including the harness's
  own recovery attempts.

The practical consequence for anyone repeating this: **instrument for
the second signature, because you only get one chance to record it.**
- 6.6 Predictions vs reality — **the calibration transfer FAILED, and
  that is the finding**: the hosted-runner model (267 MB/sim, ceiling
  ~90) missed by 4× (1,115 MB/sim, ceiling <24). Why: at N≤3 on a 7 GB
  runner, sims share warm OS caches and never carry full working sets;
  extrapolating from that regime is honest math on an insufficient
  range. The method lesson: **free-tier calibration validates the
  harness, not the hardware** — real capacity planning needs at least
  one measurement in the target density regime. The same failure
  repeated across profiles: the free tier could not reach the edge-AI
  efficiency knee (it exhausted memory at N=3, three simulators short of
  the N=6 peak), and it inverted the sharding conclusion entirely —
  0.15× measured on three cores versus 1.65× on twelve.

## 7. Analysis: CI economics

**Cost per parallel simulator-hour.** At the measured working point, one
`mac2-m2pro.metal` sustains ~16 IDLE simulators or ~6–12 under edge-AI
load. Against the instance's on-demand rate, the *marginal* cost of a
simulator is small — but the *fixed* costs dominate the decision:

- A 24-hour minimum allocation means the practical unit of purchase is
  a day, not an hour. A team needing two hours of density pays for
  twenty-four.
- Our own setup tax consumed roughly half the first window (Section 5).
  Amortized across one run, that overhead exceeded the compute.
- Therefore: **batch density work.** The economics only favor a
  dedicated host when a full day's worth of parallel testing is queued
  behind it. Below that threshold, hosted runners or a managed Mac
  vendor's per-minute pricing wins outright, despite their margin.

**Sharding economics.** The measured curve (6.4) makes the rule
concrete: shard until `suite_time / n` approaches per-simulator startup
cost, then stop. For our suite that was n=2 on a 12-core machine. Teams
routinely over-shard on the assumption that cores are the constraint;
the constraint is actually startup overhead, and over-sharding is not
merely wasteful — it makes the suite *slower* while consuming more
hardware. A team's first action here should be measuring their own
boot+install cost, since it sets the entire parallelism budget.

**Edge-AI capacity planning.** INFER-profile simulators cost ~1.5 GB
each against ~1.1 GB idle, and their throughput knee arrives at N=6 on a
32 GB box. Capacity planned on idle density will over-commit AI-feature
suites by roughly 2–3× and land the fleet in swap, where the marginal
value of each added simulator halves. **Plan AI test capacity on
inference numbers, and size for RAM, not cores** — inference throughput
here was memory-bound long before it was compute-bound.

**The comparison that matters.** Hosted runners cost nothing and prove
correctness, but cap at ~3 simulators and vary in wall-time by more than
2×. A dedicated Mac delivers 5× the density and stable timing, at the
price of a day's minimum and the operational burden documented in
Section 5. Managed Mac clouds sell the middle: per-minute VMs on their
own fleet, at a margin that is straightforwardly worth paying unless
your volume is high and sustained.

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
- Cost: ~36.5 host-hours (24-hour minimum plus a ~12.5-hour extension
  taken to complete the data set after operational losses), one 400 GB
  gp3 volume for about a day, and nothing else. Roughly 13 of those
  hours were the process-wall wedge — billed, idle, and now guarded
  against in the harness.

## 10. Conclusion

**The number: ~16.** A 12-core, 32 GB cloud Mac reliably runs about
sixteen iOS 26 simulators, refuses at twenty-four, and reaches those
limits through memory and the process table simultaneously — not through
CPU, which was never the binding constraint in any profile we measured.
Under edge-AI load the useful figure is smaller still: six simulators
for peak efficiency, twelve for maximum throughput at half marginal
value.

**The wall that arrived first was the one nobody models.** Not RAM, not
cores — the *process table*, at ~260 processes per simulator rather than
the 15–25 commonly assumed, and behind that, disk, at ~0.5–1 GB
materialized per booted simulator. Both walls take the test harness and
the CI agent down with them, turning a data point into an outage. A
density experiment must be built to survive the collapse it is designed
to produce.

**The calibration verdict: free tiers prove pipelines, not capacity.**
Our hosted-runner model was internally sound and wrong by 4×, because
three simulators on a 7 GB box do not exercise the regime that matters.
This is the transferable lesson for any team sizing a fleet from cheap
measurements — and the reason we published the miss rather than quietly
recalibrating.

**The bottleneck is acquisition, not simulation.** Simulators behave
predictably; getting a Mac to run them on does not. A capacity lottery
with no queue, a 24-hour minimum, an image without a toolchain, failure
messages that describe the wrong problem, and no supported way back in
when a key is lost — these consumed about half of the first paid day.
That is the real state of cloud iOS testing in 2026, and it is also the
opening: the provider who sells *guaranteed parallel simulators* instead
of *machines you must prepare yourself* would not need better hardware
to win. They would only need to remove the day we spent getting here.

---

## Appendix A — Run-day timeline

Wall-clock log of the paid window. Times UTC. This is the source data
for the setup-tax accounting in Section 5.

| Time | Elapsed | Event |
|---|---|---|
| Aug 15 06:52 | −6:00 | Capacity hunt begins — automated hourly `allocate-hosts` attempts across all AZs offering the type |
| Aug 15 12:50 | **T+0** | **Host allocated** (`h-08263dbbdfa1ed7a5`, us-east-1d) on attempt 10. The 24-hour clock starts |
| Aug 15 12:50 | T+0:00 | First launch attempt fails: `--tenancy` is not a valid top-level `run-instances` flag |
| Aug 15 13:40 | T+0:50 | Second launch fails: `InvalidHostId: does not exist` — the host is still `pending`, ~50 min after allocation |
| Aug 15 14:15 | T+1:25 | **Instance running** (`i-015e87b4be6932c2c`) after adding a wait-for-`available` loop |
| Aug 15 ~15:00 | T+2:10 | SSH impossible — key pair `.pem` unavailable and not re-issuable. Recovery: attach SSM role, wait for agent credential refresh |
| Aug 15 ~19:00 | T+6:10 | Session Manager shell obtained; AMI shipped with no sshd host keys (`ssh-keygen -A`) |
| Aug 15 ~19:30 | T+6:40 | **No Xcode on the AMI.** `xcodes` via Homebrew fails (compiles from source, needs Xcode); its CLI login rejects valid credentials |
| Aug 15 ~21:00 | T+8:10 | Xcode installed via authenticated browser download copied as cURL; `xip --expand`, first-launch, iOS platform download |
| Aug 15 21:07 | T+8:17 | **`make smoke` clean** — first real simulators on the box |
| Aug 15 21:23 | T+8:33 | Self-hosted runner registered and listening |
| Aug 15 21:25 | T+8:35 | IDLE ladder dispatched |
| Aug 15 22:13 | T+9:23 | Ladder dies at N=16: **disk full**. ENOSPC kills the runner; results stranded |
| Aug 15 23:02 | T+10:12 | Cleanup + rescue of stranded results; disk-floor guard added to harness |
| Aug 16 00:16 | T+11:26 | EBS volume grown to 400 GB — **invisible until instance reboot**; LaunchDaemon installed so the runner survives it |
| Aug 16 01:09 | T+12:19 | **IDLE ladder relaunched clean** — first usable density data ≈ half the paid window after allocation |
| Aug 16 03:28 | T+14:38 | IDLE complete: working point 16, ceiling 24. Snapshot published |
| Aug 16 04:01 | T+15:11 | ANIMATE ladder starts — on a host still holding ~4,600 leaked processes |
| Aug 16 06:24 | T+17:34 | **Process wall.** `fork()` fails for everything; box accepts jobs, executes nothing |
| Aug 16 06:24–19:05 | T+17:34–30:15 | **~13 hours billed idle** awaiting a console reboot (the only recovery) |
| Aug 16 19:12 | T+30:22 | Box recovered; ANIMATE data rescued; process-leak guard added |
| Aug 16 19:14 | T+30:24 | INFER ladder starts |
| Aug 17 00:23 | T+35:33 | **INFER complete, zero failures**, N=1–12 |
| Aug 17 00:24 | T+35:34 | Shard ladder starts |
| Aug 17 01:20 | T+36:30 | **Shard complete**, all shards passing |
| Aug 17 01:24 | **T+36:34** | **Instance terminated, host released.** Billing ends |

**Summary:** 36.5 host-hours. ~12.3 hours from allocation to first usable
data (setup tax), ~13 hours lost to the process-wall wedge, ~6 hours of
productive measurement, remainder in failed/contaminated ladders and
recovery. Every one of the delays above is now either automated away or
documented in `aws/RUNDAY.md`.

## Appendix B — Harness reference

**`results.csv`** — one row per (N, trial):

```
level,repeat,device,runtime,profile,boots_ok,installs_ok,launches_ok,
renders_ok,boot_wall_ms,mem_used_mb,mem_total_mb,load1,proc_count,
swap_used_mb,infer_ops,failure_mode
```

`renders_ok` is the column that matters — `boots_ok` counts simulators
that reported Booted, `renders_ok` counts those that produced a verified
frame. `failure_mode` is empty on a clean trial, else one of
`partial_render`, `boot_timeout`, `install`, `disk`, `process_wall`.
`infer_ops` is aggregate inferences/sec across all simulators (INFER and
HOTDOG profiles only).

**`timeline.csv`** — one row per sample interval (default 5 s):

```
ts_ms,level,repeat,mem_used_mb,mem_total_mb,load1,proc_count,
swap_used_mb,booted
```

**`speedup.csv`** (shard runs) — one row per shard count:

```
shards,total_tests,wall_ms,passed_shards,failed_shards
```

**Load profiles** (`--profile`, forwarded to the app as `SD_PROFILE`):

| Profile | Behavior |
|---|---|
| `IDLE` | static screen — the platform floor |
| `ANIMATE` | continuous animation plus periodic hash churn |
| `SCROLL` | auto-scrolling list — memory and render churn |
| `INFER` | Vision OCR loop on generated images; reports inferences/sec |
| `HOTDOG` | Vision image classification scored against ground truth (see the Section 5 sidebar — not usable in headless simulators) |

**Mock fault injection** (`--dry-run`, runs on any OS):

| Variable | Effect |
|---|---|
| `MOCK_BOOT_SECS` | seconds a simulated boot takes |
| `MOCK_MAX_SIMS` | `create` fails beyond this many live simulators |
| `MOCK_BOOT_HANG_AT` | simulators booted beyond this count never finish |
| `MOCK_RENDER_FAIL_AT` | simulators beyond this ordinal boot but render blank |
| `MOCK_SECS_PER_TEST` | per-test duration for shard timing |

**Guards** (environment overrides): `DISK_FLOOR_GB` (default 8) stops a
sweep before ENOSPC; `PROC_CEILING` (default 2000) forces a hard cleanup
and refuses a level the host cannot support.

**Workflow inputs** — `sweep.yml` takes `mode` (sweep/shard), `profile`,
`levels`, `repeats`, `device`, `boot_timeout`; `aws-provision.yml` takes
`action` (status/provision/teardown) plus instance type, key name, SSH
CIDR and optional AZ pin; `ec2-maintenance.yml` takes `action` (report /
clean / resize-disk / install-runner-daemon). Full usage:
[`README.md`](../README.md) and [`aws/RUNDAY.md`](../aws/RUNDAY.md).
