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
// Park mode: feed.push frames get NO reply, like a real blocking decision
// awaiting the user. Parked connections are tracked so scenarios can tear
// down only the shared connection (the app's idle reaper does exactly
// that) and observe whether the parked push survives.
let parkFeedPush = false;
const parkedConns = new Set();

const handleConnection = (conn) => {
  console.error(`[srv] accepted connection at ${Date.now()}`);
  conns.add(conn);
  conn.setEncoding("utf8");
  let buf = "";
  conn.on("data", (chunk) => {
    buf += chunk;
    let idx;
    while ((idx = buf.indexOf("\\n")) >= 0) {
      const line = buf.slice(0, idx);
      buf = buf.slice(idx + 1);
      if (!line) {
        // A bare newline is the plugin's idle-reaper keepalive.
        received.push("ka");
        continue;
      }
      let msg = null;
      try { msg = JSON.parse(line); } catch (_) {}
      if (msg && msg.method === "remote.tmux.resolve_pane") {
        received.push(`resolve:${msg.params.host_key}:${msg.params.pane_id}`);
        conn.write(JSON.stringify({
          id: msg.id,
          ok: true,
          result: { resolved: true, workspace_id: "W1", surface_id: "S1" },
        }) + "\\n");
      } else if (msg && msg.method === "feed.push" && parkFeedPush) {
        const rid = (msg.params && msg.params.event && msg.params.event._opencode_request_id) || "";
        received.push(`push-parked:${rid}`);
        parkedConns.add(conn);
        conn.on("close", () => received.push(`parked-closed:${rid}`));
      } else if (msg && msg.method) {
        const requestId = msg.params && msg.params.request_id ? `:${msg.params.request_id}` : "";
        received.push(`v2:${msg.method}${requestId}`);
        conn.write(JSON.stringify({ id: msg.id, ok: true, result: {} }) + "\\n");
      } else {
        received.push(line);
        conn.write("OK\\n");
      }
    }
  });
  conn.on("close", () => { conns.delete(conn); parkedConns.delete(conn); });
  conn.on("error", () => {});
};

const destroySharedConns = () => {
  for (const conn of conns) {
    if (!parkedConns.has(conn)) conn.destroy();
  }
};

const fs = require("node:fs");
let server = net.createServer(handleConnection);
await new Promise((resolve) => server.listen(liveSocket, resolve));
const stopServer = async () => {
  for (const conn of conns) conn.destroy();
  await new Promise((resolve) => server.close(() => resolve()));
  try { fs.unlinkSync(liveSocket); } catch (_) {}
  console.error(`[srv] stopped at ${Date.now()}`);
};
const startServer = async () => {
  server = net.createServer(handleConnection);
  server.on("error", (error) => console.error(`[srv] listen error: ${error}`));
  await new Promise((resolve) => server.listen(liveSocket, resolve));
  console.error(`[srv] restarted at ${Date.now()}`);
};

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
// Streaming deltas prove a session lives in this process (mirrored
// sibling sessions never deliver them); each scenario seeds one before
// the first busy edge, like a real turn's first token.
await hooks.event({ event: { type: "message.part.delta", properties: { sessionID: "s1", delta: "x" } } });
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

