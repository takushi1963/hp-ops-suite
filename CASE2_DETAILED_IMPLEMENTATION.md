# Super OPS Agent - 案2 実装詳細

## アーキテクチャ概要

```
┌─────────────────────────────────────────────────────────┐
│  Python制御層（薄い）: super-ops-agent.py - 500行  │
├────────────────────────────────────┬────────────────────┤
│  ScriptExecutor                    │ NotificationEngine │
│  (既存スクリプト呼び出し)          │  (Ntfy 通知)       │
├────────────────────────────────────┼────────────────────┤
│ 既存20+シェルスクリプト（実装層）  │                    │
│ - ops_bootstrap_all.sh             │ DashboardManager   │
│ - snapshot_to_html.sh              │ (HTML生成・更新)   │
│ - audio_event_detector.sh          │                    │
│ - notify.sh                        │                    │
│ - その他19個...                   │                    │
├─────────────────────────────────────────────────────────┤
│  systemd services/timers                                │
│  - super-ops-agent.service (常時監視)                 │
│  - super-ops-agent-bootstrap.service/timer (時間実行) │
└─────────────────────────────────────────────────────────┘
```

## 主な特性

### ✅ メリット
1. **既存資産の活用**
   - 20+個のシェルスクリプトがそのまま使える
   - 動作実績のあるコード（変更最小化）

2. **低リスク**
   - Python は薄い制御層のみ
   - スクリプト障害が隔離される

3. **拡張性**
   - 新スクリプト追加 = Config に 1行追加
   - フック機構で カスタム処理挿入可能

4. **運用効率**
   - subprocess で実行 = native shell error handling
   - ログ出力がそのまま活用できる

### ⚠️ トレードオフ
- subprocess のオーバーヘッド（ただし許容範囲：起動5ms程度）
- 状態共有がファイルベース（simple だが遅い）
- リアルタイム性は限定的（ポーリングベース）

---

## 実装コンポーネント

### 1. ScriptExecutor
既存シェルスクリプトを管理・実行

```python
executor = ScriptExecutor(config)

# 単一実行
result = executor.execute('snapshot', timeout=300)

# バッチ実行
results = executor.execute_batch(['snapshot', 'audio_detect'])

# フック付き実行
executor.execute_with_hook(
    'snapshot',
    on_success=lambda r: logger.info("Success!"),
    on_error=lambda r: send_alert(r.stderr)
)
```

### 2. ExecutionLog
実行履歴を JSON で永続化

```
/var/lib/ops/execution-20260323-143022.json
{
  "name": "snapshot",
  "script": "/home/taku/projects/ops/snapshot_to_html.sh",
  "status": "success",
  "return_code": 0,
  "duration": 12.5,
  "error": null
}
```

### 3. DashboardManager
既存スクリプト出力を統合・表示

```python
dashboard_mgr = DashboardManager(config, executor)

# System snapshot 実行
dashboard_mgr.update_system_snapshot()

# OPS dashboard 生成
html = dashboard_mgr.generate_ops_dashboard(exec_log)
dashboard_mgr.save_ops_dashboard(html)
```

### 4. EventDetectorWrapper
audio_event_detector.sh をラップ

```python
detector = EventDetectorWrapper(config, executor)

# 検出実行
detector.detect_audio_events()

# 統計取得
summary = detector.get_event_summary()
# → {'total': 42, 'today': 3, 'last_event': {...}}
```

### 5. NotificationEngine
Ntfy 通知を統一

```python
notifier = NotificationEngine(config, executor)

notifier.send_notification(
    title="✅ Snapshot Complete",
    message="Updated in 12.5s",
    priority=1
)
```

### 6. SuperOpsOrchestrator（メインクラス）
全体オーケストレーション

```python
agent = SuperOpsOrchestrator(config)

# 初期化
agent.bootstrap_all()

# リアルタイム監視
agent.start_monitoring()

# カスタム実行
agent.run_snapshot()
agent.run_audio_detect()
agent.run_deploy()
```

---

## コマンド一覧

