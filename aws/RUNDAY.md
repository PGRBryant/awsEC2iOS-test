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
| ANIMATE | ~356 MB/sim  | ~63 sims | contaminated run — see the process-wall lesson |
| INFER   | ~1,080 MB/sim | ~22 sims | **~1.5 GB/sim → 12 clean, never plateaued (memory-bound)** |

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
(e.g. `203.0.113.7/32`). The workflow hunts every AZ offering the type and
waits out the host's `pending` state automatically — but capacity is a
lottery: we needed **10 hourly attempts (~6 h)** before one landed. If it
fails on capacity, just re-dispatch later; nothing is billed until a host
allocates.

**The moment allocation succeeds, set two alarms: T+22h ("start teardown")
and T+24h ("release host").** Note the public IP from the run output (or
run the `status` action).

**Grow the disk now.** The default 100 GB dies mid-ladder. Console → EC2 →
Volumes → Modify → 400 GB. It will not take effect until the reboot below.

## First contact — two doors in

**Door 1, SSH** (if you hold the `.pem`):

```bash
ssh -i simdensity.pem ec2-user@<PUBLIC_IP>    # first boot resizes APFS; be patient
```

**Door 2, Session Manager** (keyless — what we actually used after losing
the `.pem`): attach an instance role carrying `AmazonSSMManagedInstanceCore`
(EC2 → instance → Actions → Security → Modify IAM role), wait up to ~30 min
for the agent to see its credentials, then Systems Manager → Session
Manager → Start session. If sshd is crash-looping in the console output,
the AMI shipped without host keys: `sudo ssh-keygen -A`.

## The Xcode hour (budget ~1.5 h — the AMI ships without it)

On a trusted browser, log into developer.apple.com/download/all, start the
Xcode `.xip` download, and copy the request from DevTools as cURL. Then on
the Mac:

```bash
cd ~ && <pasted curl command> -o Xcode.xip      # datacenter-speed download
cd /Applications && sudo xip --expand ~/Xcode.xip   # ~20 min, silent
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS                # the simulator runtime (~7 GB)
xcrun simctl list runtimes                      # success = an iOS runtime listed
rm ~/Xcode.xip
```

Skip the `xcodes` CLI: the Homebrew formula compiles from source (which
needs Xcode — circular) and its login rejects passwords that work in a
browser.

**Now reboot once** (console → Instance state → Reboot — never Stop) so
macOS sees the grown volume, then run the `resize-disk` action of
`ec2-maintenance.yml`. Confirm `df -h /` shows ~400 GB.

## Hand the box to CI (recommended over tmux)

Register a self-hosted runner (repo → Settings → Actions → Runners → New
self-hosted runner, macOS/ARM64; Enter through every `config.sh` prompt),
then make it boot-persistent with the `install-runner-daemon` action of
`ec2-maintenance.yml` — `svc.sh` needs a GUI login the box doesn't have,
and `nohup` dies on reboot. (Daemon PATH is bare; the workflows already
re-add `/opt/homebrew/bin`.)

From here the whole day is workflow dispatches of `sweep.yml`, and every
run publishes its results append-only to the `ec2-results` branch — data
survives even if the box dies mid-ladder, which it will try to do.

```bash
git clone https://github.com/PGRBryant/awsEC2iOS-test.git simdensity && cd simdensity
./scripts/bootstrap.sh && make smoke            # N=1,2 must be clean before anything paid
```

## The ladders — as actually run, with what to expect

**IDLE** — `sweep.yml`: mode `sweep`, profile `IDLE`, levels `1 2 4 8 16 24`,
repeats 2, boot_timeout 600 (~2.5 h). Expect: 16 clean, 24 refuses
(`launchd_sim` cannot bind a session), ~1,115 MB/sim, 15 GB of swap and
315 s boot walls at 16. Going past 24 buys nothing but risk.

**INFER** — levels `1 2 4 6 8 10 12` (~5 h; inference makes everything
slower). Expect: 45.6 → 523.9 aggregate inf/s, per-sim efficiency peaking
at **6**, swap from 8, no plateau — memory-bound, not core-bound.

**ANIMATE** — levels `1 2 4 8 12 16 20` (~3 h). Run it on a *clean* box:
ours ran after a failed boot leaked ~4,600 processes and measured only the
contamination. The harness now hard-cleans between levels, but if a prior
ladder ended at its ceiling, reboot before this one.

**Shard** — mode `shard`, levels `1 2 4 6 8` (~1 h). Expect 1.65× at 2
shards and *worse than unsharded* from 4 up: each shard pays 40–90 s of
boot+install before its first test.

## Getting data off the box