// Scenario 2b: cmux fully DOWN (server gone) while an agent is deep in a
// long tool call — no bus events flow, so only the recovery timer can
// notice the app coming back. Open a turn on s9 first (registers the
// user prompt so the turn-complete flush below has a real turn).
received.length = 0;
await hooks.event({ event: { type: "message.updated", properties: {
  info: { id: "m9", sessionID: "s9", role: "user" },
} } });
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "text", messageID: "m9", text: "run the long build" },
} } });
// The queued typed prompt applies once s9 proves local.
await hooks.event({ event: { type: "message.part.delta", properties: { sessionID: "s9", delta: "x" } } });
await waitFor(() => received.some((l) => l === runningLine), 5000, "turn opened on s9");
await stopServer();
// Scenario 2c seed: the turn ENDS while cmux is down — the turn-complete
// notification fires into the void and must be flushed after recovery.
await hooks.event({ event: { type: "session.status", properties: {
  sessionID: "s9", status: { type: "idle" },
} } });
received.length = 0;
await new Promise((resolve) => setTimeout(resolve, 400));
await startServer();
// NO further events: the recovery timer alone must reconnect, re-resolve,
// repaint the running state (s1 is still busy), and deliver s9's missed
// turn-complete.
await waitFor(() => received.some((l) => l.startsWith("resolve:")), 8000, "timer-driven re-resolve");
await waitFor(() => received.some((l) => l === runningLine), 5000, "timer-driven running repaint");
await waitFor(
  () => received.some(
    (l) => l.startsWith("notify_target_async W1 S1 ") && l.includes("c=turn-complete")
  ),
  5000,
  "missed turn-complete flushed after recovery"
);
if (received.filter((l) => l.includes("c=turn-complete")).length !== 1) {
  throw new Error(`expected exactly one flushed turn-complete: ${JSON.stringify(received)}`);
}

// Scenario 3: stale process env (dead socket, old host key) from a shell
// pinned by a previous cmux instance; the live tmux tables must win.
received.length = 0;
process.env.CMUX_SOCKET_PATH = `${socketDir}/dead.sock`;
process.env.CMUX_REMOTE_HOST_KEY = "host-stale";
const hooksStale = await mod.CMUXFeed({ directory: "/tmp/x" });
await hooksStale.event({ event: { type: "message.part.delta", properties: { sessionID: "s3", delta: "x" } } });
await hooksStale.event({ event: { type: "session.status", properties: { sessionID: "s3", status: { type: "busy" } } } });
await waitFor(() => received.some((l) => l === "resolve:host-live:%7"), 5000, "live tmux identity wins over stale env");
await waitFor(() => received.some((l) => l === runningLine), 5000, "lifecycle running with live identity");

// Scenario 3b: a question answered in the agent's own UI (out-of-band)
// concludes the parked blocking item immediately: the plugin sends
// feed.conclude and the parked event promise resolves without replying
// to opencode.
received.length = 0;
const pendingAsk = hooks.event({ event: { type: "question.asked", properties: {
  id: "q-77", sessionID: "s1",
  questions: [{ question: "Proceed?", options: [{ label: "Yes" }, { label: "No" }] }],
} } });
await waitFor(() => received.some((l) => l.startsWith("v2:feed.push")), 5000, "blocking push parked");
await hooks.event({ event: { type: "question.replied", properties: { sessionID: "s1", requestID: "q-77" } } });
await waitFor(() => received.some((l) => l === "v2:feed.conclude:q-77"), 5000, "feed.conclude sent for out-of-band reply");
const askSettled = await Promise.race([
  pendingAsk.then(() => "settled"),
  new Promise((resolve) => setTimeout(() => resolve("timeout"), 4000)),
]);
if (askSettled !== "settled") {
  throw new Error("parked question.asked did not resolve after out-of-band reply");
}

// Scenario 3c: the app's idle reaper closes the quiet SHARED connection
// while a blocking decision parks on its DEDICATED connection. Three
// pinned behaviors: the event hook returns while the push parks (a parked
// hook would queue the very replied event that concludes it), the parked
// push survives shared-connection churn (its resolver must not be swept
// with the shared conn's), and the out-of-band reply still concludes it.
received.length = 0;
parkFeedPush = true;
const askSettling = Promise.race([
  hooks.event({ event: { type: "question.asked", properties: {
    id: "q-88", sessionID: "s1",
    questions: [{ question: "Deploy?", options: [{ label: "Yes" }, { label: "No" }] }],
  } } }).then(() => "settled"),
  new Promise((resolve) => setTimeout(() => resolve("timeout"), 2000)),
]);
await waitFor(() => received.some((l) => l === "push-parked:q-88"), 5000, "blocking push parked on dedicated conn");
if ((await askSettling) !== "settled") {
  throw new Error("question.asked hook parked the event bus while the push waits");
}
destroySharedConns();
await new Promise((resolve) => setTimeout(resolve, 500));
if (received.some((l) => l === "parked-closed:q-88")) {
  throw new Error("shared-conn drop must not settle a parked blocking push");
}
await hooks.event({ event: { type: "question.replied", properties: { sessionID: "s1", requestID: "q-88" } } });
await waitFor(() => received.some((l) => l === "v2:feed.conclude:q-88"), 5000, "conclude sent after shared-conn churn");
await waitFor(() => received.some((l) => l === "parked-closed:q-88"), 5000, "parked push settled by out-of-band reply");
parkFeedPush = false;

