#!/usr/bin/env bash
# provision.sh — allocate an EC2 Mac Dedicated Host and launch a macOS instance.
#
# ⚠️  This STARTS THE 24-HOUR BILLING CLOCK. A Mac Dedicated Host cannot be
#     released for 24 hours after allocation (Apple licensing). Run Phase 0
#     locally first so the paid host only ever runs known-good code.
#
# Requires: awscli v2, configured credentials, an existing EC2 key pair.
# Uses only `aws` + `--query` (no jq). Writes host/instance ids to aws/.state
# so teardown.sh can find them.
set -euo pipefail

# --- config (override via env or flags) ---
REGION="${REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"
INSTANCE_TYPE="${INSTANCE_TYPE:-mac2-m2.metal}"   # directional sweet spot: M2 / 24GB
MACOS="${MACOS:-sequoia}"                          # SSM codename; see --list-macos
KEY_NAME="${KEY_NAME:-}"                           # REQUIRED: an existing EC2 key pair
AZ="${AZ:-}"                                        # optional; auto-picked if empty
SUBNET_ID="${SUBNET_ID:-}"                          # optional; default-VPC subnet if empty
SG_ID="${SG_ID:-}"                                  # optional; a /32 SSH SG is made if empty
STATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.state"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20; cat <<EOF

Flags:  --type T  --region R  --macos NAME  --key NAME  --az AZ
        --subnet ID  --sg ID  --list-macos  --list-azs
Env:    same names uppercased (INSTANCE_TYPE, REGION, MACOS, KEY_NAME, ...)
EOF
}

log()  { printf '\033[36m[provision]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[provision]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[provision] error:\033[0m %s\n' "$*" >&2; exit 1; }
aws_() { aws --region "$REGION" "$@"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --type) INSTANCE_TYPE="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --macos) MACOS="$2"; shift 2;;
    --key) KEY_NAME="$2"; shift 2;;
    --az) AZ="$2"; shift 2;;
    --subnet) SUBNET_ID="$2"; shift 2;;
    --sg) SG_ID="$2"; shift 2;;
    --list-macos)
      aws --region "$REGION" ssm get-parameters-by-path \
        --path /aws/service/ec2-macos --recursive \
        --query 'Parameters[?contains(Name,`arm64_mac/latest/image_id`)].Name' \
        --output text | tr '\t' '\n'; exit 0;;
    --list-azs)
      aws --region "$REGION" ec2 describe-instance-type-offerings \
        --location-type availability-zone \
        --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
        --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n'; exit 0;;
    -h|--help) usage; exit 0;;
    *) die "unknown arg: $1";;
  esac
done

command -v aws >/dev/null 2>&1 || die "awscli not found — install AWS CLI v2"
aws_ sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not working (aws sts get-caller-identity failed)"
[ -n "$KEY_NAME" ] || die "KEY_NAME is required (an existing EC2 key pair). Set --key or KEY_NAME."
aws_ ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1 || die "key pair '$KEY_NAME' not found in $REGION"

log "region=$REGION  type=$INSTANCE_TYPE  macos=$MACOS  key=$KEY_NAME"

# --- resolve macOS AMI via SSM (robust vs image-name scraping) ---
SSM_PATH="/aws/service/ec2-macos/${MACOS}/arm64_mac/latest/image_id"
AMI_ID="$(aws_ ssm get-parameters --names "$SSM_PATH" \
          --query 'Parameters[0].Value' --output text 2>/dev/null || true)"
[ -n "$AMI_ID" ] && [ "$AMI_ID" != "None" ] || \
  die "no AMI for macOS '$MACOS' in $REGION. List options: $0 --list-macos"
log "AMI: $AMI_ID"

