#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HP-ADS-B Super OPS Agent - Orchestrator Type (案2)
Version: 2.0.0
Updated: 2026-03-23

既存20+シェルスクリプトを統合制御する「オーケストレータ型」実装

アーキテクチャ：
  Python（制御層・薄い）
    ↓
  既存シェルスクリプト20+（実装层・既実績）
    ↓
  systemd services/timers（スケジューリング）

主要フロー：
1. ops_bootstrap_all.sh      → 全初期化
2. snapshot_to_html.sh       → システムスナップショット生成
3. audio_event_detector.sh   → 音声イベント検出
4. notify.sh                 → Ntfy通知
5. custom hooks              → ダッシュボード更新
"""

import os
import sys
import json
import subprocess
import logging
import time
from pathlib import Path
from datetime import datetime, timedelta
from typing import Dict, List, Tuple, Optional, Any
from dataclasses import dataclass
from enum import Enum
import argparse
import signal
import shlex

# =====================================================================
# Configuration
# =====================================================================

class Config:
    """システム設定（既存スクリプトパス参照）"""
    
    def __init__(self):
        self.real_user = os.environ.get("SUDO_USER", os.getenv("USER", "root"))
        self.ops_home = f"/home/{self.real_user}/projects/ops"
        self.web_root = "/var/www/html"
        self.state_dir = "/var/lib/ops"
        
        # 既存スクリプトパス
        self.scripts = {
            'bootstrap': f"{self.ops_home}/ops_bootstrap_all.sh",
            'snapshot': f"{self.ops_home}/snapshot_to_html.sh",
            'audio_detect': f"{self.ops_home}/audio_event_detector.sh",
            'audio_summary': f"{self.ops_home}/concept_summary_to_web.sh",
            'notify': f"{self.ops_home}/notify.sh",
            'concept_snap': f"{self.ops_home}/concept_snapshot_to_web.sh",
            'inventory': f"{self.ops_home}/script_inventory_to_web.sh",
            'inv_classify': f"{self.ops_home}/script_inventory_classify.sh",
            'inv_tag': f"{self.ops_home}/tag_scripts_by_role.sh",
            'pre_delete': f"{self.ops_home}/pre_delete_snapshot.sh",
            'deploy_web': f"{self.ops_home}/deploy-web.sh",
        }
        
        # Log dirs
        self.backup_log_dir = "/var/log/backup"
        self.snapshot_log_dir = "/var/log/system_snapshot"
        self.agent_log_file = "/var/log/super-ops-agent.log"
        
        # Notification
        self.ntfy_url = "https://ntfy.sh"
        self.ntfy_topic = "hp-adsb-ops"
        self.hostname = os.uname()[1]
        
        # Monitoring intervals
        self.bootstrap_interval = 3600  # 1 hour
        self.snapshot_interval = 300    # 5 minutes
        self.audio_check_interval = 60  # 1 minute
        self.dashboard_update_interval = 300  # 5 minutes
        
        self._validate()
    
    def _validate(self):
        """設定値の妥当性確認"""
        if not os.path.isdir(self.ops_home):
            raise ValueError(f"OPS_HOME not found: {self.ops_home}")
        if not os.path.isdir(self.web_root):
            raise ValueError(f"WEB_ROOT not found: {self.web_root}")
        
        # 主要スクリプト確認
        required = ['bootstrap', 'snapshot', 'audio_detect', 'notify']
        for key in required:
            if key in self.scripts and not os.path.isfile(self.scripts[key]):
                logger.warning(f"Expected script not found: {self.scripts[key]}")
        
        os.makedirs(self.state_dir, exist_ok=True)


# =====================================================================
# Models
# =====================================================================

class ScriptResult:
    """スクリプト実行結果"""
    
    def __init__(self, name: str, script: str):
        self.name = name
        self.script = script
        self.status = "pending"  # pending, running, success, error, timeout
        self.return_code = None
        self.start_time = None
        self.end_time = None
        self.stdout = ""
        self.stderr = ""
        self.duration = 0.0
    
    @property
    def success(self) -> bool:
        return self.status == "success" and self.return_code == 0
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            'name': self.name,
            'script': self.script,
            'status': self.status,
            'return_code': self.return_code,
            'duration': self.duration,
            'error': self.stderr[:200] if self.stderr else None,
        }


class ExecutionLog:
    """実行ログ管理"""
    
    def __init__(self, log_dir: str):
        self.log_dir = log_dir
        self.results: List[ScriptResult] = []
        os.makedirs(log_dir, exist_ok=True)
    
    def add(self, result: ScriptResult):
        """結果追加"""
        self.results.append(result)
        self._persist(result)
    
    def _persist(self, result: ScriptResult):
        """結果を JSON で永続化"""
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        log_file = f"{self.log_dir}/execution-{timestamp}.json"
        
        try:
            with open(log_file, 'w') as f:
                json.dump(result.to_dict(), f, indent=2, ensure_ascii=False)
        except Exception as e:
            logger.error(f"Failed to persist execution log: {e}")
    
    def get_last_run_status(self, script_name: str) -> Optional[ScriptResult]:
        """最後の実行結果取得"""
        matching = [r for r in self.results if r.name == script_name and r.success]
        return matching[-1] if matching else None


# =====================================================================
# Logging
# =====================================================================

def setup_logging(log_file: str) -> logging.Logger:
    """ロギング設定"""
    logger = logging.getLogger(__name__)
    logger.setLevel(logging.DEBUG)
    
    # Console handler
    ch = logging.StreamHandler()
    ch.setLevel(logging.INFO)
    
    # File handler
    fh = logging.FileHandler(log_file)
    fh.setLevel(logging.DEBUG)
    
    # Formatter
    fmt = logging.Formatter(
        '[%(asctime)s] %(levelname)-8s: %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    ch.setFormatter(fmt)
    fh.setFormatter(fmt)
    
    logger.addHandler(ch)
    logger.addHandler(fh)
    
    return logger


logger = None  # 後で初期化


# =====================================================================
# Script Executor
# =====================================================================

class ScriptExecutor:
    """既存シェルスクリプト実行器"""
    
    def __init__(self, config: Config):
        self.config = config
        self.exec_log = ExecutionLog(config.state_dir)
    
    def execute(
        self,
        script_key: str,
        args: List[str] = None,
        timeout: int = 300,
        use_sudo: bool = True
    ) -> ScriptResult:
        """スクリプト実行"""
        
        if script_key not in self.config.scripts:
            raise ValueError(f"Unknown script key: {script_key}")
        
        script_path = self.config.scripts[script_key]
        result = ScriptResult(script_key, script_path)
        
        if not os.path.isfile(script_path):
            result.status = "error"
            result.stderr = f"Script not found: {script_path}"
            self.exec_log.add(result)
            return result
        
        # コマンド構築
        cmd = []
        if use_sudo:
            cmd.append("sudo")
        cmd.extend(["bash", script_path])
        if args:
            cmd.extend(args)
        
        result.status = "running"
        result.start_time = datetime.now()
        
        logger.info(f"Executing: {' '.join(cmd)}")
        
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout
            )
            
            result.return_code = proc.returncode
            result.stdout = proc.stdout
            result.stderr = proc.stderr
            result.status = "success" if proc.returncode == 0 else "error"
            
        except subprocess.TimeoutExpired:
            result.status = "timeout"
            result.stderr = f"Script timeout after {timeout}s"
            logger.error(f"Script timeout: {script_key}")
        
        except Exception as e:
            result.status = "error"
            result.stderr = str(e)
            logger.error(f"Script execution failed: {e}")
        
        finally:
            result.end_time = datetime.now()
            result.duration = (result.end_time - result.start_time).total_seconds()
            self.exec_log.add(result)
        
        return result
    
    def execute_batch(
        self,
        script_keys: List[str],
        sequential: bool = True,
        timeout: int = 300
    ) -> Dict[str, ScriptResult]:
        """バッチ実行"""
        
        results = {}
        
        for key in script_keys:
            logger.info(f"[Batch] Executing {key}...")
            result = self.execute(key, timeout=timeout)
            results[key] = result
            
            if not result.success and sequential:
                logger.warning(f"Batch stopped due to error in {key}")
                break
        
        return results
    
    def execute_with_hook(
        self,
        script_key: str,
        on_success: callable = None,
        on_error: callable = None
    ) -> bool:
        """フック付き実行"""
        
        result = self.execute(script_key)
        
        if result.success:
            logger.info(f"Script succeeded: {script_key}")
            if on_success:
                try:
                    on_success(result)
                except Exception as e:
                    logger.error(f"Hook execution failed: {e}")
        else:
            logger.error(f"Script failed: {script_key}")
            if on_error:
                try:
                    on_error(result)
                except Exception as e:
                    logger.error(f"Hook execution failed: {e}")
        
        return result.success


# =====================================================================
# Event Detector (Wrapper)
# =====================================================================

class EventDetectorWrapper:
    """audio_event_detector.sh ラッパー"""
    
    def __init__(self, config: Config, executor: ScriptExecutor):
        self.config = config
        self.executor = executor
    
    def detect_audio_events(self) -> bool:
        """
        音声イベント検出の実行
        実装は audio_event_detector.sh に委譲
        """
        logger.info("Running audio event detection...")
        
        result = self.executor.execute(
            'audio_detect',
            timeout=600,
            use_sudo=True
        )
        
        if result.success:
            logger.info("Audio event detection completed successfully")
            return True
        else:
            logger.error(f"Audio event detection failed: {result.stderr}")
            return False
    
    def get_event_summary(self) -> Dict[str, Any]:
        """イベント集計情報取得"""
        try:
            event_json = f"{self.config.web_root}/audio/events/events.json"
            
            if os.path.isfile(event_json):
                with open(event_json, 'r') as f:
                    events = json.load(f)
                
                # 本日のイベント集計
                today = datetime.now().strftime('%Y-%m-%d')
                today_events = [
                    e for e in events
                    if e.get('start_time', '').startswith(today)
                ]
                
                return {
                    'total': len(events),
                    'today': len(today_events),
                    'last_event': events[-1] if events else None,
                }
        
        except Exception as e:
            logger.warning(f"Failed to get event summary: {e}")
        
        return {'total': 0, 'today': 0, 'last_event': None}


# =====================================================================
# Dashboard Manager
# =====================================================================

class DashboardManager:
    """ダッシュボード管理（スナップショット統合）"""
    
    def __init__(self, config: Config, executor: ScriptExecutor):
        self.config = config
        self.executor = executor
    
    def update_system_snapshot(self) -> bool:
        """システムスナップショット更新（snapshot_to_html.sh）"""
        logger.info("Updating system snapshot...")
        
        result = self.executor.execute(
            'snapshot',
            timeout=300,
            use_sudo=True
        )
        
        return result.success
    
    def update_concept_snapshot(self) -> bool:
        """コンセプトスナップショット更新"""
        logger.info("Updating concept snapshot...")
        
        result = self.executor.execute(
            'concept_snap',
            timeout=300,
            use_sudo=True
        )
        
        return result.success
    
    def generate_ops_dashboard(self, exec_log: ExecutionLog) -> str:
        """OPS ダッシュボード HTML 生成"""
        
        # 最後の実行結果を取得
        recent_results = exec_log.results[-10:] if exec_log.results else []
        
        html_rows = "\n".join([
            f"""<tr>
              <td>{r.name}</td>
              <td>{r.end_time.strftime('%H:%M:%S') if r.end_time else '-'}</td>
              <td><span class="{'success' if r.success else 'error'}">{r.status.upper()}</span></td>
              <td>{r.duration:.1f}s</td>
            </tr>"""
            for r in sorted(recent_results, key=lambda x: x.end_time or datetime.min, reverse=True)
        ])
        
        html = f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="refresh" content="300">
<title>Super OPS Dashboard</title>
<style>
body {{
  font-family: 'Courier New', monospace;
  background: #0a0a0a;
  color: #eee;
  padding: 20px;
}}
.container {{ max-width: 1000px; margin: 0 auto; }}
h1 {{ color: #00ff88; text-shadow: 0 0 10px #00ff88; }}
table {{ width: 100%; border-collapse: collapse; margin-top: 20px; }}
th {{ background: #1a1a1a; padding: 10px; text-align: left; border-bottom: 2px solid #00ff88; }}
td {{ padding: 10px; border-bottom: 1px solid #333; }}
.success {{ color: #0f0; }}
.error {{ color: #f00; }}
tr:hover {{ background: #1a1a1a; }}
.timestamp {{ color: #999; font-size: 0.9em; }}
</style>
</head>
<body>
<div class="container">
  <h1>🚀 Super OPS Agent - Orchestrator</h1>
  <p>Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
  <p class="timestamp">Auto-refresh: 5 min</p>
  
  <h2>Recent Executions</h2>
  <table>
    <tr>
      <th>Script</th>
      <th>Time</th>
      <th>Status</th>
      <th>Duration</th>
    </tr>
    {html_rows}
  </table>
</div>
</body>
</html>"""
        
        return html
    
    def save_ops_dashboard(self, html: str) -> str:
        """OPS ダッシュボード保存"""
        path = f"{self.config.web_root}/ops/index.html"
        os.makedirs(os.path.dirname(path), exist_ok=True)
        
        try:
            with open(path, 'w') as f:
                f.write(html)
            logger.info(f"Dashboard saved: {path}")
            return path
        except Exception as e:
            logger.error(f"Failed to save dashboard: {e}")
            return ""