// Scenario 3d: keepalive newlines ride the shared connection so the app's
// idle reaper never fires between real frames.
received.length = 0;
await hooks.event({ event: { type: "tick" } });
await waitFor(() => received.filter((l) => l === "ka").length >= 2, 5000, "keepalive newlines on the shared conn");

// Scenario 3e: a conclude fired while cmux is down must be redelivered
// after the next successful resolve instead of silently vanishing (a lost
// conclude leaves "needs input" stuck until wait-timeout expiry).
received.length = 0;
await stopServer();
await hooks.event({ event: { type: "question.replied", properties: { sessionID: "s1", requestID: "q-99" } } });
await new Promise((resolve) => setTimeout(resolve, 300));
await startServer();
await waitFor(() => received.some((l) => l === "v2:feed.conclude:q-99"), 8000, "conclude redelivered after recovery");
// Both live factories (hooks: s1 busy, hooksStale: s3 busy) repaint running
// after the restart; drain those before scenario 4 asserts on quiet, then
// idle both sessions so no straggler resolve can repaint into scenario 4's
// window (afterResolveRecovered only paints while some session is busy).
await waitFor(() => received.filter((l) => l === runningLine).length >= 2, 8000, "recovery repaints drained");
await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "idle" } } } });
await hooksStale.event({ event: { type: "session.status", properties: { sessionID: "s3", status: { type: "idle" } } } });
// Both factories' delayed idle writes land inside this drain window
// (CMUX_FEED_IDLE_GRACE_MS=120 in the test env).
await new Promise((resolve) => setTimeout(resolve, 300));

// Scenario 3f: swarm/goal-loop semantics. Engine deliveries (synthetic
// parts: goal-continuation nudges, worker reports to the lead, task
// prompts fanned out to workers) never open turns; worker sessions
// (parentID set) never mint turn-complete notifications; a worker idling
// never blanks the running slot while the lead is busy; and an idle-then-
// busy bounce inside the grace window writes no idle line at all (the
// blue/green strobe a goal loop produced at every iteration boundary).
received.length = 0;
const idleLine = "set_agent_lifecycle opencode idle --tab=W1 --panel=S1";
await hooks.event({ event: { type: "message.updated", properties: {
  info: { id: "m50", sessionID: "s1", role: "user" },
} } });
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "text", messageID: "m50", text: "start the goal" },
} } });
await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "busy" } } } });
await waitFor(() => received.some((l) => l === runningLine), 5000, "lead turn opened");

// A worker spawns under the lead and receives its engine-authored prompt.
received.length = 0;
await hooks.event({ event: { type: "session.created", properties: {
  info: { id: "w1", parentID: "s1", directory: "/tmp/x" },
} } });
await waitFor(() => received.filter((l) => l.startsWith("v2:feed.push")).length === 1, 5000, "worker SessionStart telemetry");
await hooks.event({ event: { type: "message.updated", properties: {
  info: { id: "mw1", sessionID: "w1", role: "user" },
} } });
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "text", messageID: "mw1", text: "delegated unit", synthetic: true },
} } });
await hooks.event({ event: { type: "session.status", properties: { sessionID: "w1", status: { type: "busy" } } } });
await new Promise((resolve) => setTimeout(resolve, 200));
if (received.filter((l) => l.startsWith("v2:feed.push")).length !== 1) {
  throw new Error(`synthetic delivery must not mint UserPromptSubmit telemetry: ${JSON.stringify(received)}`);
}