# --- reuse an already-allocated host, if state says we have one ---
# A failed run-instances after a successful allocate-hosts leaves a host
# billing with nothing on it. Rerunning must launch onto THAT host, never
# allocate a second (double 24h bill). State restored by CI or a prior run.
HOST_ID=""
if [ -s "$STATE_FILE" ]; then
  SAVED_HOST="$(sed -n 's/^HOST_ID=//p' "$STATE_FILE")"
  SAVED_AZ="$(sed -n 's/^AZ=//p' "$STATE_FILE")"
  SAVED_TYPE="$(sed -n 's/^INSTANCE_TYPE=//p' "$STATE_FILE")"
  SAVED_INSTANCE="$(sed -n 's/^INSTANCE_ID=//p' "$STATE_FILE")"
  if [ -n "$SAVED_INSTANCE" ]; then
    inst_state="$(aws_ ec2 describe-instances --instance-ids "$SAVED_INSTANCE" \
      --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown)"
    case "$inst_state" in
      pending|running|stopping|stopped)
        die "instance $SAVED_INSTANCE already exists ($inst_state) — nothing to provision. Use status or teardown." ;;
    esac
  fi
  if [ -n "$SAVED_HOST" ]; then
    host_state="$(aws_ ec2 describe-hosts --host-ids "$SAVED_HOST" \
      --query 'Hosts[0].State' --output text 2>/dev/null || echo unknown)"
    if [ "$host_state" = "available" ] || [ "$host_state" = "pending" ]; then
      [ -z "$SAVED_TYPE" ] || [ "$SAVED_TYPE" = "$INSTANCE_TYPE" ] || \
        die "saved host $SAVED_HOST is $SAVED_TYPE but --type is $INSTANCE_TYPE — they must match"
      HOST_ID="$SAVED_HOST"; AZ="$SAVED_AZ"
      log "reusing already-allocated Dedicated Host $HOST_ID in $AZ (state: $host_state) — skipping allocation"
    else
      warn "saved host $SAVED_HOST is '$host_state' — ignoring stale state, allocating fresh"
    fi
  fi
fi

# --- allocate the Dedicated Host, hunting across AZs (24h clock starts) ---
# Mac capacity is scarce and per-AZ (quota is permission, not inventory), so
# a fixed AZ frequently hits InsufficientHostCapacity while a neighbor has
# stock. Try every AZ offering the type unless --az pinned one.
if [ -z "$HOST_ID" ]; then
  if [ -n "$AZ" ]; then
    CANDIDATE_AZS="$AZ"
  else
    CANDIDATE_AZS="$(aws_ ec2 describe-instance-type-offerings --location-type availability-zone \
        --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
        --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | sort)"
    [ -n "$CANDIDATE_AZS" ] || die "$INSTANCE_TYPE not offered in any AZ of $REGION"
  fi
  warn "allocating Dedicated Host — this starts the 24-HOUR minimum billing window."
  for candidate in $CANDIDATE_AZS; do
    log "trying $candidate..."
    set +e
    alloc_out="$(aws_ ec2 allocate-hosts --instance-type "$INSTANCE_TYPE" \
      --availability-zone "$candidate" --auto-placement on --quantity 1 \
      --tag-specifications 'ResourceType=dedicated-host,Tags=[{Key=project,Value=simdensity}]' \
      --query 'HostIds[0]' --output text 2>&1)"
    alloc_rc=$?
    set -e
    if [ "$alloc_rc" -eq 0 ] && [ -n "$alloc_out" ] && [ "$alloc_out" != "None" ]; then
      HOST_ID="$alloc_out"; AZ="$candidate"; break
    fi
    case "$alloc_out" in
      *InsufficientHostCapacity*|*Insufficient\ capacity*)
        warn "no $INSTANCE_TYPE capacity in $candidate right now" ;;
      *) die "allocate-hosts failed in $candidate: $alloc_out" ;;
    esac
  done
  [ -n "$HOST_ID" ] || die "no $INSTANCE_TYPE capacity in ANY AZ of $REGION right now. \
Mac capacity churns hourly — re-run later (off-peak US hours are best)."
fi
log "Dedicated Host: $HOST_ID in $AZ"
printf 'HOST_ID=%s\nREGION=%s\nAZ=%s\nINSTANCE_TYPE=%s\n' "$HOST_ID" "$REGION" "$AZ" "$INSTANCE_TYPE" > "$STATE_FILE"