# =====================================================================
# Notification Engine
# =====================================================================

class NotificationEngine:
    """通知エンジン（notify.sh ラッパー）"""
    
    def __init__(self, config: Config, executor: ScriptExecutor):
        self.config = config
        self.executor = executor
    
    def send_notification(
        self,
        title: str,
        message: str,
        priority: int = 3
    ) -> bool:
        """
        Ntfy 通知送信
        実装は notify.sh に委譲
        """
        try:
            cmd = [
                "curl", "-fsS",
                "-H", f"Title: {title}",
                "-H", f"Priority: {priority}",
                "-d", message,
                f"{self.config.ntfy_url}/{self.config.ntfy_topic}"
            ]
            
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            
            if result.returncode == 0:
                logger.info(f"Notification sent: {title}")
                return True
            else:
                logger.error(f"Notification failed: {result.stderr}")
                return False
        
        except Exception as e:
            logger.error(f"Notification error: {e}")
            return False
    
    def send_execution_alert(self, script_name: str, result: ScriptResult):
        """実行結果アラート"""
        if result.success:
            self.send_notification(
                title=f"✅ {script_name} Success",
                message=f"Duration: {result.duration:.1f}s",
                priority=1
            )
        else:
            self.send_notification(
                title=f"❌ {script_name} Error",
                message=f"Status: {result.status}\nError: {result.stderr[:100]}",
                priority=5
            )


