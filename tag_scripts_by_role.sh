#!/bin/bash
set -euo pipefail
for f in /usr/local/bin/*; do
  [[ -f "$f" && -x "$f" ]] || continue
  head -n1 "$f" | grep -q '^# ROLE:' && continue
  role="UNKNOWN"
  case "$(basename "$f")" in
    adsb*|readsb*) role="ADSB" ;;
    audio*)        role="AUDIO" ;;
    backup*|dd*)   role="BACKUP" ;;
    ops*|status*)  role="OPS" ;;
  esac
  sed -i "1i# ROLE: $role" "$f"
done
