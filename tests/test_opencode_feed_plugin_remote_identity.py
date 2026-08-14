#!/usr/bin/env python3
"""
Regression test: the cmux feed plugin resolves its remote identity from the
LIVE tmux environment tables, not only from birth-time process env.

The remote agent bridge pins CMUX_REMOTE_HOST_KEY / CMUX_SOCKET_PATH with
`tmux set-environment`, which only reaches processes started in panes created
AFTER the pin. Agents launched from older shells saw no vars, silently stayed
in local mode, and never self-reported lifecycle (no sidebar activity dot, no
turn notifications). The plugin now looks the vars up via
`tmux show-environment` (session scope, then global), prefers the live values
over stale process env, and repaints the running state after a socket drop
(cmux app restart mid-turn).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PLUGIN_PATH = REPO_ROOT / "Resources" / "opencode-plugin.js"

FAKE_TMUX = """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_TMUX_LOG"
last="${!#}"
case "$last" in
  CMUX_REMOTE_HOST_KEY)
    if [ -n "${FAKE_TMUX_HOST_KEY-}" ]; then
      printf 'CMUX_REMOTE_HOST_KEY=%s\\n' "$FAKE_TMUX_HOST_KEY"
    else
      echo "unknown variable: $last" >&2
      exit 1
    fi
    ;;
  CMUX_SOCKET_PATH)
    if [ -n "${FAKE_TMUX_SOCKET_PATH-}" ]; then
      printf 'CMUX_SOCKET_PATH=%s\\n' "$FAKE_TMUX_SOCKET_PATH"
    else
      echo "unknown variable: $last" >&2
      exit 1
    fi
    ;;
  *)
    exit 1
    ;;
esac
"""

BUN_SCRIPT = """
const net = require("node:net");

const pluginPath = process.env.TEST_PLUGIN_PATH;
const socketDir = process.env.TEST_SOCKET_DIR;
const liveSocket = `${socketDir}/live.sock`;

const received = [];
const conns = new Set();

const server = net.createServer((conn) => {
  conns.add(conn);
  conn.setEncoding("utf8");
  let buf = "";
  conn.on("data", (chunk) => {
    buf += chunk;
    let idx;
    while ((idx = buf.indexOf("\\n")) >= 0) {
      const line = buf.slice(0, idx);
      buf = buf.slice(idx + 1);
      if (!line) continue;
      let msg = null;
      try { msg = JSON.parse(line); } catch (_) {}
      if (msg && msg.method === "remote.tmux.resolve_pane") {
        received.push(`resolve:${msg.params.host_key}:${msg.params.pane_id}`);
        conn.write(JSON.stringify({
          id: msg.id,
          ok: true,
          result: { resolved: true, workspace_id: "W1", surface_id: "S1" },
        }) + "\\n");
      } else if (msg && msg.method) {
        received.push(`v2:${msg.method}`);
        conn.write(JSON.stringify({ id: msg.id, ok: true, result: {} }) + "\\n");
      } else {
        received.push(line);
        conn.write("OK\\n");
      }
    }
  });
  conn.on("close", () => conns.delete(conn));
  conn.on("error", () => {});
});
await new Promise((resolve) => server.listen(liveSocket, resolve));

const waitFor = async (predicate, ms, label) => {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`timeout: ${label}; received=${JSON.stringify(received)}`);
};
const runningLine = "set_agent_lifecycle opencode running --tab=W1 --panel=S1";

const mod = await import(pluginPath);
if (typeof mod.CMUXFeed !== "function") throw new Error("missing CMUXFeed export");

// Scenario 1: pane older than the env pin. No CMUX_* process env at all;
// identity must come from the fake tmux server environment.
delete process.env.CMUX_SOCKET_PATH;
delete process.env.CMUX_REMOTE_HOST_KEY;
process.env.TMUX = `${socketDir}/fake-tmux,123,0`;
process.env.TMUX_PANE = "%7";
process.env.FAKE_TMUX_HOST_KEY = "host-live";
process.env.FAKE_TMUX_SOCKET_PATH = liveSocket;

const hooks = await mod.CMUXFeed({ directory: "/tmp/x" });
await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "busy" } } } });
await waitFor(() => received.some((l) => l === "resolve:host-live:%7"), 5000, "resolve via tmux env fallback");
await waitFor(() => received.some((l) => l === runningLine), 5000, "lifecycle running via tmux env fallback");

