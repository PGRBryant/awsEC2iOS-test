# Run day — 24 hours on a mac2-m2pro.metal (M2 Pro · 12 cores · 32 GB)

> ## Lessons from the actual run day (2026-08-15/16) — read BEFORE allocating
>
> Each of these cost us real clock on a billing host. Budget for them:
>
> 1. **Capacity is a lottery.** Quota approval ≠ a Mac existing. 10
>    hourly AZ-hunting attempts (~6h) before allocation succeeded.
> 2. **A fresh host sits `pending` ~50+ min** before it accepts launches —
>    and AWS reports a launch onto a pending host as `InvalidHostId: does
>    not exist`. provision.sh now waits automatically.
> 3. **The AMI has NO Xcode** (Apple licensing). Budget ~1–1.5h: browser
>    login to developer.apple.com on a trusted machine → DevTools "Copy as
>    cURL" on the .xip download → run that curl on the Mac → `xip --expand`
>    (~20 min, silent) → `sudo xcodebuild -runFirstLaunch` →
>    `xcodebuild -downloadPlatform iOS`. The `xcodes` brew formula
>    compiles from source (needs Xcode — circular) and its CLI auth is
>    flaky; use the prebuilt release binary or the cURL trick.
> 4. **Disk is a real wall.** Booted sims materialize ~0.5–1+ GB each;
>    the default 100 GB volume died at N=16 and took the runner with it.
>    Grow the EBS volume in the console (400 GB ≈ $1/day) — and note the
>    grow is **invisible to macOS until you REBOOT the instance** (reboot
>    is safe; STOP is not — stop triggers host scrubbing). Then run the
>    `resize-disk` action of `ec2-maintenance.yml`. sweep.sh now stops
>    gracefully at a disk floor (`DISK_FLOOR_GB`, default 8).
> 5. **Run the Actions runner as a LaunchDaemon** (`install-runner-daemon`
>    action), not `svc.sh` (LaunchAgents need a GUI login that headless
>    boxes lack) and not nohup (dies on reboot). Daemon PATH is bare —
>    workflows must add `/opt/homebrew/bin` to `GITHUB_PATH` (done).
> 6. **Lost .pem = no re-download.** Recovery: attach an SSM role to the
>    running instance → Session Manager shell (~30 min for the agent to
>    see credentials) → `sudo ssh-keygen -A` if sshd host keys are missing
>    → add a new authorized key. Never stop the instance for access.

The clock starts at allocation and cannot stop for 24 hours, so the day is a
schedule, not a vibe. Everything below is copy-paste; timeboxes are loose but
the ordering matters (cheap validation first, expensive sweeps once trusted,
teardown armed before you sleep).

### Predictions vs what actually happened (2026-08-15/16)

The hosted-runner fits predicted this box would hold ~90 IDLE sims. **It
held 16.** Keep the original numbers visible — being wrong in public is
the point of the exercise:

| profile | hosted-runner fit | predicted ceiling | **measured on this box** |
|---|---|---|---|
| IDLE    | ~267 MB/sim  | ~90 sims | **~1,115 MB/sim → 16 clean, 24 won't boot** |
| ANIMATE | ~356 MB/sim  | ~63 sims | contaminated run (see below) |
| INFER   | ~1,080 MB/sim | ~22 sims | `[pending]` |

Why the miss: at N≤3 on a 7 GB runner, simulators share warm OS caches and
never carry a full working set. Extrapolating from that regime is honest
math on an insufficient range — **free-tier calibration validates the
harness, not the hardware.**

Both walls arrive together here, not sequentially: at N=16 the box is 15 GB
into swap *and* running ~4,200 processes (≈260/sim, not the 15–25 the docs
suggest), with 315 s boot walls. At N=24 `launchd_sim` cannot bind a session
at all.

**The wall takes the harness with it.** A failed boot leaks simulator
processes that `simctl shutdown`/`delete` do not reap; they accumulate until
`fork()` fails for *everything* — the sweep, the CI runner, and any recovery
job you dispatch afterwards. The box then accepts work and executes nothing,
recoverable only by a console **Reboot** (never Stop). sweep.sh now hard-
cleans after every level and refuses to start one above `PROC_CEILING`; if
you see `failure_mode=process_wall` in a CSV, that guard just saved a host.

## T+0:00 — allocate (the clock starts)

Actions → **AWS Mac host** → Run workflow → `provision`, instance type
`mac2-m2pro.metal`, your key pair name, your home IP as `ssh_cidr`
(e.g. `203.0.113.7/32`). Note the public IP from the run output
(or run the `status` action).

