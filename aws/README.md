# Phase 1 — provision an EC2 Mac Dedicated Host

Everything here spends money. Do **Phase 0 locally first** (repo root README) so
the paid host only runs proven code.

## The one hard constraint

EC2 Mac instances run only on **Dedicated Hosts** with a **24-hour minimum
allocation** — you cannot release the host for a full day after allocating it
([AWS docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-mac-instances.html)).
Plan the run to fit one window: allocate, bootstrap, sweep, analyze, then release
at ~24h. Terminating the *instance* stops instance charges immediately, but the
*host* keeps billing until released.

---

## Step 0 — quota (do this days ahead; it's the only real lead-time item)

New accounts almost always have a **quota of 0** for Mac Dedicated Hosts, and the
increase can take a day or more. Request it now, before you plan to run.

```bash
REGION=us-east-1                     # pick your region
# Find the quota code for your instance family (e.g. mac2-m2):
aws service-quotas list-service-quotas --service-code ec2 --region $REGION \
  --query "Quotas[?contains(QuotaName, 'Dedicated mac')].[QuotaName,QuotaCode,Value]" \
  --output table

# Request at least 1 (use the QuotaCode from above):
aws service-quotas request-service-quota-increase --service-code ec2 --region $REGION \
  --quota-code <QUOTA_CODE> --desired-value 1
```

Or in the console: **Service Quotas → Amazon EC2 → "Running Dedicated
`<family>` Hosts" → Request increase**. Confirm the *Applied* value is ≥ 1
before provisioning.

## Step 1 — cost guardrails (before allocating anything)

```bash
# Billing alarms live in us-east-1 regardless of where the host runs.
aws budgets create-budget --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --budget '{"BudgetName":"simdensity","BudgetLimit":{"Amount":"75","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}'
```

Also set a calendar reminder for **24h after allocation** to release the host.

## Step 2 — provision

```bash
export KEY_NAME=my-ec2-keypair       # an existing EC2 key pair you hold the .pem for
export REGION=us-east-1

# Optional discovery:
./aws/provision.sh --list-macos      # available macOS versions (SSM)
./aws/provision.sh --list-azs        # AZs offering the chosen type

# Directional sweet spot — M2 / 24 GB (cheaper, hits the ceiling sooner):
./aws/provision.sh --type mac2-m2.metal

# Or maximize the ceiling — M4 Pro / 48 GB:
./aws/provision.sh --type mac-m4pro.metal
```

`provision.sh` resolves the macOS AMI via SSM, picks an AZ that offers the type,
uses a default-VPC subnet, opens SSH from **your IP only**, allocates the host,
launches the instance, and prints the SSH command. Ids are saved to `aws/.state`.

## Step 3 — connect & bootstrap the harness

First boot resizes APFS and can take several minutes.

```bash
ssh ec2-user@<public-ip>

# on the Mac:
xcodebuild -runFirstLaunch                     # accept license / finish setup
git clone <this-repo-url> simdensity && cd simdensity
./scripts/bootstrap.sh                          # build the app once
make sweep LEVELS="1 2 4 8 16 24 32" REPEATS=3  # the experiment
make analyze                                    # the two headline numbers
```

Copy results back before releasing the host:

```bash
scp -r ec2-user@<public-ip>:simdensity/results ./results-ec2
```

## Step 4 — release (stop billing)

```bash
./aws/teardown.sh
```

Terminates the instance immediately; releases the host if the 24h minimum has
passed (it prints the reason and keeps state if release is still refused — re-run
after the window).

---

## Optional — real CI/CD (Phase 3)

`.github/workflows/sweep.yml` runs the sweep on a **self-hosted GitHub Actions
runner**. On the Mac:

```bash
# from your repo: Settings → Actions → Runners → New self-hosted runner (macOS)
# follow the token'd ./config.sh steps, then run it as a service:
./svc.sh install && ./svc.sh start
```

Then trigger the workflow (Actions tab → "Simulator density sweep" → Run) with
your chosen `levels`/`repeats`; it uploads `results.csv`, charts, and the failing
screenshots as artifacts. That closes the loop: push → sweep on the Mac →
downloadable results.

## Cost note

Because of the 24h minimum you're paying for a full day regardless of instance
type, and the per-hour delta between the small Apple-silicon box and the big one
is modest. Going smaller mainly buys you a **faster path to the ceiling** (less
RAM ⇒ fewer sims before failure ⇒ shorter sweeps), not big savings. Confirm live
per-type pricing in the console before allocating.
