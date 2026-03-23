# Super OPS Agent - 3つの実装案

## 案1: フル統合型（Monolithic）
**特徴**：すべての機能をPython 1ファイルで実装  
**利点**：
- 単一ファイルで完結、デプロイが簡単
- 状態管理が統一できる
- パフォーマンスが良い

**欠点**：
- ファイルサイズが大きい
- 機能追加時に依存関係が複雑化
- テストが難しい

**対象機能**：
```
1. バックアップ（rsync/dd）全処理
2. 音声イベント検出・処理 全スタック
3. Webダッシュボード 全生成・更新
4. 通知エンジン （Ntfy/Discord）
5. systemd 統合
```

**実装例**：
```python
class SuperOpsAgent:
    def bootstrap_all(self): ...    # 初期化
    def start_monitoring(self): ... # リアルタイム監視
    def run_backup_job(self): ...   # バックアップ実行
```

---

## 案2: オーケストレータ型（Orchestrator）
**特徴**：既存20+シェルスクリプトを Python が統合・制御  
**利点**：
- 既存スクリプトの資産を活用できる
- 機能ごとに責任分離
- スクリプトの独立性がある

**欠点**：
- サブプロセス呼び出しのオーバーヘッド
- スクリプト間の状態共有が複雑
- エラーハンドリングが煩雑

**対象機能**：
```
1. ops_bootstrap_all.sh を呼び出し
2. audio_event_detector.sh を定期実行
3. snapshot_to_html.sh を監視
4. notify.sh で通知中継
5. 既存スクリプトを systemd timer で制御
```

**実装例**：
```python
class OpsAgent:
    def execute_script(script: str, args: list[str]) -> Result:
        # subprocess.run でシェルスクリプト呼び出し
        return exec("sudo bash script.sh")
    
    def orchestrate_workflow(self):
        results = []
        for script in [bootstrap, audio_detect, snapshot, notify]:
            results.append(self.execute_script(script))
        return results
```

---

## 案3: イベント駆動型（Event-Driven）
**特徴**：systemd journal / inotify でイベント検出→対応処理  
**利点**：
- リアルタイムレスポンス
- リソース効率が良い（ポーリング不要）
- 非同期処理が自然

**欠点**：
- 実装が複雑（async/await 必須）
- デバッグが難しい
- イベント漏れの可能性

**対象機能**：
```
1. systemd journal 監視
   → backup エラー検出 → 通知・ダッシュボード更新
2. inotify で /var/log/backup 監視
   → 新ログ検出 → HTML 自動更新
3. /var/www/html/audio 監視
   → 新ファイル → イベント検出・追加
4. timer イベント
   → 定期 bootstrap・監視実行
```

**実装例**：
```python
import asyncio
from systemd.journal import Reader

class EventDrivenAgent:
    async def watch_journal(self):
        reader = Reader()
        while True:
            for entry in reader:
                await self.handle_event(entry)
    
    async def watch_directory(self, path: str):
        async for event in inotify_watch(path):
            await self.handle_filesystem_change(event)
    
    async def main(self):
        await asyncio.gather(
            self.watch_journal(),
            self.watch_directory('/var/log/backup'),
            self.watch_directory('/var/www/html/audio')
        )
```

---

## 比較表

| 項目 | 案1（統合型） | 案2（オーケストレータ） | 案3（イベント駆動） |
|------|-------------|-----------------|------------------|
| **ファイル数** | 1 | 1 + 既存20+ | 1 + systemd units |
| **開発時間** | 短 | 中 | 長 |
| **メモリ使用** | 高 | 低 | 低 |
| **レスポンス** | 定期（遅延） | 定期（遅延） | リアルタイム |
| **デバッグ性** | 良好 | 中 | 難 |
| **既存資産活用** | ✗ | ◎ | ◎ |
| **スケーラビリティ** | △ | ○ | ◎ |

---

## 推奨案

### 当面：**案2（オーケストレータ型）**
理由：
- 既存20+スクリプトをすぐ活用可能
- リスクが低い（既存スクリプトは動作実績あり）
- Python は制御層のみで軽量

### 将来：**案3へ段階移行**
1. Phase 1：案2で基盤構築（2-3週間）
2. Phase 2：高頻度イベント → 案3に移行（2-3ヶ月）
3. Phase 3：フル async 化（6ヶ月以降）

