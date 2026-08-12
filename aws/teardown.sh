#!/usr/bin/env bash
# teardown.sh — terminate the Mac instance and release the Dedicated Host.
#
# Reads aws/.state written by provision.sh. Releasing a Mac host is REFUSED by
# AWS until 24h after allocation — that refusal is expected, not an error in
# this script. Terminating the instance stops instance charges immediately, but
# the host keeps billing until released, so run this again after the 24h window
# if the release is initially refused.
set -uo pipefail

STATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.state"
log()  { printf '\033[36m[teardown]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[teardown]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[teardown] error:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$STATE_FILE" ] || die "no state file at $STATE_FILE — pass ids manually with aws ec2 terminate-instances / release-hosts"
# shellcheck disable=SC1090
. "$STATE_FILE"
: "${REGION:?}" "${HOST_ID:?}"
aws_() { aws --region "$REGION" "$@"; }

if [ -n "${INSTANCE_ID:-}" ]; then
  log "terminating instance $INSTANCE_ID..."
  aws_ ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 \
    && aws_ ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" \
    && log "instance terminated (instance charges stopped)" \
    || warn "instance may already be gone"
fi

log "attempting to release Dedicated Host $HOST_ID..."
if aws_ ec2 release-hosts --host-ids "$HOST_ID" 2>/tmp/release.err; then
  log "host released — billing stopped. Done."
  rm -f "$STATE_FILE"
else
  warn "release refused. Reason:"
  sed 's/^/    /' /tmp/release.err >&2
  warn "If this is the 24h minimum: the host is still billing. Re-run teardown.sh"
  warn "after $(date -u) + 24h from allocation. State kept at $STATE_FILE."
fi
