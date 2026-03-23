#!/bin/bash
#
# recovery_missing_info.sh
# Version : 1.0.0
# Updated : 2026-01-06
#
# 目的:
#   - 「/hp-diagnose/logs が見えない」原因を特定し、回復ルートを確定する
#   - lighttpd alias と診断生成スクリプトの実体を採取する（読み取り専用）
#
# 収集内容:
#   1) lighttpd の hp-diagnose alias 定義（conf）
#   2) hp_adsb_diagnose.sh の存在と中身（先頭～）
#   3) diagnose 成果物（html/json/txt）がどこかに残っていないか探索
#

set -euo pipefail

echo "========================================"
echo " Recovery Missing Info Report"
echo " Host      : $(hostname)"
echo " Timestamp : $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo

echo "## [1] lighttpd: hp-diagnose alias 設定（有効版）"
if [ -f /etc/lighttpd/conf-enabled/90-hp-diagnose.conf ]; then
  sudo sed -n '1,220p' /etc/lighttpd/conf-enabled/90-hp-diagnose.conf
else
  echo "NOT FOUND: /etc/lighttpd/conf-enabled/90-hp-diagnose.conf"
fi
echo

echo "## [2] lighttpd: /hp-diagnose/ へのアクセス制御（deny 等の有無）"
sudo grep -R "hp-diagnose" /etc/lighttpd 2>/dev/null || true
echo

echo "## [3] 診断生成スクリプト: hp_adsb_diagnose.sh"
if [ -f /usr/local/bin/hp_adsb_diagnose.sh ]; then
  ls -l /usr/local/bin/hp_adsb_diagnose.sh
  echo "--- head (1..260) ---"
  sudo sed -n '1,260p' /usr/local/bin/hp_adsb_diagnose.sh
  echo "--- grep: output/log paths ---"
  sudo grep -nE "(/var/www|/var/log|hp-diagnose|diagnose|logs|output|DEST|OUT|REPORT)" /usr/local/bin/hp_adsb_diagnose.sh || true
else
  echo "NOT FOUND: /usr/local/bin/hp_adsb_diagnose.sh"
fi
echo

echo "## [4] diagnose 成果物の残骸探索（/var/log と /var/www）"
sudo find /var/log /var/www -type f 2>/dev/null | \
  grep -E "diagnose-.*\.(html|json|txt)$" | head -n 100 || true
echo

echo "## [5] Web 側に hp-diagnose ディレクトリが存在するか"
ls -ld /var/www/html/hp-diagnose 2>/dev/null || true
ls -ld /var/www/html/hp-diagnose/logs 2>/dev/null || true
echo

echo "========================================"
echo " End of Missing Info Report"
echo "========================================"