```bash
# 全初期化（ops_bootstrap_all.sh 実行）
sudo python3 super-ops-agent.py bootstrap

# リアルタイム監視開始（daemon）
sudo python3 super-ops-agent.py monitor

# 個別スクリプト実行
sudo python3 super-ops-agent.py snapshot
sudo python3 super-ops-agent.py audio
sudo python3 super-ops-agent.py dashboard
sudo python3 super-ops-agent.py deploy

# ステータス確認
sudo python3 super-ops-agent.py status

# ログ確認
sudo python3 super-ops-agent.py show-logs

# systemd 経由
sudo systemctl start super-ops-agent
sudo systemctl status super-ops-agent
sudo journalctl -u super-ops-agent -f
```

---

## インストール手順

### 1. Python依存関係（最小化）
```bash
pip install -r requirements.txt
```

**requirements.txt:**
```
# 実は不要な依存（subprocess使用）
# psutil（システムステータスはフォールバック）
```

### 2. systemd 統合
```bash
sudo cp super-ops-agent.service /etc/systemd/system/
sudo cp super-ops-agent-bootstrap.service /etc/systemd/system/
sudo cp super-ops-agent-bootstrap.timer /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable super-ops-agent
sudo systemctl enable super-ops-agent-bootstrap.timer
```

### 3. 初回起動
```bash
# 即座に bootstrap
sudo python3 /home/taku/projects/ops/super-ops-agent.py bootstrap

# 監視開始
sudo systemctl start super-ops-agent

# ステータス確認
sudo systemctl status super-ops-agent
```

---

## 実行フロー例

### Monitor モード（continuous）
```
[START] super-ops-agent.py monitor
  ├─ 30s: Snapshot check → YES → execute snapshot_to_html.sh
  ├─ 60s: Audio check → YES → execute audio_event_detector.sh
  │       └─ get_event_summary() で /audio/events/events.json 読み込み
  ├─ 300s: Dashboard update → update_dashboards()
  │        ├─ snapshot_to_html.sh 実行
  │        └─ /ops/index.html 生成
  └─ LOOP (poll every 30s)
```

### Bootstrap モード（one-shot）
```
[START] super-ops-agent.py bootstrap
  ├─ concept_snapshot_to_web.sh
  ├─ snapshot_to_html.sh
  ├─ script_inventory_classify.sh
  ├─ tag_scripts_by_role.sh
  ├─ pre_delete_snapshot.sh
  └─ dashboard update
[END] + Ntfy 通知
```

---

## ログ出力

### Agent ログ
```
/var/log/super-ops-agent.log

[2026-03-23 14:30:22] INFO    : Starting orchestration monitoring...
[2026-03-23 14:30:23] DEBUG   : Monitor cycle started
[2026-03-23 14:30:23] INFO    : Executing: sudo bash /home/taku/projects/ops/snapshot_to_html.sh
[2026-03-23 14:30:35] INFO    : Script succeeded: snapshot
[2026-03-23 14:30:35] DEBUG   : Dashboards updated
```

### systemd Journal
```bash
sudo journalctl -u super-ops-agent -f

Mar 23 14:30:22 h0 super-ops-agent[12345]: [2026-03-23 14:30:22] INFO    : Starting orchestration monitoring...
Mar 23 14:30:35 h0 super-ops-agent[12345]: [2026-03-23 14:30:35] INFO    : Script succeeded: snapshot
```

---

## トラブルシューティング

### スクリプトが見つからない
```bash
$ sudo python3 super-ops-agent.py status
ERROR: Expected script not found: /home/taku/projects/ops/audio_event_detector.sh
```
→ Ops home path を確認

### Permission denied
```bash
sudo chown root:root /home/taku/projects/ops/*.sh
sudo chmod +x /home/taku/projects/ops/*.sh
```

### Monitor が反応しない
```bash
sudo systemctl stop super-ops-agent
sudo python3 super-ops-agent.py monitor --verbose

# ↑ 詳細ログで動作確認
```

---

## 次フェーズ：案3 への移行

Monitor の遅延を削減し、リアルタイム応答性を高めたい場合：

### systemd journal 監視化
```python
# async inotify + systemd journal reader の組み込み
from systemd.journal import Reader
import asyncio

async def watch_journal():
    reader = Reader()
    while True:
        for entry in reader:
            if entry['MESSAGE'].contains('error'):
                await handle_backup_error(entry)
```

### Phase Plan
- **Week 1-3**: 案2 稳定化（エラーハンドリング強化）
- **Week 4-6**: 案3 pilot（async 基盤構築）
- **Month 3**: 案3 本格移行（削除 logging interval）