// The worker idles while the lead is still busy: no idle write, no
// turn-complete, ever — its report to the lead is not a finished turn.
received.length = 0;
await hooks.event({ event: { type: "session.status", properties: { sessionID: "w1", status: { type: "idle" } } } });
await new Promise((resolve) => setTimeout(resolve, 400));
if (received.some((l) => l === idleLine)) {
  throw new Error(`worker idle blanked the slot while the lead is busy: ${JSON.stringify(received)}`);
}
if (received.some((l) => l.includes("c=turn-complete"))) {
  throw new Error(`worker idle minted a turn-complete: ${JSON.stringify(received)}`);
}

// Even a REAL typed part in a child session (a user driving the worker
// directly) opens no turn: child sessions never notify.
await hooks.event({ event: { type: "message.updated", properties: {
  info: { id: "mw2", sessionID: "w1", role: "user" },
} } });
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "text", messageID: "mw2", text: "typed at the worker" },
} } });
await hooks.event({ event: { type: "session.status", properties: { sessionID: "w1", status: { type: "busy" } } } });
received.length = 0;
await hooks.event({ event: { type: "session.status", properties: { sessionID: "w1", status: { type: "idle" } } } });
await new Promise((resolve) => setTimeout(resolve, 250));
if (received.some((l) => l.includes("c=turn-complete"))) {
  throw new Error(`child session turn minted a notification: ${JSON.stringify(received)}`);
}

// Goal iteration boundary: the lead idles and the loop re-prompts within
// the grace windows. NOTHING may fire — no idle write (the strobe) and
// no turn-complete toast (the typed turn's debt is HELD across the
// bounce; iterating is not completing).
received.length = 0;
await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "idle" } } } });
await new Promise((resolve) => setTimeout(resolve, 40));
// The loop's continuation nudge: an engine-authored (synthetic) user
// message, then busy again.
await hooks.event({ event: { type: "message.updated", properties: {
  info: { id: "m51", sessionID: "s1", role: "user" },
} } });
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "text", messageID: "m51", text: "Continue if you have next steps.", synthetic: true },
} } });
await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "busy" } } } });
await new Promise((resolve) => setTimeout(resolve, 400));
if (received.some((l) => l === idleLine)) {
  throw new Error(`iteration boundary inside the grace window strobed the slot: ${JSON.stringify(received)}`);
}
if (received.some((l) => l.includes("c=turn-complete"))) {
  throw new Error(`iteration boundary minted a mid-goal toast: ${JSON.stringify(received)}`);
}

// TRUE completion: the loop finally rests. The settled idle writes once,
// and the typed prompt's carried debt delivers exactly ONE toast.
received.length = 0;
await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "idle" } } } });
await waitFor(() => received.some((l) => l === idleLine), 5000, "settled idle lands after the grace window");
await waitFor(
  () => received.filter((l) => l.includes("c=turn-complete")).length === 1,
  5000,
  "goal completion notifies exactly once at settle"
);
await new Promise((resolve) => setTimeout(resolve, 300));
if (received.filter((l) => l.includes("c=turn-complete")).length !== 1) {
  throw new Error(`completion toast repeated after settle: ${JSON.stringify(received)}`);
}

// A WATCH wake: the card is a synthetic delivery, but the busy edge must
// repaint running immediately — a resting (or green unseen-done) agent
// goes blue the moment a watch wakes it.
received.length = 0;
await hooks.event({ event: { type: "message.updated", properties: {
  info: { id: "m52", sessionID: "s1", role: "user" },
} } });
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "text", messageID: "m52", text: "[watch] borg job finished", synthetic: true },
} } });
await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "busy" } } } });
await waitFor(() => received.some((l) => l === runningLine), 5000, "watch wake repaints running from idle");
// The wake's work ending mints no turn-complete (nudge semantics) and
// settles back to idle through the same grace window.
received.length = 0;
await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "idle" } } } });
await waitFor(() => received.some((l) => l === idleLine), 5000, "watch work settles back to idle");
if (received.some((l) => l.includes("c=turn-complete"))) {
  throw new Error(`watch-opened work minted a turn-complete: ${JSON.stringify(received)}`);
}