// Scenario 2: cmux restarts mid-turn. Drop the connection; the next event
// (not a status flip) must reconnect, re-resolve, and repaint running.
received.length = 0;
for (const conn of conns) conn.destroy();
await new Promise((resolve) => setTimeout(resolve, 150));
await hooks.event({ event: { type: "tick" } });
await waitFor(() => received.some((l) => l.startsWith("resolve:")), 8000, "re-resolve after socket drop");
await waitFor(() => received.some((l) => l === runningLine), 5000, "repaint running after socket drop");

// Scenario 3: stale process env (dead socket, old host key) from a shell
// pinned by a previous cmux instance; the live tmux tables must win.
received.length = 0;
process.env.CMUX_SOCKET_PATH = `${socketDir}/dead.sock`;
process.env.CMUX_REMOTE_HOST_KEY = "host-stale";
const hooksStale = await mod.CMUXFeed({ directory: "/tmp/x" });
await hooksStale.event({ event: { type: "session.status", properties: { sessionID: "s3", status: { type: "busy" } } } });
await waitFor(() => received.some((l) => l === "resolve:host-live:%7"), 5000, "live tmux identity wins over stale env");
await waitFor(() => received.some((l) => l === runningLine), 5000, "lifecycle running with live identity");

// Scenario 4: not in tmux and no env: local mode, events complete, and no
// lifecycle lines are emitted.
received.length = 0;
delete process.env.TMUX;
delete process.env.TMUX_PANE;
delete process.env.CMUX_SOCKET_PATH;
delete process.env.CMUX_REMOTE_HOST_KEY;
const hooksLocal = await mod.CMUXFeed({ directory: "/tmp/x" });
await hooksLocal.event({ event: { type: "session.status", properties: { sessionID: "s4", status: { type: "busy" } } } });
await new Promise((resolve) => setTimeout(resolve, 300));
if (received.some((l) => l.startsWith("set_agent_lifecycle"))) {
  throw new Error(`local mode must not self-report lifecycle: ${JSON.stringify(received)}`);
}

console.log("BUN-PASS");
process.exit(0);
"""


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def main() -> int:
    bun = shutil.which("bun")
    if bun is None:
        print("SKIP: bun not found")
        return 0
    if not PLUGIN_PATH.exists():
        print(f"FAIL: plugin source missing at {PLUGIN_PATH}")
        return 1

    # AF_UNIX sun_path is 104 bytes on macOS: keep sockets under /tmp.
    with tempfile.TemporaryDirectory(prefix="cmux-feed-id-", dir="/tmp") as td:
        root = Path(td)
        fake_bin = root / "bin"
        fake_bin.mkdir()
        make_executable(fake_bin / "tmux", FAKE_TMUX)
        fake_tmux_log = root / "tmux-args.log"
        script_path = root / "check.mjs"
        script_path.write_text(BUN_SCRIPT, encoding="utf-8")

        env = os.environ.copy()
        env["PATH"] = f"{fake_bin}:{env.get('PATH', '')}"
        # Isolate DEFAULT_SOCKET (~/.config/cmux/cmux.sock) from the real user.
        env["HOME"] = str(root)
        env["TEST_PLUGIN_PATH"] = str(PLUGIN_PATH)
        env["TEST_SOCKET_DIR"] = str(root)
        env["FAKE_TMUX_LOG"] = str(fake_tmux_log)
        env.pop("CMUX_SOCKET_PATH", None)
        env.pop("CMUX_REMOTE_HOST_KEY", None)
        env.pop("TMUX", None)
        env.pop("TMUX_PANE", None)

        check = subprocess.run(
            [bun, str(script_path)],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=90,
        )
        if check.returncode != 0 or "BUN-PASS" not in check.stdout:
            print("FAIL: feed plugin remote identity scenarios failed")
            print(f"exit={check.returncode}")
            print(f"stdout={check.stdout.strip()}")
            print(f"stderr={check.stderr.strip()}")
            return 1

        tmux_log = fake_tmux_log.read_text(encoding="utf-8") if fake_tmux_log.exists() else ""
        if "show-environment CMUX_REMOTE_HOST_KEY" not in tmux_log:
            print(f"FAIL: plugin never queried tmux for the host key, got {tmux_log!r}")
            return 1
        if "show-environment CMUX_SOCKET_PATH" not in tmux_log:
            print(f"FAIL: plugin never queried tmux for the socket path, got {tmux_log!r}")
            return 1

    print("PASS: feed plugin resolves remote identity from live tmux environment")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
