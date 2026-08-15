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

## Step 0 — grant the harness AWS access (one-time, console)

The scripts need an identity allowed to spin up EC2 Mac hardware. Two options
share the same least-privilege policy (0.1 below):

- **Option A — IAM user + access key** (0.2–0.3): simplest; for running
  `provision.sh` from your own machine.
- **Option B — OIDC role for GitHub Actions** (0.5): **no stored secrets at
  all** — workflows assume a role scoped to this repo and receive credentials
  that expire in minutes. Preferred once you want CI to drive provisioning
  (`.github/workflows/aws-provision.yml`). If you set this up, deactivate and
  delete any Option-A access key afterwards.

### 0.1 Create the policy

**Console → IAM → Policies → Create policy → JSON**, paste this, name it
`SimDensityProvisioning`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DiscoverAndDescribe",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeHosts",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeSubnets",
        "ec2:DescribeKeyPairs",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeImages",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ProvisionMacHost",
      "Effect": "Allow",
      "Action": [
        "ec2:AllocateHosts",
        "ec2:ReleaseHosts",
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:CreateSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CreateTags"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": { "aws:RequestedRegion": "us-east-1" }
      }
    },
    {
      "Sid": "QuotaAndBudget",
      "Effect": "Allow",
      "Action": [
        "servicequotas:ListServiceQuotas",
        "servicequotas:GetServiceQuota",
        "servicequotas:RequestServiceQuotaIncrease",
        "budgets:ViewBudget",
        "budgets:ModifyBudget"
      ],
      "Resource": "*"
    }
  ]
}
```

Change the `aws:RequestedRegion` value if you provision elsewhere. The
mutating EC2 actions are region-locked; the describe/SSM reads are not
(several are global or needed for discovery).

### 0.2 Create the user and attach the policy

1. **Console → IAM → Users → Create user** — name it `simdensity-provisioner`.
   Leave **"Provide user access to the AWS Management Console" unchecked**
   (CLI-only identity; no password, no console login).
2. **Permissions → Attach policies directly** → select `SimDensityProvisioning`
   → **Create user**.

### 0.3 Create an access key and configure the CLI

1. Open the user → **Security credentials → Create access key** → choose
   **Command Line Interface (CLI)** → acknowledge → **Create**.
2. On the machine that will run these scripts:

```bash
aws configure          # paste the Access key ID and Secret access key
# Default region: us-east-1 (match the policy's region condition)
aws sts get-caller-identity   # should print the simdensity-provisioner ARN
```

⚠️ The secret key is shown **once** — store it in a password manager. Never
commit it, and never paste it into a chat or issue; anything that leaks it can
allocate 24-hour-minimum Mac hardware on your bill. If it ever leaks:
IAM → the user → Security credentials → **Deactivate** the key immediately.

### 0.4 Create the SSH key pair (the scripts assume one exists)

**Console → EC2 → Key pairs → Create key pair** — name it (e.g.
`simdensity`), type ED25519, download the `.pem`, `chmod 400` it. Pass the
name to `provision.sh` via `KEY_NAME=simdensity`.

### 0.5 Option B — OIDC role for GitHub Actions (no stored secrets)

1. **Add GitHub as an identity provider** — Console → IAM → Identity
   providers → **Add provider** → *OpenID Connect*:
   - Provider URL: `https://token.actions.githubusercontent.com`
   - Audience: `sts.amazonaws.com`
2. **Create the role** — IAM → Roles → **Create role**. The wizard has three
   screens:
   1. *Select trusted entity*: choose **Web identity**, pick the provider from
      step 1, audience `sts.amazonaws.com`, GitHub organization `PGRBryant`,
      repository `awsEC2iOS-test`. (This screen writes the trust policy.)
   2. *Add permissions*: **do not create an inline policy** — search the
      existing-policies list for `SimDensityProvisioning` (from 0.1; filter
      "Customer managed" if needed), tick it, Next. If it's missing, create it
      via 0.1 in another tab first.
   3. *Name, review, create*: name it `SimDensityGithubOIDC` → **Create role**.

   The resulting trust policy should look like:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
         "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:PGRBryant/awsEC2iOS-test:*" }
       }
     }]
   }
   ```

   Tighten `:sub` to `repo:PGRBryant/awsEC2iOS-test:ref:refs/heads/main` if
   you only ever want main-branch workflows to hold hardware power.
3. **Tell the workflow the role ARN** — repo → Settings → Secrets and
   variables → Actions → **Variables** → new repository variable
   `AWS_ROLE_ARN` = the role's ARN (it's an identifier, not a secret, so a
   variable is fine).
4. Done — `.github/workflows/aws-provision.yml` (manual dispatch only)
   assumes the role via `aws-actions/configure-aws-credentials`. No key
   material exists anywhere; revoking access = deleting the role.

**Troubleshooting `Not authorized to perform sts:AssumeRoleWithWebIdentity`:**
the token was minted fine but the trust policy's conditions didn't match its
claims. Diagnosed here the hard way — the decisive tool is the workflow's
"Decode OIDC token claims" step, which prints the real `sub` to compare
character-for-character.

What we actually found: GitHub now stamps **immutable numeric IDs** into the
sub claim —

```
repo:PGRBryant@9953275/awsEC2iOS-test@1331487463:ref:refs/heads/main
```

— so the textbook pattern `repo:ORG/REPO:*` never matches. Use ID-tolerant
`StringLike` patterns (and remember IAM string matching is case-sensitive,
and `*` wildcards only work under `StringLike`, never `StringEquals`):

```json
"StringLike": { "token.actions.githubusercontent.com:sub": [
  "repo:PGRBryant@*/awsEC2iOS-test@*:*",
  "repo:PGRBryant/awsEC2iOS-test:*"
] }
```

Also verify the identity provider is exactly
`token.actions.githubusercontent.com` with audience `sts.amazonaws.com`.
Retest free with the workflow's `status` action.

## Step 1 — quota (do this days ahead; it's the only real lead-time item)

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

## Step 2 — cost guardrails (before allocating anything)

```bash
# Billing alarms live in us-east-1 regardless of where the host runs.
aws budgets create-budget --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --budget '{"BudgetName":"simdensity","BudgetLimit":{"Amount":"75","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}'
```

Also set a calendar reminder for **24h after allocation** to release the host.

## Step 3 — provision

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

## Step 4 — connect & bootstrap the harness

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

## Step 5 — release (stop billing)

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
