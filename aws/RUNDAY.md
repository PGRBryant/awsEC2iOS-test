# Run day — 24 hours on a mac2-m2pro.metal (M2 Pro · 12 cores · 32 GB)

The clock starts at allocation and cannot stop for 24 hours, so the day is a
schedule, not a vibe. Everything below is copy-paste; timeboxes are loose but
the ordering matters (cheap validation first, expensive sweeps once trusted,
teardown armed before you sleep).

Predicted ceilings for this box (from the hosted-runner RAM fits — the whole
point of today is to check them):

| profile | MB/sim (measured) | predicted ceiling (32 GB, 85% usable) |
|---|---|---|
| IDLE    | ~267  | ~90 sims |
| ANIMATE | ~356  | ~63 sims |
| INFER   | ~1080 | ~22 sims |

Watch for the other walls arriving first: 12 CPU cores, and the ~2,500
process-per-user limit (each sim spawns 15–25 processes, so expect trouble
past ~N=80 on IDLE).

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
