#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================
# File    : /home/taku/projects/ops/super-ops-agent.py
# Version : 3.0.1-A+++
# Updated : 2026-03-24
#
# Purpose :
#   HP-ADS-B / hp-adsb 用 Super OPS Agent 完成版
#
# Features :
#   - 既存 shell / python スクリプト群の統合制御
#   - monitor 常駐ループ
#   - bootstrap 一括実行
#   - JSON 状態保存
#   - 実行ログ保存
#   - flock による多重起動防止
#   - signal による安全停止
#   - 失敗時の簡易 backoff
#
# Important Fix :
#   - systemd(User=root) 実行時でも /home/taku/projects/ops を使う
#   - USER=root を拾って /home/root/projects/ops にならないよう修正
#   - OPS_HOME / WEB_ROOT / STATE_DIR は環境変数で上書き可能
# ============================================================

import argparse
import fcntl
import json
import logging
import os
import shlex
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


# ============================================================
# Utility
# ============================================================

def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ensure_dir(path: str) -> None:
    Path(path).mkdir(parents=True, exist_ok=True)


def read_json(path: str, default: Any) -> Any:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def write_json(path: str, data: Any) -> None:
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


# ============================================================
# Config
# ============================================================

class Config:
    """
    システム設定
    """

    def __init__(self) -> None:
        # ----------------------------------------------------
        # 重要:
        # systemd で User=root 実行すると USER=root になる。
        # それを使って /home/root/projects/ops を作らない。
        #
        # 優先順位:
        #   1) OPS_HOME 環境変数
        #   2) /home/taku/projects/ops（既定）
        # ----------------------------------------------------
        self.default_real_user = "taku"
        self.real_user = os.environ.get("OPS_REAL_USER", self.default_real_user)

        self.ops_home = os.environ.get(
            "OPS_HOME",
            f"/home/{self.default_real_user}/projects/ops",
        )
        self.web_root = os.environ.get("WEB_ROOT", "/var/www/html")
        self.state_dir = os.environ.get("STATE_DIR", "/var/lib/ops")
        self.run_dir = "/run"
        self.log_dir = "/var/log"

        self.state_file = f"{self.state_dir}/super-ops-agent-state.json"
        self.exec_log_dir = f"{self.state_dir}/execution_logs"
        self.lock_file = f"{self.run_dir}/super-ops-agent.lock"
        self.agent_log_file = f"{self.log_dir}/super-ops-agent.log"

        # 既存スクリプト群
        self.scripts: Dict[str, str] = {
            "bootstrap": f"{self.ops_home}/ops_bootstrap_all.sh",
            "snapshot": f"{self.ops_home}/snapshot_to_html.sh",
            "audio_detect": f"{self.ops_home}/audio_event_detector.sh",
            "audio_summary": f"{self.ops_home}/concept_summary_to_web.sh",
            "concept_snap": f"{self.ops_home}/concept_snapshot_to_web.sh",
            "inventory": f"{self.ops_home}/script_inventory_to_web.sh",
            "inv_classify": f"{self.ops_home}/script_inventory_classify.sh",
            "inv_tag": f"{self.ops_home}/tag_scripts_by_role.sh",
            "pre_delete": f"{self.ops_home}/pre_delete_snapshot.sh",
            "deploy_web": f"{self.ops_home}/deploy-web.sh",
            "notify": f"{self.ops_home}/notify.sh",
            "ops_status": f"{self.ops_home}/ops-status.sh",
            "ops_health_notify": f"{self.ops_home}/ops_health_notify.sh",
            "inventory_diff": f"{self.ops_home}/inventory_diff_watch.sh",
        }

        # monitor 時の定期タスク
        self.tasks: List[Dict[str, Any]] = [
            {
                "name": "audio_detect",
                "interval_sec": 60,
                "timeout_sec": 180,
                "enabled": True,
                "run_on_start": True,
            },
            {
                "name": "snapshot",
                "interval_sec": 300,
                "timeout_sec": 300,
                "enabled": True,
                "run_on_start": True,
            },
            {
                "name": "audio_summary",
                "interval_sec": 300,
                "timeout_sec": 300,
                "enabled": True,
                "run_on_start": False,
            },
            {
                "name": "concept_snap",
                "interval_sec": 900,
                "timeout_sec": 300,
                "enabled": True,
                "run_on_start": False,
            },
            {
                "name": "ops_status",
                "interval_sec": 300,
                "timeout_sec": 180,
                "enabled": True,
                "run_on_start": False,
            },
            {
                "name": "inventory",
                "interval_sec": 3600,
                "timeout_sec": 600,
                "enabled": True,
                "run_on_start": False,
            },
            {
                "name": "inv_classify",
                "interval_sec": 3600,
                "timeout_sec": 600,
                "enabled": True,
                "run_on_start": False,
            },
            {
                "name": "inv_tag",
                "interval_sec": 3600,
                "timeout_sec": 600,
                "enabled": True,
                "run_on_start": False,
            },
            {
                "name": "deploy_web",
                "interval_sec": 600,
                "timeout_sec": 300,
                "enabled": True,
                "run_on_start": False,
            },
            {
                "name": "inventory_diff",
                "interval_sec": 1800,
                "timeout_sec": 300,
                "enabled": True,
                "run_on_start": False,
            },
        ]

        self.loop_sleep_sec = 5
        self.failure_backoff_sec = 120

        self._validate()

    def _validate(self) -> None:
        if not os.path.isdir(self.ops_home):
            raise RuntimeError(f"OPS_HOME not found: {self.ops_home}")

        if not os.path.isdir(self.web_root):
            raise RuntimeError(f"WEB_ROOT not found: {self.web_root}")

        ensure_dir(self.state_dir)
        ensure_dir(self.exec_log_dir)

        missing_required = []
        for key in ("bootstrap", "snapshot", "audio_detect", "deploy_web"):
            path = self.scripts.get(key)
            if not path or not os.path.isfile(path):
                missing_required.append(path)

        if missing_required:
            raise RuntimeError(
                "Required scripts missing:\n" + "\n".join(str(x) for x in missing_required)
            )