# --- wait for the host to finish provisioning ---
# A freshly allocated Mac host sits in 'pending' (sometimes for a long while)
# and run-instances against a pending host fails with a misleading
# InvalidHostId "does not exist". Only 'available' accepts launches.
HOST_WAIT_SECS="${HOST_WAIT_SECS:-2400}"
waited=0
while :; do
  host_state="$(aws_ ec2 describe-hosts --host-ids "$HOST_ID" \
    --query 'Hosts[0].State' --output text 2>/dev/null || echo unknown)"
  case "$host_state" in
    available) log "host $HOST_ID is available"; break ;;
    pending|under-assessment|unknown) ;;
    *) die "host $HOST_ID entered state '$host_state' — cannot launch onto it. Check the console; teardown if it's dead." ;;
  esac
  [ "$waited" -lt "$HOST_WAIT_SECS" ] || \
    die "host $HOST_ID still '$host_state' after $((HOST_WAIT_SECS/60)) min. It stays allocated and state is saved — re-run provision later to launch onto it."
  log "host state: $host_state — waiting for 'available' (${waited}s elapsed)"
  sleep 30; waited=$((waited+30))
done

# --- default-VPC subnet in the winning AZ, if not supplied ---
if [ -z "$SUBNET_ID" ]; then
  SUBNET_ID="$(aws_ ec2 describe-subnets \
    --filters "Name=availability-zone,Values=$AZ" "Name=default-for-az,Values=true" \
    --query 'Subnets[0].SubnetId' --output text)"
  [ -n "$SUBNET_ID" ] && [ "$SUBNET_ID" != "None" ] || \
    die "no default subnet in $AZ — host $HOST_ID is allocated; pass --subnet and rerun, or teardown"
fi
log "subnet: $SUBNET_ID"

# --- SSH security group scoped to your current public IP, if not supplied ---
# SSH_CIDR overrides the autodetected IP (needed when this runs in CI: the
# runner's IP is not where you'll SSH from).
if [ -z "$SG_ID" ]; then
  if [ -n "${SSH_CIDR:-}" ]; then
    MYIP="${SSH_CIDR%/*}"
  else
    MYIP="$(curl -fsS https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')"
  fi
  [ -n "$MYIP" ] || die "could not determine your public IP — pass --sg <id> or set SSH_CIDR"
  VPC_ID="$(aws_ ec2 describe-subnets --subnet-ids "$SUBNET_ID" \
            --query 'Subnets[0].VpcId' --output text)"
  SG_ID="$(aws_ ec2 describe-security-groups \
            --filters "Name=group-name,Values=simdensity-ssh" "Name=vpc-id,Values=$VPC_ID" \
            --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)"
  if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
    SG_ID="$(aws_ ec2 create-security-group --group-name simdensity-ssh \
             --description "SSH to SimDensity EC2 Mac" --vpc-id "$VPC_ID" \
             --query 'GroupId' --output text)"
    log "created security group $SG_ID"
  fi
  aws_ ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr "${MYIP}/32" >/dev/null 2>&1 || true
  log "SSH allowed from ${MYIP}/32 via $SG_ID"
fi

# --- launch the Mac instance onto the host ---
log "launching instance onto host..."
INSTANCE_ID="$(aws_ ec2 run-instances --instance-type "$INSTANCE_TYPE" \
  --image-id "$AMI_ID" --key-name "$KEY_NAME" \
  --placement "Tenancy=host,HostId=$HOST_ID" \
  --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=project,Value=simdensity},{Key=Name,Value=simdensity-mac}]' \
  --query 'Instances[0].InstanceId' --output text)" \
  || die "run-instances failed (host $HOST_ID left allocated — rerun or run teardown.sh)"
echo "INSTANCE_ID=$INSTANCE_ID" >> "$STATE_FILE"
log "instance: $INSTANCE_ID — waiting for running state..."

aws_ ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUB_IP="$(aws_ ec2 describe-instances --instance-ids "$INSTANCE_ID" \
          --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
echo "PUBLIC_IP=$PUB_IP" >> "$STATE_FILE"

printf '\n\033[32m[provision] host is up.\033[0m\n'
cat <<EOF
  instance : $INSTANCE_ID
  public IP: $PUB_IP
  ssh      : ssh ec2-user@$PUB_IP     (first boot resizes APFS and can take several minutes)

  Next:  bootstrap the harness on the Mac (see aws/README.md), then run the sweep.

  ⚠️  24-HOUR CLOCK IS RUNNING. Release with:  aws/teardown.sh
      (release is refused until 24h after allocation — that's expected.)
EOF
