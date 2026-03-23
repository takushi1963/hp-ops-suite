# OPS Repository (status-first)

このリポジトリは、運用系スクリプト群を
**status-first / ChatGPT一発理解**の思想で管理する。

## 構成
- backup/  : バックアップ（dd / rsync）
- adsb/    : ADS-B 受信・配信・可視化
- audio/   : 録音・相関・分析

各ディレクトリは **git worktree** として管理され、
それぞれ独立した履歴を持つ。


## Web dashboards

HTML dashboards are managed as **source of truth** under `web/`.
Files in `/var/www/html` are **deployed copies only**.

### Edit & Deploy
1. Edit files under `web/**`
2. Commit to Git
3. Deploy:
#```bash
./deploy-web.sh

## Entry Points


#```bash
backup/backup-status.sh
adsb/adsb-status.sh
audio/audio-status.sh
---

## System Entry Points（最初に実行）

### Backup

backup/backup-status.sh
adsb/adsb-status.sh
audio/audio-status.sh

