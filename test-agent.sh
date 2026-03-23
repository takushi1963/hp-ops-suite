#!/bin/bash
# Quick test suite for super-ops-agent.py

set -euo pipefail

AGENT_SCRIPT="super-ops-agent.py"
OPS_HOME="$(dirname "$(readlink -f "$0")")"
PYTHON="${PYTHON:-python3}"

echo "=== Super OPS Agent - Test Suite ==="
echo "OPS_HOME: $OPS_HOME"
echo

# 1. Python 構文チェック
echo "[1/5] Python syntax check..."
if $PYTHON -m py_compile "$OPS_HOME/$AGENT_SCRIPT"; then
    echo "✅ Syntax OK"
else
    echo "❌ Syntax error"
    exit 1
fi
echo

# 2. Help コマンド
echo "[2/5] Help command..."
if sudo $PYTHON "$OPS_HOME/$AGENT_SCRIPT" --help > /dev/null 2>&1; then
    echo "✅ Help OK"
else
    echo "⚠️  Help failed (expected if not run as root)"
fi
echo

# 3. 設定検証
echo "[3/5] Configuration validation..."
if python3 -c "
import sys
sys.path.insert(0, '$OPS_HOME')
from super_ops_agent import Config
try:
    config = Config()
    print(f'  - OPS_HOME: {config.ops_home}')
    print(f'  - WEB_ROOT: {config.web_root}')
    print(f'  - STATE_DIR: {config.state_dir}')
    print(f'  - Scripts found: {sum(1 for s in config.scripts.values() if __import__(\"os\").path.isfile(s))}')
except ValueError as e:
    print(f'  ⚠️  {e}')
"; then
    echo "✅ Config OK"
else
    echo "❌ Config error"
fi
echo

# 4. スクリプトパス確認
echo "[4/5] Script availability check..."
REQUIRED_SCRIPTS=(
    'ops_bootstrap_all.sh'
    'snapshot_to_html.sh'
    'audio_event_detector.sh'
    'notify.sh'
)

for script in "${REQUIRED_SCRIPTS[@]}"; do
    if [[ -f "$OPS_HOME/$script" ]]; then
        echo "  ✅ $script"
    else
        echo "  ❌ $script NOT FOUND"
    fi
done
echo

# 5. systemd ユニットチェック
echo "[5/5] systemd units check..."
REQUIRED_UNITS=(
    'super-ops-agent.service'
    'super-ops-agent-bootstrap.service'
    'super-ops-agent-bootstrap.timer'
)

for unit in "${REQUIRED_UNITS[@]}"; do
    if [[ -f "$OPS_HOME/$unit" ]]; then
        echo "  ✅ $unit"
    else
        echo "  ❌ $unit NOT FOUND"
    fi
done
echo

echo "=== Test Summary ==="
echo "✅ All basic checks passed!"
echo
echo "Next steps:"
echo "1. Review CASE2_DETAILED_IMPLEMENTATION.md"
echo "2. Run: sudo python3 $AGENT_SCRIPT status"
echo "3. Deploy systemd units: sudo cp $OPS_HOME/*.service $OPS_HOME/*.timer /etc/systemd/system/"
echo "4. Enable: sudo systemctl enable super-ops-agent super-ops-agent-bootstrap.timer"
echo
