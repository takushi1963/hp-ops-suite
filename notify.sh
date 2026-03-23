#!/bin/bash
# notify.sh
set -euo pipefail
source "$(dirname "$0")/notify.conf"

title="$1"
message="$2"
prio="${3:-3}"

BASE_URL="http://192.168.0.5"

curl -fsS \
  -H "Title: ${title}" \
  -H "Priority: ${prio}" \
  -d "${HOSTNAME}: ${message}
- Portal: ${BASE_URL}/
- System: ${BASE_URL}/system_snapshot/
- Concept: ${BASE_URL}/concept_snapshot/
- OPS: ${BASE_URL}/ops/
- Inventory: ${BASE_URL}/inventory/" \
  "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null
