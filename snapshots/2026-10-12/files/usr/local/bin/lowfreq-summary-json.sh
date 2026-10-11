#!/bin/bash
set -euo pipefail
exec /usr/bin/python3 /usr/local/lib/ops-dashboard-repair/collector.py collect
