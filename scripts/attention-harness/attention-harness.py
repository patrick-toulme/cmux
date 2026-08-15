#!/usr/bin/env python3
"""
End-to-end attention pipeline harness.

Drives the REAL stack with zero mocks inside the app: a real tagged cmux
instance, a real tmux server standing in for a corp machine (fake ssh runs
"remote" commands locally), and the REAL opencode feed plugin running in a
real mirrored pane, replaying captured opencode bus event shapes. Asserts
every attention transition through the `debug.attention_state` verb:

  working dot -> unseen-done -> visit clears
  pending approval -> out-of-band conclude
  awaiting input (question) -> reply concludes
  app gone mid-turn -> recovery timer repaints running
  turn completes while app is gone -> done state delivered after recovery

Usage:
  python3 scripts/attention-harness/attention-harness.py --tag attn-e2e

Requires the tagged app built at /tmp/cmux-<tag> (scripts/reload.sh --tag
<tag>). The harness launches its own app instance with the fake-ssh
override, so the user's main app and other tagged instances are untouched.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
HARNESS_DIR = Path(__file__).resolve().parent
FAKE_HOST = "attnfake"
TMUX_SOCKET_NAME = "cmux-attn-harness"
SESSION_NAME = "harness"

PASSES: list[str] = []
FAILURES: list[str] = []


def log(message: str) -> None:
    print(f"[harness] {message}", flush=True)


def record(name: str, ok: bool, detail: str = "") -> None:
    line = f"{name}{': ' + detail if detail else ''}"
    (PASSES if ok else FAILURES).append(line)
    log(("PASS  " if ok else "FAIL  ") + line)


class Harness:
    def __init__(
        self,
        tag: str,
        keep_app: bool,
        setup_only: bool = False,
        only: list[str] | None = None,
    ) -> None:
        self.tag = tag
        self.keep_app = keep_app
        self.setup_only = setup_only
        self.only = only or []
        self.derived = (
            Path.home() / f"Library/Developer/Xcode/DerivedData/cmux-{tag}"
        )
        self.socket = Path(f"/tmp/cmux-debug-{tag}.sock")
        self.work = Path(f"/tmp/attn-harness-{tag}")
        self.fifo = self.work / "events.fifo"
        self.tmux_env = os.environ.copy()
        self.app_process: subprocess.Popen | None = None
        self.session_counter = 0
        self.agent_link_path: str = ""
        self.link_keeper: threading.Thread | None = None

    # ---------- infrastructure ----------

    def app_binary(self) -> Path:
        products = self.derived / "Build/Products/Debug"
        # The TAGGED bundle only ("cmux DEV <tag>.app"): an untagged bundle
        # shares the default debug socket and must never be launched here.
        for app in sorted(products.glob(f"*{self.tag}*.app")):
            plist = app / "Contents/Info.plist"
            executable = subprocess.run(
                ["plutil", "-extract", "CFBundleExecutable", "raw", str(plist)],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
            candidate = app / "Contents/MacOS" / executable
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return candidate
        raise SystemExit(
            f"no tagged app under {products}; run scripts/reload.sh --tag {self.tag} first"
        )

    def tmux(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["tmux", "-L", TMUX_SOCKET_NAME, *args],
            capture_output=True,
            text=True,
            check=check,
        )

    def cli(self, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["CMUX_TAG"] = self.tag
        env["CMUX_QUIET"] = "1"
        env["CMUX_REMOTE_TMUX_SSH_FOR_TESTING"] = str(HARNESS_DIR / "fake-ssh.sh")
        return subprocess.run(
            [str(REPO / "scripts/cmux-debug-cli.sh"), *args],
            capture_output=True,
            text=True,
            check=check,
            env=env,
        )

    def rpc(self, method: str, params: dict | None = None) -> dict:
        args = ["rpc", method]
        if params is not None:
            args.append(json.dumps(params))
        result = self.cli(*args)
        text = result.stdout.strip()
        start = text.find("{")
        if start < 0:
            raise RuntimeError(f"rpc {method}: no JSON in output: {text!r}")
        return json.loads(text[start:])

    def launch_app(self) -> None:
        binary = self.app_binary()
        # Seed the fresh instance's defaults: accept the driver's CLI
        # connections (default is cmux-only peer verification) and enable
        # the remote tmux beta. Argument-domain overrides don't work here:
        # the settings client decodes raw defaults objects, and argv
        # overrides arrive as strings.
        bundle_plist = binary.parent.parent / "Info.plist"
        bundle_id = subprocess.run(
            ["plutil", "-extract", "CFBundleIdentifier", "raw", str(bundle_plist)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        subprocess.run(
            ["defaults", "write", bundle_id, "socketControlMode", "allowall"],
            check=True,
        )
        subprocess.run(
            ["defaults", "write", bundle_id, "remoteTmux.beta.enabled",
             "-bool", "true"],
            check=True,
        )
        env = os.environ.copy()
        env["CMUX_REMOTE_TMUX_SSH_FOR_TESTING"] = str(HARNESS_DIR / "fake-ssh.sh")
        log(f"launching {binary.name} (tag {self.tag}, bundle {bundle_id})")
        self.app_process = subprocess.Popen(
            [str(binary)],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.time() + 120
        while time.time() < deadline:
            if self.app_process.poll() is not None:
                raise SystemExit(
                    f"tagged app exited during launch (status {self.app_process.returncode})"
                )
            try:
                self.cli("list-workspaces")
                log("app socket ready")
                return
            except subprocess.CalledProcessError:
                pass
            time.sleep(1)
        raise SystemExit("tagged app socket never came up (120s)")

    def kill_app(self) -> None:
        if self.app_process is not None:
            self.app_process.terminate()
            try:
                self.app_process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.app_process.kill()
            self.app_process = None
        time.sleep(1)

    def setup_fake_host(self) -> None:
        self.work.mkdir(parents=True, exist_ok=True)
        if self.fifo.exists():
            self.fifo.unlink()
        os.mkfifo(self.fifo)
        self.tmux("kill-server", check=False)
        env = os.environ.copy()
        env["ATTN_PLUGIN_PATH"] = str(REPO / "Resources/opencode-plugin.js")
        env["ATTN_EVENTS_FIFO"] = str(self.fifo)
        env["CMUX_FEED_DEBUG"] = "1"
        env["CMUX_FEED_RECONNECT_INTERVAL_MS"] = "1000"
        puppet = (
            f"exec {shutil.which('bun')} {HARNESS_DIR / 'puppet-agent.mjs'} "
            f"> {self.work}/puppet.log 2>&1"
        )
        subprocess.run(
            [
                "tmux", "-L", TMUX_SOCKET_NAME,
                "new-session", "-d", "-s", SESSION_NAME, "-n", "agent", puppet,
            ],
            env=env,
            check=True,
        )
        log("fake host tmux server + puppet pane up")

    def attach_fake_host(self) -> None:
        # The CLI drives the whole attach pipeline (probe, master, mirror)
        # through the fake ssh, which executes everything locally against
        # the harness tmux server.
        env = os.environ.copy()
        env["CMUX_TAG"] = self.tag
        env["CMUX_REMOTE_TMUX_SSH_FOR_TESTING"] = str(HARNESS_DIR / "fake-ssh.sh")
        env["CMUX_FAKE_TMUX_SOCKET"] = TMUX_SOCKET_NAME
        result = subprocess.run(
            [str(REPO / "scripts/cmux-debug-cli.sh"), "ssh-tmux", FAKE_HOST],
            capture_output=True,
            text=True,
            env=env,
            timeout=120,
        )
        if result.returncode != 0:
            raise SystemExit(
                f"ssh-tmux attach failed:\n{result.stdout}\n{result.stderr}"
            )
        log("fake host attached")

    def link_agent_socket(self) -> None:
        # The bridge pins CMUX_SOCKET_PATH into the fake host's tmux tables
        # asynchronously after the attach returns; poll for it. Locally
        # there is no reverse forward, so symlink the pinned path to the
        # app's real control socket.
        remote_path = ""
        deadline = time.time() + 30
        while time.time() < deadline and not remote_path:
            result = self.tmux(
                "show-environment", "-g", "CMUX_SOCKET_PATH", check=False
            )
            out = result.stdout.strip()
            if result.returncode == 0 and "=" in out:
                remote_path = out.split("=", 1)[1]
                break
            time.sleep(1)
        if not remote_path:
            raise SystemExit("CMUX_SOCKET_PATH never pinned by the agent bridge")
        self.agent_link_path = remote_path
        self.relink_agent_socket()
        log(f"agent socket linked: {remote_path} -> {self.socket}")
        if self.link_keeper is None:
            # The bridge re-runs `rm -f <remote socket>` on every (re)attach
            # pass before requesting the forward, deleting the harness's
            # stand-in symlink. Keep re-creating it for the run's lifetime.
            self.link_keeper = threading.Thread(
                target=self.keep_agent_link, daemon=True
            )
            self.link_keeper.start()

    def relink_agent_socket(self) -> None:
        path = self.agent_link_path
        if not path:
            return
        try:
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            if not (os.path.islink(path) and os.readlink(path) == str(self.socket)):
                if os.path.lexists(path):
                    os.unlink(path)
                os.symlink(self.socket, path)
        except OSError:
            pass

    def keep_agent_link(self) -> None:
        while True:
            self.relink_agent_socket()
            time.sleep(0.3)

    # ---------- event plumbing ----------

    def send_events(self, events: list[dict]) -> None:
        payload = "".join(json.dumps(event) + "\n" for event in events)
        fd = os.open(self.fifo, os.O_WRONLY)
        try:
            os.write(fd, payload.encode())
        finally:
            os.close(fd)

    def new_session_id(self) -> str:
        self.session_counter += 1
        return f"ses_harness{self.session_counter}"

    # Captured shapes (live opencode bus traces, message-v2 vocabulary).
    def user_prompt(self, sid: str, text: str, message_id: str) -> list[dict]:
        return [
            {"type": "message.updated", "properties": {
                "info": {"id": message_id, "sessionID": sid, "role": "user"},
            }},
            {"type": "message.part.updated", "properties": {
                "part": {"type": "text", "messageID": message_id,
                         "sessionID": sid, "text": text},
            }},
            {"type": "session.status", "properties": {
                "sessionID": sid, "status": {"type": "busy"},
            }},
        ]

    def turn_end(self, sid: str) -> list[dict]:
        return [
            {"type": "session.status", "properties": {
                "sessionID": sid, "status": {"type": "idle"},
            }},
            {"type": "session.idle", "properties": {"sessionID": sid}},
        ]

    def permission_asked(self, sid: str, request_id: str) -> list[dict]:
        return [{"type": "permission.asked", "properties": {
            "id": request_id, "sessionID": sid, "permission": "bash",
            "patterns": ["rm -rf /tmp/x"], "always": [], "metadata": {},
        }}]

    def question_asked(self, sid: str, request_id: str) -> list[dict]:
        return [{"type": "question.asked", "properties": {
            "id": request_id, "sessionID": sid,
            "questions": [{"question": "Proceed with the plan?",
                           "options": [{"label": "Yes"}, {"label": "No"}]}],
        }}]

    def replied(self, event_type: str, sid: str, request_id: str) -> list[dict]:
        return [{"type": event_type, "properties": {
            "sessionID": sid, "requestID": request_id,
        }}]

    # ---------- state polling ----------

    def set_focus_override(self, focused: bool | None) -> None:
        """Pin the app's focus state (DEBUG verb).

        Visit-driven unread clearing requires an ACTIVE app; the harness app
        must never steal real focus, so the visit scenario pins focus around
        its select-and-clear assert instead.
        """
        params = {} if focused is None else {"focused": focused}
        self.rpc("debug.set_app_focus_override", params)

    def mirror_workspace(self) -> dict | None:
        state = self.rpc("debug.attention_state")
        for workspace in state.get("result", state).get("workspaces", []):
            if workspace.get("host_key"):
                return workspace
        return None

    def wait_for(self, label: str, predicate, timeout: float = 15.0) -> bool:
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            try:
                last = self.mirror_workspace()
                if last is not None and predicate(last):
                    record(label, True)
                    return True
            except Exception as error:  # noqa: BLE001 - report at timeout
                last = {"error": str(error)}
            time.sleep(0.5)
        record(label, False, f"last state: {json.dumps(last)[:300]}")
        return False

    # ---------- scenarios ----------

    def scenario_working_and_done(self) -> None:
        sid = self.new_session_id()
        self.send_events(self.user_prompt(sid, "build the thing", "msg_h1"))
        self.wait_for("working dot after prompt",
                      lambda w: w["phase"] == "working")
        # Select a LOCAL workspace so the mirror is unfocused when the turn
        # completes (mirrors the real "switched away" flow).
        self.cli("select-workspace", "--workspace", "workspace:1", check=False)
        time.sleep(1)
        self.send_events(self.turn_end(sid))
        self.wait_for("unseen-done after turn end",
                      lambda w: w["unread_turn_complete"] is True)
        mirror = self.mirror_workspace() or {}
        workspace_id = mirror.get("workspace_id", "")
        # A visit only clears unread while the app is ACTIVE (selecting a
        # workspace in a backgrounded cmux deliberately keeps the dot). Pin
        # focus for the visit instead of stealing the user's real focus.
        self.set_focus_override(True)
        try:
            self.cli("select-workspace", "--workspace", workspace_id, check=False)
            time.sleep(1.5)
            self.wait_for("visit clears unseen-done",
                          lambda w: w["unread_turn_complete"] is False, timeout=10)
        finally:
            self.set_focus_override(None)

    def scenario_permission(self) -> None:
        sid = self.new_session_id()
        request_id = f"perm-{sid}"
        self.send_events(self.user_prompt(sid, "dangerous step", "msg_h2"))
        self.send_events(self.permission_asked(sid, request_id))
        self.wait_for("pending approval phase",
                      lambda w: w["phase"] == "pendingApproval")
        self.send_events(self.replied("permission.replied", sid, request_id))
        self.wait_for("approval concludes out-of-band",
                      lambda w: w["phase"] in ("working", "none"))
        self.send_events(self.turn_end(sid))
        time.sleep(1)

    def scenario_question(self) -> None:
        sid = self.new_session_id()
        request_id = f"q-{sid}"
        self.send_events(self.user_prompt(sid, "ask me something", "msg_h3"))
        self.send_events(self.question_asked(sid, request_id))
        self.wait_for("awaiting input phase",
                      lambda w: w["phase"] == "awaitingInput")
        self.send_events(self.replied("question.replied", sid, request_id))
        self.wait_for("question concludes out-of-band",
                      lambda w: w["phase"] in ("working", "none"))
        self.send_events(self.turn_end(sid))
        time.sleep(1)

    def scenario_restart_mid_turn(self) -> None:
        sid = self.new_session_id()
        self.send_events(self.user_prompt(sid, "long tool call", "msg_h4"))
        self.wait_for("working before restart",
                      lambda w: w["phase"] == "working")
        log("killing app mid-turn")
        self.kill_app()
        self.launch_app()
        self.attach_fake_host()
        self.link_agent_socket()
        # NO further events: the plugin's recovery timer alone must repaint.
        self.wait_for("working repainted after restart (no events)",
                      lambda w: w["phase"] == "working", timeout=30)
        self.send_events(self.turn_end(sid))
        time.sleep(1)

    def scenario_complete_during_downtime(self) -> None:
        sid = self.new_session_id()
        self.send_events(self.user_prompt(sid, "finish while down", "msg_h5"))
        self.wait_for("working before downtime",
                      lambda w: w["phase"] == "working")
        log("killing app; turn will complete during downtime")
        self.kill_app()
        self.send_events(self.turn_end(sid))
        time.sleep(1)
        self.launch_app()
        self.attach_fake_host()
        self.link_agent_socket()
        self.wait_for("missed turn-complete delivered after restart",
                      lambda w: w["unread_turn_complete"] is True, timeout=30)

    # ---------- lifecycle ----------

    def run(self) -> int:
        try:
            self.launch_app()
            self.setup_fake_host()
            self.attach_fake_host()
            self.link_agent_socket()
            if self.setup_only:
                log("setup complete; leaving app + fake host running")
                return 0
            scenarios = {
                "working": self.scenario_working_and_done,
                "permission": self.scenario_permission,
                "question": self.scenario_question,
                "restart": self.scenario_restart_mid_turn,
                "downtime": self.scenario_complete_during_downtime,
            }
            for name, scenario in scenarios.items():
                if self.only and name not in self.only:
                    continue
                log(f"--- scenario: {name} ---")
                scenario()
        finally:
            if not self.keep_app:
                self.kill_app()
                self.tmux("kill-server", check=False)
        print()
        log(f"{len(PASSES)} passed, {len(FAILURES)} failed")
        for failure in FAILURES:
            log(f"  FAILED: {failure}")
        return 1 if FAILURES else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", default="attn-e2e")
    parser.add_argument("--keep-app", action="store_true")
    parser.add_argument(
        "--setup-only", action="store_true",
        help="stand everything up (app, fake host, attach, link) and wait",
    )
    parser.add_argument(
        "--only", action="append", default=[],
        help="run only the named scenario(s): working, permission, question, restart, downtime",
    )
    args = parser.parse_args()
    return Harness(
        tag=args.tag,
        keep_app=args.keep_app or args.setup_only,
        setup_only=args.setup_only,
        only=args.only,
    ).run()


if __name__ == "__main__":
    raise SystemExit(main())