**Immediately set two alarms: T+22h ("start teardown") and T+24h ("release
host").**

## T+0:10 — first contact

```bash
ssh -i simdensity.pem ec2-user@<PUBLIC_IP>     # first boot can take minutes
sudo xcodebuild -license accept && xcodebuild -runFirstLaunch
git clone https://github.com/PGRBryant/awsEC2iOS-test.git simdensity && cd simdensity
./scripts/bootstrap.sh                          # brew + xcodegen + app build
make smoke                                      # N=1,2 IDLE — must be clean
```

If smoke is clean, the day is de-risked. Run sweeps inside `tmux` so an SSH
drop doesn't kill a 3-hour sweep: `tmux new -s sweep`.

## T+1 — IDLE density ladder (~3h)

```bash
./harness/sweep.sh --app app/build/Build/Products/Debug-iphonesimulator/SimDensity.app \
  --levels "1 2 4 8 16 24 32 48 64 80 96" --repeats 2 \
  --profile IDLE --sample-interval 5 --boot-timeout 600 --out results/ec2-idle
python3 harness/analyze.py results/ec2-idle/results.csv --report results/ec2-idle/report.md
```

This finds the headline hard ceiling. If the failure mode is process-count
(not RAM), raise the wall and re-run the top levels:
`sudo sysctl kern.maxproc; sudo launchctl limit maxproc` (record before/after).

## T+4 — ANIMATE ladder (~3h)

```bash
./harness/sweep.sh --app ... --levels "1 2 4 8 16 24 32 40 48" --repeats 2 \
  --profile ANIMATE --sample-interval 5 --boot-timeout 600 --out results/ec2-animate
```

## T+7 — INFER ladder (~3h) — the edge-AI curve

```bash
./harness/sweep.sh --app ... --levels "1 2 4 8 12 16 20 24" --repeats 2 \
  --profile INFER --sample-interval 5 --boot-timeout 600 --out results/ec2-infer
```

The chart that matters: aggregate inf/s vs N. On 3 cores it was still linear
at N=3 (30→46→88). With 12 cores, find the plateau.

## T+10 — shard speedup with real cores (~2h)

```bash
make bootstrap-tests
./harness/shard.sh --levels "1 2 4 6 8 12" --boot-timeout 600 --out results/ec2-shard
```

On 3 cores, 2-way sharding was 0.15× (slower!). This measures where the
crossover actually is when cores exist. This is the CI-economics headline.

## T+13 — analysis, dashboard, and getting data OFF the box

```bash
python3 harness/compare.py \
  runner-7gb=<hosted-runner results.csv if kept> \
  ec2-idle=results/ec2-idle/results.csv
cd harness && python3 dashboard.py ../results/ec2-idle --shard ../results/ec2-shard/speedup.csv && cd ..
# copy EVERYTHING off before teardown — from your laptop:
scp -i simdensity.pem -r ec2-user@<PUBLIC_IP>:simdensity/results ./results-ec2
```

Spare hours before teardown? Phase-7 extras, in value order: re-run the top-3
IDLE levels with `maxproc` raised; a `--repeats 3` pass at the knee levels for
variance; SCROLL profile ladder.

## T+22 — teardown (instance now, host at 24h)

Actions → **AWS Mac host** → `teardown`. Terminating the instance stops
instance billing immediately; the host release will be **refused** until T+24
— that refusal is expected. **Re-run `teardown` just after T+24**, then run
`status` and confirm zero hosts. Done: the bill stops.

## How the box reaches the internet

The Mac has outbound internet from first boot — it pulls an ~8 GB Xcode
`.xip`, installs Homebrew packages, clones from GitHub, and keeps the
Actions runner connected. Three things make that work, and none of them
is IAM:

1. **A public IP.** `provision.sh` passes `--associate-public-ip-address`
   and launches into the default VPC's default subnet.
2. **A route to an Internet Gateway.** The default VPC ships with an IGW
   and a `0.0.0.0/0 → igw-…` route, so packets have somewhere to go.
3. **Open egress.** Security groups allow *all outbound* by default. The
   `simdensity-ssh` group we create only restricts **inbound** (SSH from
   the `ssh_cidr` you pass). We never touch egress.

**IAM is not in the network path.** Two separate planes:

| Plane | Governs | Example here |
|---|---|---|
| **Control (IAM)** | who may *call AWS APIs* — create a VPC, launch an instance, open a security group | the OIDC role's `ec2:RunInstances`, `ec2:CreateSecurityGroup`, … |
| **Data (VPC)** | whether *packets* move — subnets, routes, gateways, security groups, NACLs | public IP + IGW route + default-open egress |

IAM decides whether you may *build* the road; it has no opinion about
traffic once the road exists. An instance with no IAM role still reaches
the internet if its subnet routes there. The SSM role we attach for
Session Manager is not an exception — it grants permission to call SSM
*APIs*, and the agent still needs a network path to reach those endpoints.

### If you want a tighter posture

| Posture | Setup | Trade-off |
|---|---|---|
| **Public subnet** (what we run) | public IP + IGW; inbound limited to your `/32` | simplest; box is directly addressable |
| **Private + NAT** | no public IP; outbound via NAT Gateway | nothing reaches in; ~$0.045/h plus data processing |
| **Fully private** | no IGW/NAT; VPC endpoints for SSM, S3 | most locked down — **Session Manager still works over VPC endpoints**, so you keep a shell with zero internet exposure |

The third row is worth considering for a repeat run: we ended up working
almost entirely through Session Manager anyway, so a private subnet would
have cost no capability. The only thing it breaks is downloading Xcode and
Homebrew from the public internet — which is the argument for baking a
pre-provisioned AMI once and reusing it.

## Contingencies

- **SSH unreachable**: security group only allows your `ssh_cidr` — if your
  IP changed, add the new one: EC2 → Security groups → `simdensity-ssh` →
  edit inbound rules.
- **Boot storms at high N**: raise `--boot-timeout`; the sweep already boots
  sequentially-waited. Slow ≠ failed; the CSV separates them.
- **Runaway box (load so high SSH dies)**: EC2 console → reboot instance.
  Results up to the last completed trial are already in the CSVs.
- **Anything ambiguous**: the harness never leaves sims behind, every trial
  is torn down; when in doubt, `xcrun simctl shutdown all && xcrun simctl
  delete all` and re-run the level.