# =====================================================================
# Super OPS Orchestrator - Main
# =====================================================================

class SuperOpsOrchestrator:
    """HP-ADS-B スーパーオペレータ（案2：オーケストレータ型）"""
    
    def __init__(self, config: Config):
        self.config = config
        self.executor = ScriptExecutor(config)
        self.dashboard_mgr = DashboardManager(config, self.executor)
        self.event_detector = EventDetectorWrapper(config, self.executor)
        self.notifier = NotificationEngine(config, self.executor)
        self.running = False
        self.last_execution = {}  # 前回実行時刻の記録
    
    def bootstrap_all(self):
        """全初期化実行（ops_bootstrap_all.sh 互換）"""
        logger.info("=== OPS BOOTSTRAP START ===")
        
        startup_scripts = [
            'concept_snap',
            'snapshot',
            'inv_classify',
            'inv_tag',
            'pre_delete'
        ]
        
        try:
            results = self.executor.execute_batch(startup_scripts, sequential=True)
            
            # 結果集計
            success_count = sum(1 for r in results.values() if r.success)
            logger.info(f"Bootstrap complete: {success_count}/{len(startup_scripts)} succeeded")
            
            # ダッシュボード更新
            self._update_dashboards()
            
            # 通知
            self.notifier.send_notification(
                title="✅ OPS Bootstrap Complete",
                message=f"{success_count}/{len(startup_scripts)} scripts executed",
                priority=1
            )
            
            logger.info("=== OPS BOOTSTRAP COMPLETE ===")
            
        except Exception as e:
            logger.error(f"Bootstrap failed: {e}")
            self.notifier.send_notification(
                title="❌ OPS Bootstrap Error",
                message=str(e),
                priority=5
            )
    
    def start_monitoring(self):
        """リアルタイム監視開始"""
        logger.info("Starting orchestration monitoring...")
        self.running = True
        
        try:
            while self.running:
                try:
                    current_time = datetime.now()
                    
                    # snapshot 周期実行（5分ごと）
                    if self._should_execute('snapshot'):
                        logger.debug("Periodic snapshot execution")
                        self.executor.execute('snapshot', timeout=300)
                        self.last_execution['snapshot'] = current_time
                    
                    # audio detect 周期実行（1分ごと）
                    if self._should_execute('audio_detect'):
                        logger.debug("Periodic audio detection")
                        if self.executor.execute('audio_detect', timeout=300):
                            self.event_detector.get_event_summary()
                        self.last_execution['audio_detect'] = current_time
                    
                    # ダッシュボード更新（5分ごと）
                    if self._should_execute('dashboard'):
                        self._update_dashboards()
                        self.last_execution['dashboard'] = current_time
                    
                    time.sleep(30)  # ポーリング間隔
                
                except KeyboardInterrupt:
                    logger.info("Interrupted by user")
                    break
                except Exception as e:
                    logger.error(f"Monitor cycle failed: {e}")
                    time.sleep(5)
        
        except Exception as e:
            logger.error(f"Monitoring failed: {e}")
        finally:
            self.running = False
            logger.info("Monitoring stopped")
    
    def _should_execute(self, script_key: str) -> bool:
        """実行判定（前回実行時刻ベース）"""
        interval_map = {
            'snapshot': self.config.snapshot_interval,
            'audio_detect': self.config.audio_check_interval,
            'dashboard': self.config.dashboard_update_interval,
        }
        
        if script_key not in interval_map:
            return False
        
        last = self.last_execution.get(script_key)
        interval = interval_map[script_key]
        
        if not last:
            return True
        
        elapsed = (datetime.now() - last).total_seconds()
        return elapsed >= interval
    
    def _update_dashboards(self):
        """ダッシュボード更新"""
        try:
            # System snapshot
            self.dashboard_mgr.update_system_snapshot()
            
            # OPS dashboard
            html = self.dashboard_mgr.generate_ops_dashboard(
                self.executor.exec_log
            )
            self.dashboard_mgr.save_ops_dashboard(html)
            
            logger.debug("Dashboards updated")
        
        except Exception as e:
            logger.error(f"Dashboard update failed: {e}")
    
    def run_custom_backup(self, script_name: str = 'bootstrap'):
        """カスタム個別スクリプト実行"""
        if script_name not in self.config.scripts:
            logger.error(f"Unknown script: {script_name}")
            return False
        
        logger.info(f"Running custom: {script_name}")
        result = self.executor.execute(script_name, timeout=600)
        
        if result.success:
            self.notifier.send_execution_alert(script_name, result)
        else:
            self.notifier.send_execution_alert(script_name, result)
        
        self._update_dashboards()
        return result.success
    
    def run_bootstrap(self):
        """フルブートストラップ実行"""
        return self.run_custom_backup('bootstrap')
    
    def run_audio_detect(self):
        """音声検出実行"""
        return self.run_custom_backup('audio_detect')
    
    def run_snapshot(self):
        """スナップショット実行"""
        return self.run_custom_backup('snapshot')
    
    def run_deploy(self):
        """Web デプロイ実行"""
        return self.run_custom_backup('deploy_web')
    
    def stop(self):
        """停止"""
        logger.info("Stopping Super OPS Orchestrator...")
        self.running = False