Nothing to do — `sweep.yml` publishes every run to the `ec2-results`
branch as it completes, and `ec2-maintenance.yml`'s `clean` action rescues
results stranded by a crash *before* checkout can delete them. `scp` is
only needed for ad-hoc files from manual runs.

## T+22 — teardown (instance now, host at 24h)

Actions → **AWS Mac host** → `teardown`. Terminating the instance stops
instance billing immediately; the host release will be **refused** until
T+24 — that refusal is expected. **Re-run `teardown` just after T+24**,
then run `status` and confirm zero hosts. Done: the bill stops.

## How connectivity works — three ways in, one way out

The box had three control channels during the run, and it pays to notice
that **two of the three "ways in" are really outbound connections the Mac
initiates**:

| Channel | Direction | Needs an open inbound port? | Needs a credential? |
|---|---|---|---|
| **SSH** | inbound | yes — 22, from your `ssh_cidr` only | the `.pem` |
| **SSM Session Manager** | *outbound* — the agent long-polls AWS and your "session" rides that channel | no | an instance role |
| **Actions runner** | *outbound* — long-polls GitHub for jobs | no | a registration token, once |

That is why losing the `.pem` was recoverable, and why the box could be
driven entirely from CI with port 22 locked to one home IP: SSH is the
only channel that requires a hole in the wall.

**The way out** takes three ingredients, and none of them is IAM:

1. **A public IP** — `provision.sh` passes `--associate-public-ip-address`
   into the default VPC's default subnet.
2. **A route to the Internet Gateway** — the default VPC ships with
   `0.0.0.0/0 → igw-…`.
3. **Open egress** — security groups allow all *outbound* by default; the
   `simdensity-ssh` group only restricts inbound.

That trio is how the Mac pulled an 8 GB Xcode image, installed Homebrew,
and kept its runner connected from first boot with zero configuration.

**IAM is not in the packet path.** Two planes: IAM (control) decides who
may *call AWS APIs* — launch instances, open security groups; the VPC
(data) decides whether *packets* move. IAM authorizes building the road,
never the traffic on it. The SSM role is no exception — it grants the
right to call SSM APIs; the agent still needs the network path above.

**Tighter postures, if you want one:**

| Posture | Setup | Trade-off |
|---|---|---|
| **Public subnet** (this run) | public IP + IGW; inbound = your `/32` | simplest; box is addressable |
| **Private + NAT** | no public IP; egress via NAT Gateway | nothing reaches in; ~$0.045/h + data |
| **Fully private** | no IGW/NAT; VPC endpoints for SSM/S3 | Session Manager still works — a shell with zero internet exposure; but no public downloads, so bake Xcode into an AMI first |

We lived in Session Manager anyway, so the third row would have cost this
run nothing — it is the natural pairing for a pre-provisioned AMI.

## Seeing the screen (VNC) — the money shot, taken carefully

macOS ships Screen Sharing (a VNC server on port 5900). Sixteen simulators
tiled across one desktop is the most convincing artifact this experiment
can produce — **but a GUI session spins up WindowServer and consumes real
memory and CPU, so never do this during a measured ladder.** Take the
screenshot in its own window, outside the data runs.

On the Mac (SSM shell):

```bash
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate -configure -access -on -restart -agent -privs -all
sudo launchctl enable system/com.apple.screensharing
sudo passwd ec2-user            # VNC authenticates with the account password
```

From your laptop — tunnel it, never open 5900 to the internet:

```bash
# keyless, via SSM:
aws ssm start-session --target <INSTANCE_ID> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["5900"],"localPortNumber":["5900"]}'
# or with the .pem:
ssh -i simdensity.pem -L 5900:localhost:5900 ec2-user@<PUBLIC_IP>
```

Then Finder → **Cmd+K** → `vnc://localhost:5900` (any VNC client works).
One caveat: it is a 1:1 GUI session — one viewer at a time.

## Contingencies

- **SSH unreachable**: the security group only allows your `ssh_cidr` — if
  your IP changed, add the new one (EC2 → Security groups →
  `simdensity-ssh`), or skip SSH entirely and use Session Manager.
- **Boot storms at high N**: raise `--boot-timeout`; slow ≠ failed, and the
  CSV separates them.
- **Box accepts jobs but executes nothing** (runner picks up work, zero
  steps run): that is the process wall — `fork()` is failing machine-wide.
  Console → **Reboot** (never Stop — Stop triggers host scrubbing). The
  LaunchDaemon brings the runner back on its own.
- **Disk full**: dispatch `ec2-maintenance.yml` → `clean`; it rescues any
  stranded results first, then reclaims space.
- **Anything ambiguous**: `xcrun simctl shutdown all && xcrun simctl delete
  all` and re-run the level — the harness never depends on leftover sims.