# ============================================================
# Logging
# ============================================================

def setup_logger(log_file: str) -> logging.Logger:
    logger = logging.getLogger("super_ops_agent")
    logger.setLevel(logging.DEBUG)

    if logger.handlers:
        return logger

    fmt = logging.Formatter(
        "[%(asctime)s] %(levelname)-8s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)
    ch.setFormatter(fmt)

    fh = logging.FileHandler(log_file, encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(fmt)

    logger.addHandler(ch)
    logger.addHandler(fh)
    return logger


# ============================================================
# Models
# ============================================================

@dataclass
class ScriptResult:
    name: str
    script: str
    status: str = "pending"
    return_code: Optional[int] = None
    start_time: Optional[str] = None
    end_time: Optional[str] = None
    duration_sec: float = 0.0
    stdout: str = ""
    stderr: str = ""

    @property
    def success(self) -> bool:
        return self.status == "success" and self.return_code == 0

    def short_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "script": self.script,
            "status": self.status,
            "return_code": self.return_code,
            "start_time": self.start_time,
            "end_time": self.end_time,
            "duration_sec": self.duration_sec,
            "stdout_head": self.stdout[:400],
            "stderr_head": self.stderr[:400],
        }


# ============================================================
# State Manager
# ============================================================

class StateManager:
    def __init__(self, state_file: str) -> None:
        self.state_file = state_file
        self.state = self._load()

    def _default(self) -> Dict[str, Any]:
        return {
            "agent": {
                "last_start_utc": None,
                "last_stop_utc": None,
                "last_heartbeat_utc": None,
                "pid": None,
                "mode": None,
            },
            "tasks": {},
        }

    def _load(self) -> Dict[str, Any]:
        data = read_json(self.state_file, self._default())
        if "agent" not in data:
            data["agent"] = self._default()["agent"]
        if "tasks" not in data:
            data["tasks"] = {}
        return data

    def save(self) -> None:
        write_json(self.state_file, self.state)

    def update_agent(self, **kwargs: Any) -> None:
        self.state["agent"].update(kwargs)
        self.save()

    def update_task(self, name: str, result: ScriptResult) -> None:
        task_state = self.state["tasks"].setdefault(name, {})
        task_state.update(
            {
                "last_status": result.status,
                "last_return_code": result.return_code,
                "last_start_utc": result.start_time,
                "last_end_utc": result.end_time,
                "last_duration_sec": result.duration_sec,
                "last_success_utc": result.end_time if result.success else task_state.get("last_success_utc"),
                "last_failure_utc": result.end_time if not result.success else task_state.get("last_failure_utc"),
                "stderr_head": result.stderr[:400],
                "stdout_head": result.stdout[:400],
            }
        )
        self.save()

    def task_last_success(self, name: str) -> Optional[float]:
        task = self.state["tasks"].get(name, {})
        ts = task.get("last_success_utc")
        if not ts:
            return None
        try:
            return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
        except Exception:
            return None

    def task_last_end(self, name: str) -> Optional[float]:
        task = self.state["tasks"].get(name, {})
        ts = task.get("last_end_utc")
        if not ts:
            return None
        try:
            return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
        except Exception:
            return None


# ============================================================
# Lock
# ============================================================

class SingleInstanceLock:
    def __init__(self, lock_file: str) -> None:
        self.lock_file = lock_file
        self.fp = None

    def acquire(self) -> None:
        self.fp = open(self.lock_file, "w", encoding="utf-8")
        try:
            fcntl.flock(self.fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as e:
            raise RuntimeError(f"Another instance is already running: {self.lock_file}") from e

        self.fp.write(str(os.getpid()))
        self.fp.flush()

    def release(self) -> None:
        if self.fp:
            try:
                fcntl.flock(self.fp.fileno(), fcntl.LOCK_UN)
            except Exception:
                pass
            try:
                self.fp.close()
            except Exception:
                pass
            self.fp = None


# ============================================================
# Script Executor
# ============================================================

class ScriptExecutor:
    def __init__(self, config: Config, logger: logging.Logger, state: StateManager) -> None:
        self.config = config
        self.logger = logger
        self.state = state

    def _build_cmd(self, script_path: str, args: Optional[List[str]]) -> List[str]:
        args = args or []

        if script_path.endswith(".py"):
            return ["/usr/bin/python3", script_path] + args

        if script_path.endswith(".sh"):
            return ["/bin/bash", script_path] + args

        return [script_path] + args

    def _persist_exec_result(self, result: ScriptResult) -> None:
        ensure_dir(self.config.exec_log_dir)
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        path = f"{self.config.exec_log_dir}/{ts}-{result.name}.json"
        write_json(path, result.short_dict())

    def execute(self, script_key: str, args: Optional[List[str]] = None, timeout: int = 300) -> ScriptResult:
        if script_key not in self.config.scripts:
            raise ValueError(f"Unknown script key: {script_key}")

        script_path = self.config.scripts[script_key]
        result = ScriptResult(name=script_key, script=script_path)
        result.start_time = utc_now_iso()

        if not os.path.isfile(script_path):
            result.status = "error"
            result.return_code = 127
            result.stderr = f"Script not found: {script_path}"
            result.end_time = utc_now_iso()
            self.logger.error(result.stderr)
            self.state.update_task(script_key, result)
            self._persist_exec_result(result)
            return result

        cmd = self._build_cmd(script_path, args)
        self.logger.info("RUN  %-16s -> %s", script_key, " ".join(shlex.quote(x) for x in cmd))

        started = time.time()
        try:
            cp = subprocess.run(
                cmd,
                cwd=self.config.ops_home,
                capture_output=True,
                text=True,
                timeout=timeout,
                env=os.environ.copy(),
            )
            result.return_code = cp.returncode
            result.stdout = cp.stdout.strip()
            result.stderr = cp.stderr.strip()
            result.duration_sec = round(time.time() - started, 3)
            result.end_time = utc_now_iso()

            if cp.returncode == 0:
                result.status = "success"
                self.logger.info("OK   %-16s rc=%s dur=%.3fs", script_key, cp.returncode, result.duration_sec)
            else:
                result.status = "error"
                self.logger.error("FAIL %-16s rc=%s dur=%.3fs", script_key, cp.returncode, result.duration_sec)

        except subprocess.TimeoutExpired as e:
            result.status = "timeout"
            result.return_code = 124
            result.stdout = (e.stdout or "").strip() if isinstance(e.stdout, str) else ""
            result.stderr = (e.stderr or "").strip() if isinstance(e.stderr, str) else ""
            result.duration_sec = round(time.time() - started, 3)
            result.end_time = utc_now_iso()
            self.logger.error("TIME %-16s timeout=%ss", script_key, timeout)

        except Exception as e:
            result.status = "error"
            result.return_code = 1
            result.stderr = str(e)
            result.duration_sec = round(time.time() - started, 3)
            result.end_time = utc_now_iso()
            self.logger.exception("EXC  %-16s %s", script_key, e)

        self.state.update_task(script_key, result)
        self._persist_exec_result(result)
        return result


# ============================================================
# Agent
# ============================================================

class SuperOpsAgent:
    def __init__(self, config: Config, logger: logging.Logger) -> None:
        self.config = config
        self.logger = logger
        self.state = StateManager(config.state_file)
        self.executor = ScriptExecutor(config, logger, self.state)
        self.lock = SingleInstanceLock(config.lock_file)
        self.stop_requested = False

    def install_signal_handlers(self) -> None:
        signal.signal(signal.SIGTERM, self._handle_signal)
        signal.signal(signal.SIGINT, self._handle_signal)

    def _handle_signal(self, signum: int, frame: Any) -> None:
        self.logger.warning("Signal received: %s -> graceful stop requested", signum)
        self.stop_requested = True

    def start(self, mode: str) -> None:
        self.lock.acquire()
        self.state.update_agent(
            last_start_utc=utc_now_iso(),
            last_heartbeat_utc=utc_now_iso(),
            pid=os.getpid(),
            mode=mode,
        )

    def stop(self) -> None:
        self.state.update_agent(
            last_stop_utc=utc_now_iso(),
            last_heartbeat_utc=utc_now_iso(),
            pid=None,
        )
        self.lock.release()

    def _notify_failure(self, title: str, body: str) -> None:
        notify_script = self.config.scripts.get("notify")
        if not notify_script or not os.path.isfile(notify_script):
            return

        try:
            subprocess.run(
                ["/bin/bash", notify_script, title, body],
                cwd=self.config.ops_home,
                capture_output=True,
                text=True,
                timeout=30,
            )
        except Exception as e:
            self.logger.warning("notify skipped: %s", e)

    def _run_task(self, task_name: str, timeout_sec: int) -> ScriptResult:
        result = self.executor.execute(task_name, timeout=timeout_sec)

        if not result.success:
            body = f"{task_name} failed on {self.config.ops_home}\nstatus={result.status}\nrc={result.return_code}"
            self._notify_failure(f"[hp-adsb] {task_name} failed", body)

        return result

    def _run_sequence(self, items: List[Dict[str, Any]]) -> bool:
        ok = True
        for item in items:
            name = item["name"]
            timeout_sec = item.get("timeout_sec", 300)

            if self.stop_requested:
                self.logger.warning("Stop requested -> sequence interrupted")
                return False

            result = self._run_task(name, timeout_sec)
            if not result.success:
                ok = False
        return ok

    def _task_due(self, task: Dict[str, Any], startup_phase: bool) -> bool:
        if not task.get("enabled", True):
            return False

        name = task["name"]
        interval_sec = int(task["interval_sec"])

        if startup_phase and task.get("run_on_start", False):
            last_end = self.state.task_last_end(name)
            if last_end is None:
                return True

        last_success = self.state.task_last_success(name)
        if last_success is None:
            return True

        return (time.time() - last_success) >= interval_sec

    def cmd_bootstrap(self) -> int:
        self.logger.info("Bootstrap started")

        sequence = [
            {"name": "bootstrap", "timeout_sec": 600},
            {"name": "snapshot", "timeout_sec": 300},
            {"name": "audio_summary", "timeout_sec": 300},
            {"name": "concept_snap", "timeout_sec": 300},
            {"name": "inventory", "timeout_sec": 600},
            {"name": "inv_classify", "timeout_sec": 600},
            {"name": "inv_tag", "timeout_sec": 600},
            {"name": "ops_status", "timeout_sec": 180},
            {"name": "deploy_web", "timeout_sec": 300},
        ]

        ok = self._run_sequence(sequence)
        self.logger.info("Bootstrap finished ok=%s", ok)
        return 0 if ok else 1

    def cmd_once(self) -> int:
        self.logger.info("Run once started")

        due_tasks = []
        for task in self.config.tasks:
            if self._task_due(task, startup_phase=True):
                due_tasks.append(task)

        if not due_tasks:
            self.logger.info("No due tasks")
            return 0

        ok = self._run_sequence(due_tasks)
        self.logger.info("Run once finished ok=%s", ok)
        return 0 if ok else 1

    def cmd_status(self) -> int:
        data = self.state.state
        print(json.dumps(data, indent=2, ensure_ascii=False))
        return 0

    def cmd_monitor(self) -> int:
        self.logger.info("Monitor loop started")
        startup_phase = True

        while not self.stop_requested:
            self.state.update_agent(
                last_heartbeat_utc=utc_now_iso(),
                pid=os.getpid(),
                mode="monitor",
            )

            ran_something = False

            for task in self.config.tasks:
                if self.stop_requested:
                    break

                if self._task_due(task, startup_phase=startup_phase):
                    ran_something = True
                    result = self._run_task(task["name"], int(task["timeout_sec"]))

                    if not result.success:
                        self.logger.warning(
                            "Task failed -> backoff %ss : %s",
                            self.config.failure_backoff_sec,
                            task["name"],
                        )
                        for _ in range(self.config.failure_backoff_sec):
                            if self.stop_requested:
                                break
                            time.sleep(1)

            startup_phase = False

            if not ran_something:
                time.sleep(self.config.loop_sleep_sec)

        self.logger.info("Monitor loop stopped")
        return 0


# ============================================================
# Main
# ============================================================

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="HP-ADS-B Super OPS Agent")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("monitor", help="常駐監視ループ")
    sub.add_parser("bootstrap", help="一括初期化")
    sub.add_parser("once", help="今 due なタスクを1回だけ実行")
    sub.add_parser("status", help="現在の state.json を表示")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    config = Config()
    logger = setup_logger(config.agent_log_file)
    agent = SuperOpsAgent(config, logger)
    agent.install_signal_handlers()

    try:
        agent.start(args.command)

        if args.command == "monitor":
            return agent.cmd_monitor()

        if args.command == "bootstrap":
            return agent.cmd_bootstrap()

        if args.command == "once":
            return agent.cmd_once()

        if args.command == "status":
            return agent.cmd_status()

        parser.print_help()
        return 1

    except RuntimeError as e:
        try:
            logger = logging.getLogger("super_ops_agent_bootstrap_fallback")
            if not logger.handlers:
                logging.basicConfig(level=logging.INFO)
            logger.error("%s", e)
        except Exception:
            pass
        return 1
    except Exception as e:
        try:
            logger = logging.getLogger("super_ops_agent_bootstrap_fallback")
            if not logger.handlers:
                logging.basicConfig(level=logging.INFO)
            logger.exception("Fatal error: %s", e)
        except Exception:
            pass
        return 1
    finally:
        try:
            agent.stop()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())