// Scenario 3g: the live activity ticker. Tool parts paint a throttled
// "what is it doing" status line on the sidebar row; bursts coalesce to
// the newest text at the interval boundary; identical text never
// re-sends; the settled idle clears the line; and a parked blocking
// decision clears it so the needs-input line stands alone.
received.length = 0;
const activityLine = (text) =>
  `set_status opencode.activity ${text} --priority=-1 --tab=W1 --panel=S1`;
const activityClearLine = "clear_status opencode.activity --tab=W1";
await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "busy" } } } });
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "tool", sessionID: "s1", messageID: "mt1", tool: "bash", state: { status: "running", input: { command: "git status" } } },
} } });
await waitFor(() => received.some((l) => l === activityLine("bash: git status")), 5000, "first activity paints immediately");
// A burst inside the throttle window coalesces to the LATEST text; the
// intermediate tool never reaches the wire.
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "tool", sessionID: "s1", messageID: "mt2", tool: "read", state: { status: "running", input: { filePath: "/tmp/a.txt" } } },
} } });
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "tool", sessionID: "s1", messageID: "mt3", tool: "edit", state: { status: "running", input: { filePath: "/tmp/b.txt" } } },
} } });
await waitFor(() => received.some((l) => l === activityLine("edit: /tmp/b.txt")), 5000, "trailing flush lands the newest activity");
if (received.some((l) => l === activityLine("read: /tmp/a.txt"))) {
  throw new Error(`throttle window leaked an intermediate activity send: ${JSON.stringify(received)}`);
}
// Identical text never re-sends once the window passes.
received.length = 0;
await new Promise((resolve) => setTimeout(resolve, 250));
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "tool", sessionID: "s1", messageID: "mt4", tool: "edit", state: { status: "running", input: { filePath: "/tmp/b.txt" } } },
} } });
await new Promise((resolve) => setTimeout(resolve, 300));
if (received.some((l) => l.startsWith("set_status opencode.activity"))) {
  throw new Error(`identical activity text re-sent: ${JSON.stringify(received)}`);
}
// Completed tool states carry no activity.
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "tool", sessionID: "s1", messageID: "mt5", tool: "bash", state: { status: "completed", input: { command: "ls" } } },
} } });
await new Promise((resolve) => setTimeout(resolve, 300));
if (received.some((l) => l.includes("bash: ls"))) {
  throw new Error(`completed tool state painted activity: ${JSON.stringify(received)}`);
}
// The settled idle clears the activity line alongside the lifecycle write.
received.length = 0;
await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "idle" } } } });
await waitFor(() => received.some((l) => l === activityClearLine), 5000, "settled idle clears the activity line");
// A parked blocking decision clears the repainted activity line.
await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "busy" } } } });
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "tool", sessionID: "s1", messageID: "mt6", tool: "bash", state: { status: "running", input: { command: "make deploy" } } },
} } });
await waitFor(() => received.some((l) => l === activityLine("bash: make deploy")), 5000, "activity repaints on the next turn");
received.length = 0;
const pendingAsk3g = hooks.event({ event: { type: "question.asked", properties: {
  id: "q-3g", sessionID: "s1",
  questions: [{ question: "Ship it?", options: [{ label: "Yes" }] }],
} } });
await waitFor(() => received.some((l) => l === activityClearLine), 5000, "parked decision clears the activity line");
await hooks.event({ event: { type: "question.replied", properties: { sessionID: "s1", requestID: "q-3g" } } });
await pendingAsk3g;
// Settle s1 idle so scenario 4's quiet window stays quiet.
await hooks.event({ event: { type: "session.status", properties: { sessionID: "s1", status: { type: "idle" } } } });
await new Promise((resolve) => setTimeout(resolve, 300));