# =====================================================================
# CLI
# =====================================================================

def main():
    """メインエントリポイント"""
    
    parser = argparse.ArgumentParser(
        description="HP-ADS-B Super OPS Agent - Orchestrator Type (案2)"
    )
    
    parser.add_argument(
        "command",
        choices=[
            "bootstrap", "monitor", "snapshot",
            "audio", "dashboard", "deploy",
            "status", "show-logs"
        ],
        help="Command to execute"
    )
    
    parser.add_argument(
        "--interval",
        type=int,
        default=60,
        help="Monitoring check interval (seconds)"
    )
    
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Verbose output"
    )
    
    args = parser.parse_args()
    
    # グローバルロギング初期化
    global logger
    os.makedirs("/var/log", exist_ok=True)
    logger = setup_logging("/var/log/super-ops-agent.log")
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    # 設定初期化
    try:
        config = Config()
    except ValueError as e:
        print(f"Configuration error: {e}", file=sys.stderr)
        sys.exit(1)
    
    # オーケストレータ初期化
    agent = SuperOpsOrchestrator(config)
    
    # シグナルハンドラ
    def signal_handler(sig, frame):
        logger.info("Received signal, shutting down...")
        agent.stop()
        sys.exit(0)
    
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    
    # コマンド実行
    try:
        if args.command == "bootstrap":
            agent.bootstrap_all()
        
        elif args.command == "monitor":
            config.check_interval = args.interval
            agent.start_monitoring()
        
        elif args.command == "snapshot":
            agent.run_snapshot()
        
        elif args.command == "audio":
            agent.run_audio_detect()
        
        elif args.command == "dashboard":
            agent._update_dashboards()
        
        elif args.command == "deploy":
            agent.run_deploy()
        
        elif args.command == "status":
            print_status(agent, config)
        
        elif args.command == "show-logs":
            show_logs(config)
    
    except Exception as e:
        logger.error(f"Execution failed: {e}", exc_info=True)
        sys.exit(1)


def print_status(agent: SuperOpsOrchestrator, config: Config):
    """ステータス表示"""
    print("\n=== Super OPS Orchestrator Status ===")
    print(f"Host: {config.hostname}")
    print(f"OPS Home: {config.ops_home}")
    print(f"Web Root: {config.web_root}")
    print()
    
    # 最後の各スクリプト実行結果
    if agent.executor.exec_log.results:
        print("Recent Executions:")
        for result in agent.executor.exec_log.results[-5:]:
            status_icon = "✅" if result.success else "❌"
            print(f"  {status_icon} {result.name} ({result.status}) - {result.duration:.1f}s")
    else:
        print("No execution history")
    
    print()


def show_logs(config: Config):
    """ログ表示"""
    log_file = config.agent_log_file
    
    if os.path.isfile(log_file):
        print(f"\n=== Last 30 lines from {log_file} ===\n")
        try:
            with open(log_file, 'r') as f:
                lines = f.readlines()
                for line in lines[-30:]:
                    print(line.rstrip())
        except Exception as e:
            print(f"Error reading logs: {e}")
    else:
        print(f"Log file not found: {log_file}")


if __name__ == "__main__":
    main()