// Scenario 3h: same-folder sibling quarantine. The engine mirrors
// same-project sessions across processes: a sibling pane's session
// delivers session.created, session.status BUSY, and message parts onto
// this bus, but never its idle edge or streaming deltas. Unproven
// sessions must not paint the pane running, must not leak their typed
// prompt into this pane's telemetry, must not paint activity text, and
// must never mint a toast. A REAL first turn (prompt queued before the
// first delta proves the session) applies in full on confirmation.
received.length = 0;
await hooks.event({ event: { type: "session.created", properties: {
  info: { id: "f1", directory: "/tmp/x" },
} } });
await hooks.event({ event: { type: "message.updated", properties: {
  info: { id: "mf1", sessionID: "f1", role: "user" },
} } });
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "text", messageID: "mf1", sessionID: "f1", text: "sibling pane's prompt" },
} } });
await hooks.event({ event: { type: "session.status", properties: { sessionID: "f1", status: { type: "busy" } } } });
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "tool", sessionID: "f1", messageID: "mf2", tool: "bash", state: { status: "running", input: { command: "sibling job" } } },
} } });
await new Promise((resolve) => setTimeout(resolve, 400));
if (received.some((l) => l === runningLine)) {
  throw new Error(`a mirrored sibling's busy painted this pane running: ${JSON.stringify(received)}`);
}
if (received.some((l) => l.startsWith("v2:feed.push"))) {
  throw new Error(`a mirrored sibling's prompt leaked into telemetry: ${JSON.stringify(received)}`);
}
if (received.some((l) => l.includes("sibling job"))) {
  throw new Error(`a mirrored sibling's tool painted activity text: ${JSON.stringify(received)}`);
}

// A REAL first turn on a fresh session: the typed prompt is queued while
// ownership is unproven, then the first streaming delta confirms the
// session and the prompt applies in full (telemetry, running paint, and
// the turn debt that mints exactly one toast at settle).
await hooks.event({ event: { type: "message.updated", properties: {
  info: { id: "m80", sessionID: "s8", role: "user" },
} } });
await hooks.event({ event: { type: "message.part.updated", properties: {
  part: { type: "text", messageID: "m80", sessionID: "s8", text: "first turn in a fresh pane" },
} } });
await hooks.event({ event: { type: "session.status", properties: { sessionID: "s8", status: { type: "busy" } } } });
await new Promise((resolve) => setTimeout(resolve, 150));
if (received.some((l) => l === runningLine) || received.some((l) => l.startsWith("v2:feed.push"))) {
  throw new Error(`an unproven session acted before its first delta: ${JSON.stringify(received)}`);
}
await hooks.event({ event: { type: "message.part.delta", properties: { sessionID: "s8", delta: "F" } } });
await waitFor(() => received.some((l) => l === runningLine), 5000, "confirmed first turn paints running");
await waitFor(() => received.some((l) => l.startsWith("v2:feed.push")), 5000, "queued UserPromptSubmit flushes on confirmation");
received.length = 0;
await hooks.event({ event: { type: "session.status", properties: { sessionID: "s8", status: { type: "idle" } } } });
await waitFor(
  () => received.filter((l) => l.includes("c=turn-complete")).length === 1,
  5000,
  "confirmed first turn mints exactly one toast at settle"
);
// The sibling ghost still parks unproven: quiet forever, no toast.
await new Promise((resolve) => setTimeout(resolve, 300));
if (received.some((l) => l.includes("sibling"))) {
  throw new Error(`the sibling ghost surfaced after settle: ${JSON.stringify(received)}`);
}
received.length = 0;

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
        # Fast recovery cadence so the timer-driven scenarios finish quickly.
        env["CMUX_FEED_RECONNECT_INTERVAL_MS"] = "250"
        env["CMUX_FEED_KEEPALIVE_INTERVAL_MS"] = "200"
        # Short idle grace so the debounced lifecycle writes land inside the
        # scenario windows instead of stretching the run by 2.5s per settle.
        env["CMUX_FEED_IDLE_GRACE_MS"] = "120"
        # Tight activity-ticker window so the throttle/trailing-flush
        # scenario runs in milliseconds instead of seconds.
        env["CMUX_FEED_ACTIVITY_INTERVAL_MS"] = "200"
        # Same for the turn-complete settle (fires after the idle grace).
        env["CMUX_FEED_TURN_SETTLE_MS"] = "200"
        env["CMUX_FEED_DEBUG"] = "1"
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
