// cmux-feed-plugin-marker v8
// Bridges OpenCode's plugin event bus to the cmux socket's feed.* verbs.
// Installed by `cmux hooks setup` or `cmux hooks opencode install`; pushed
// onto remote tmux machines by the cmux remote agent bridge.
// DO NOT EDIT MANUALLY - cmux upgrades this file in place.

const net = require("node:net");
const os = require("node:os");
const fs = require("node:fs");
const path = require("node:path");
const childProcess = require("node:child_process");

const DEFAULT_SOCKET = `${os.homedir()}/.config/cmux/cmux.sock`;
const REPLY_TIMEOUT_MS = 120_000;
const MAX_PLAN_BYTES = 128 * 1024;

// Remote mode: this opencode runs inside a tmux pane on a machine that a
// cmux instance mirrors over SSH. The remote agent bridge injects
// CMUX_REMOTE_HOST_KEY (the machine identity) and CMUX_SOCKET_PATH (a
// reverse-forwarded unix socket back to that cmux) into the tmux server
// environment; $TMUX_PANE identifies which mirrored pane this agent lives
// in. In remote mode the plugin resolves its pane to the mirrored
// workspace/surface UUIDs once, then self-reports lifecycle over the
// socket (there is no local PID for cmux to watch).
//
// The bridge can only pin those vars into tmux's environment TABLES
// (`set-environment`), which reach processes started in panes created
// AFTER the pin. A shell in a pane older than the first attach never saw
// them, so an agent launched from it would silently stay in local mode.
// tmux itself always sets $TMUX/$TMUX_PANE, and `tmux show-environment`
// reads the LIVE tables, so identity is resolved tmux-first (session
// scope, then global) with birth-time process env as the fallback. The
// live tables also win when process env is stale, e.g. a shell pinned by
// a previous cmux instance whose socket path has since changed.
const TMUX_ENV_LOOKUP_TIMEOUT_MS = 3_000;
const REMOTE_RESOLVE_TIMEOUT_MS = 10_000;
const REMOTE_RESOLVE_ATTEMPTS = 3;
// Disconnect recovery cadence. Event-driven recovery alone has a hole: an
// agent deep in a long tool call (a build, a test run) emits NO bus events
// for minutes, so after a cmux restart nothing would trigger the
// re-resolve and the sidebar's running state stayed blank until streaming
// resumed. While a turn is open and the socket is down, a timer retries
// instead. Env override exists for tests.
const RECONNECT_RECOVERY_INTERVAL_MS =
  Number(process.env.CMUX_FEED_RECONNECT_INTERVAL_MS || "") || 8_000;

// The app reaps control connections that stay silent for ~30s (its
// receive-timeout guard against hung peers). The shared connection is
// silent exactly when the agent is: mid tool call, awaiting the user. A
// bare newline is protocol-neutral (the app skips empty lines) but
// resets the reaper's idle clock, and it turns a half-open FIN into a
// prompt write error, so recovery starts within one interval instead of
// at the next real frame. Env override exists for tests.
const KEEPALIVE_INTERVAL_MS =
  Number(process.env.CMUX_FEED_KEEPALIVE_INTERVAL_MS || "") || 12_000;

// A turn-complete notification written moments before a disconnect may
// have landed in a dying socket (the app's FIN arrives milliseconds after
// the write "succeeds"). Sends this recent are treated as possibly lost
// when a disconnect follows, and are redelivered after recovery:
// at-least-once beats silently losing the unseen-done state, and the
// duplicate window is only ever entered by an app exit racing a turn end.
const TURN_COMPLETE_REDELIVERY_WINDOW_MS = 3_000;

// A goal loop (and any queued follow-up) re-prompts the session moments
// after it idles, so writing "idle" on the raw edge strobed the sidebar
// spinner at every iteration boundary. The idle write waits out this
// grace window and is cancelled by busy returning; "running" still writes
// immediately. Env override exists for tests.
const IDLE_LIFECYCLE_GRACE_MS =
  Number(process.env.CMUX_FEED_IDLE_GRACE_MS || "") || 2_500;

// Turn-complete notifications fire only at TRUE completion: a typed
// prompt's debt is carried across goal-loop iterations (each raw idle is
// followed by a continuation nudge within moments) and settles when the
// SESSION stays idle for this long. Wider than the lifecycle grace: a
// false mid-goal "finished" toast costs attention, a real toast arriving
// a few seconds late costs nothing. Env override exists for tests.
const TURN_SETTLE_GRACE_MS =
  Number(process.env.CMUX_FEED_TURN_SETTLE_MS || "") || 5_000;

// Live activity ticker: while the agent works, the sidebar row shows what
// it is doing right now (the running tool and its target), refreshed at a
// calm cadence instead of only toasting at turn end. Sends are throttled
// to this interval with a trailing flush, so bursts collapse to the latest
// text and the row never strobes. Env override exists for tests.
const ACTIVITY_STATUS_INTERVAL_MS =
  Number(process.env.CMUX_FEED_ACTIVITY_INTERVAL_MS || "") || 3_000;
// The sidebar status slot the ticker writes. Deliberately NOT the bare
// agent key: non-allowlisted keys render as plain metadata text without
// requiring a local agent PID binding (remote agents have none), and the
// feed's needs-input entry (priority 0) outranks it while both are shown.
const ACTIVITY_STATUS_KEY = "opencode.activity";
const ACTIVITY_TEXT_MAX = 80;

// Opt-in stderr tracing (CMUX_FEED_DEBUG=1) for diagnosing the plugin on a
// remote machine without a debugger: connection lifecycle, recovery timer,
// and resolve outcomes. Zero cost when unset.
const feedDebugLog = (process.env.CMUX_FEED_DEBUG || "").trim()
  ? (...parts) => console.error("[cmux-feed]", ...parts)
  : () => {};

const tmuxEnvLookup = async (name) => {
  if (!(process.env.TMUX || "").trim()) return null;
  for (const args of [["show-environment", name], ["show-environment", "-g", name]]) {
    const stdout = await new Promise((resolve) => {
      try {
        childProcess.execFile(
          "tmux",
          args,
          { timeout: TMUX_ENV_LOOKUP_TIMEOUT_MS, encoding: "utf8" },
          (error, out) => resolve(error ? null : out)
        );
      } catch (_) {
        resolve(null);
      }
    });
    if (!stdout) continue;
    // A removed variable prints as `-NAME`; the prefix match skips it.
    const line = stdout.split("\n").find((entry) => entry.startsWith(`${name}=`));
    const value = line ? line.slice(name.length + 1).trim() : "";
    if (value) return value;
  }
  return null;
};

export const CMUXFeed = async (ctx) => {
  let client = null;
  let buffered = "";
  let remoteTarget = null;
  let remoteResolvePromise = null;
  const pending = new Map();
  // Resolvers for blocking pushes parked on their own dedicated
  // connections. Kept apart from `pending` so shared-connection teardown
  // (failPending) cannot kill a push whose app-side waiter still parks.
  const blockingPending = new Map();
  // Concludes not yet confirmed delivered (dead socket, app restart
  // mid-reply). Flushed after the next successful resolve; feed.conclude
  // is idempotent app-side.
  const pendingConcludes = new Map();
  const messageRoles = new Map();
  const sessions = new Map();
  // Message ids whose typed text already opened a turn (streaming
  // re-delivers a growing part; one prompt = one UserPromptSubmit).
  const promptedMessageIds = new Set();
  // The last lifecycle state actually written, so aggregate updates only
  // write edges. Reset on every reconnect (a fresh cmux must be repainted).
  let lastLifecycleSent = null;
  // Pending delayed idle write (see updateAggregateLifecycle's grace).
  let idleGraceTimer = null;
  // Live activity ticker state (see sendActivityStatus).
  let lastActivitySentText = null;
  let lastActivitySentAt = 0;
  let pendingActivityText = null;
  let activityFlushTimer = null;

  // Identity is mutable: tmux-first with process env fallback, refreshed
  // after a socket drop so a new cmux instance's pins are picked up live.
  let socketPath = (process.env.CMUX_SOCKET_PATH || "").trim() || null;
  let remoteHostKey = (process.env.CMUX_REMOTE_HOST_KEY || "").trim() || null;
  const remotePaneId = (process.env.TMUX_PANE || "").trim() || null;
  let identityPromise = null;

  // Disconnect recovery state. Completion debts live on the session states
  // themselves (`completionOwed` survives socket churn); this map only
  // remembers sends recent enough to have died in a dying socket's buffer,
  // so a disconnect can re-mark them owed for redelivery.
  const recentTurnCompleteSends = new Map();
  let reconnectRecoveryTimer = null;

  const ensureIdentity = () => {
    if (!identityPromise) {
      identityPromise = (async () => {
        if (remotePaneId) {
          const liveHostKey = await tmuxEnvLookup("CMUX_REMOTE_HOST_KEY");
          if (liveHostKey) remoteHostKey = liveHostKey;
          const liveSocketPath = await tmuxEnvLookup("CMUX_SOCKET_PATH");
          if (liveSocketPath) socketPath = liveSocketPath;
        }
      })();
    }
    return identityPromise;
  };

  const isRemote = () => Boolean(remoteHostKey && remotePaneId);

  const isObject = (value) => value && typeof value === "object" && !Array.isArray(value);

  const firstString = (...values) => {
    for (const value of values) {
      if (typeof value === "string" && value.trim().length > 0) return value.trim();
    }
    return null;
  };

  const normalizeText = (value, max = 1000) => {
    if (typeof value !== "string") return null;
    const normalized = value.replace(/\s+/g, " ").trim();
    if (!normalized) return null;
    return normalized.length > max ? `${normalized.slice(0, max - 3)}...` : normalized;
  };

  const sessionState = (sessionId) => {
    const key = sessionId || "unknown";
    if (!sessions.has(key)) {
      sessions.set(key, {
        lastUserMessage: null,
        assistantPreamble: null,
        cwd: null,
        isBusy: false,
        turnOpen: false,
        // Subagent sessions (task tool, swarms) carry the lead's id here.
        // They flap busy/idle constantly and their prompts are engine
        // deliveries, so they never mint turn-complete notifications.
        parentId: null,
        // A typed turn ended but the completion notification has not been
        // delivered yet: it settles (see armCompletionSettle) or carries
        // across goal-loop iterations and disconnects until a send lands.
        completionOwed: false,
        settleTimer: null,
        // The engine mirrors same-project sessions ACROSS processes: a
        // sibling agent in the same folder delivers its session.created,
        // session.status BUSY, and message parts onto this process's bus
        // (its idle and streaming deltas never cross). Only sessions
        // proven to live in THIS process may drive the pane's lifecycle,
        // turns, notifications, or activity text; everything else would
        // paint a sibling pane's work onto this pane's sidebar row.
        confirmedLocal: false,
        // Work queued while ownership is unproven, flushed on
        // confirmation: telemetry frames plus the typed-prompt turn open.
        pendingTelemetry: [],
        pendingPromptOpensTurn: false,
        lastEventAt: Date.now(),
      });
    }
    const state = sessions.get(key);
    state.lastEventAt = Date.now();
    return state;
  };

  // Ownership proof: streaming deltas, idle edges, and blocking asks are
  // emitted only by the process that runs the session (mirrored copies
  // carry busy edges and message parts, never these). A confirmed lead
  // confirms its subagents: workers run in the lead's process.
  const confirmSessionLocal = (sid) => {
    const state = sessionState(sid);
    if (state.confirmedLocal) return state;
    state.confirmedLocal = true;
    for (const frame of state.pendingTelemetry.splice(0)) {
      pushTelemetry(frame);
    }
    if (state.pendingPromptOpensTurn) {
      state.pendingPromptOpensTurn = false;
      // The queued typed prompt now applies exactly as it would have on
      // arrival: busy + turn open (an idle that follows in the same
      // handler still closes the turn and banks the completion debt).
      noteSessionBusyState(sid, true, true);
    }
    // Child sessions created before the parent's proof arrive here too.
    for (const [childId, childState] of sessions) {
      if (!childState.confirmedLocal && childState.parentId === sid) {
        confirmSessionLocal(childId);
      }
    }
    updateAggregateLifecycle();
    return state;
  };

  // Foreign busy ghosts never receive the idle that would clean them up;
  // without pruning every sibling session in the folder accumulates
  // forever. Confirmed sessions are kept: they are this process's own.
  const pruneUnconfirmedSessions = () => {
    if (sessions.size <= 200) return;
    const candidates = [...sessions.entries()]
      .filter(([, state]) => !state.confirmedLocal)
      .sort((a, b) => a[1].lastEventAt - b[1].lastEventAt);
    for (const [sid, state] of candidates.slice(0, sessions.size - 200)) {
      if (state.settleTimer) clearTimeout(state.settleTimer);
      sessions.delete(sid);
    }
  };

  const queueTelemetryUntilConfirmed = (sid, frame) => {
    const state = sessionState(sid);
    if (state.confirmedLocal) {
      pushTelemetry(frame);
      return;
    }
    state.pendingTelemetry.push(frame);
    if (state.pendingTelemetry.length > 4) state.pendingTelemetry.shift();
  };

  const contextForSession = (sessionId) => {
    const state = sessionState(sessionId);
    const context = {};
    if (state.lastUserMessage) context.lastUserMessage = state.lastUserMessage;
    if (state.assistantPreamble) context.assistantPreamble = state.assistantPreamble;
    return Object.keys(context).length > 0 ? context : undefined;
  };

  const clientMethod = (root, name) => {
    const fn = root?.[name];
    return typeof fn === "function" ? fn.bind(root) : null;
  };

  const rawClientRequest = async (method, options) => {
    const raw = ctx?.client?._client || ctx?.client?.client;
    const fn = raw && typeof raw[method] === "function" ? raw[method].bind(raw) : null;
    if (!fn) throw new Error(`OpenCode SDK raw ${method} unavailable`);
    return await fn({
      ...options,
      throwOnError: true,
      headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    });
  };

  const tryRawClientRequest = async (method, options) => {
    try {
      await rawClientRequest(method, options);
      return true;
    } catch (_) {
      return false;
    }
  };

  const callClientMethod = async (root, name, args) => {
    const fn = clientMethod(root, name);
    if (!fn) return false;
    await fn(args);
    return true;
  };

  const legacyPermissionBody = (reply) => ({
    response: reply === "reject" ? "deny" : "approve",
    remember: reply === "always",
  });

  const replyPermission = async ({ sessionId, requestId, reply, message }) => {
    if (
      await tryRawClientRequest("post", {
        url: "/permission/{requestID}/reply",
        path: { requestID: requestId },
        body: message ? { reply, message } : { reply },
      })
    ) {
      return;
    }

    if (await callClientMethod(ctx?.client?.permission, "reply", { requestID: requestId, reply, message })) {
      return;
    }

    if (sessionId) {
      await callClientMethod(ctx?.client, "postSessionIdPermissionsPermissionId", {
        path: { id: sessionId, permissionID: requestId },
        body: legacyPermissionBody(reply),
      });
    }
  };

  const replyQuestion = async (requestId, answers) => {
    if (
      await tryRawClientRequest("post", {
        url: "/question/{requestID}/reply",
        path: { requestID: requestId },
        body: { answers },
      })
    ) {
      return;
    }

    await callClientMethod(ctx?.client?.question, "reply", { requestID: requestId, answers });
  };

  const rejectQuestion = async (requestId) => {
    if (
      await tryRawClientRequest("post", {
        url: "/question/{requestID}/reject",
        path: { requestID: requestId },
        body: {},
      })
    ) {
      return;
    }

    await callClientMethod(ctx?.client?.question, "reject", { requestID: requestId });
  };

  const updateSessionPermission = async (sessionId, permission) => {
    if (!sessionId || !permission.length) return true;
    if (
      await tryRawClientRequest("patch", {
        url: "/session/{sessionID}",
        path: { sessionID: sessionId },
        body: { permission },
      })
    ) {
      return true;
    }

    return await callClientMethod(ctx?.client?.session, "update", { path: { id: sessionId }, body: { permission } });
  };

  const sendPlanFeedback = async (sessionId, text) => {
    const message = normalizeText(text, 2000);
    if (!sessionId || !message) return;
    const body = {
      agent: "plan",
      parts: [{ type: "text", text: message }],
    };
    if (
      await tryRawClientRequest("post", {
        url: "/session/{sessionID}/prompt_async",
        path: { sessionID: sessionId },
        body,
      })
    ) {
      return;
    }

    await callClientMethod(ctx?.client?.session, "promptAsync", { path: { id: sessionId }, body });
  };

  const permissionRulesForExitPlanMode = (mode) => {
    switch (mode) {
      case "manual":
        return [
          { permission: "edit", pattern: "*", action: "ask" },
          { permission: "bash", pattern: "*", action: "ask" },
          { permission: "external_directory", pattern: "*", action: "ask" },
        ];
      case "autoAccept":
      case "bypassPermissions":
        return [
          { permission: "edit", pattern: "*", action: "allow" },
          { permission: "bash", pattern: "*", action: "allow" },
          { permission: "external_directory", pattern: "*", action: "allow" },
        ];
      default:
        return [];
    }
  };

  const permissionReplyForMode = (mode) => {
    switch (mode) {
      case "deny":
        return "reject";
      case "always":
      case "all":
      case "bypass":
        return "always";
      default:
        return "once";
    }
  };

  const permissionSessionRulesForMode = (permission, mode) => {
    if (!permission) return [];
    switch (mode) {
      case "all":
      case "bypass":
        return [{ permission: "*", pattern: "*", action: "allow" }];
      default:
        return [];
    }
  };

  const questionAnswers = (selections) => {
    if (!Array.isArray(selections) || selections.length === 0) return [[]];
    return selections.map((selection) => [String(selection)]);
  };

  const resolveSessionPlanPath = (sid, rawPlanPath) => {
    if (!rawPlanPath) return null;
    const root = path.resolve(sessionState(sid).cwd || ctx?.worktree || ctx?.directory || process.cwd());
    const raw = String(rawPlanPath);
    const relativeInput = path.isAbsolute(raw)
      ? path.relative(root, path.resolve(raw))
      : raw;
    const candidate = path.resolve(root, relativeInput);
    const relative = path.relative(root, candidate);
    if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) return null;
    return candidate;
  };

  const readPlanFile = (planFilePath) => {
    const stat = fs.statSync(planFilePath);
    if (!stat.isFile()) return null;
    const fd = fs.openSync(planFilePath, "r");
    try {
      const length = Math.min(stat.size, MAX_PLAN_BYTES);
      const buffer = Buffer.alloc(length);
      const bytes = fs.readSync(fd, buffer, 0, length, 0);
      const text = buffer.subarray(0, bytes).toString("utf8");
      if (stat.size <= bytes) return text;
      return `${text}\n\n[cmux truncated plan file at ${bytes} bytes.]`;
    } finally {
      fs.closeSync(fd);
    }
  };

  const planExitInfo = (sid, questions) => {
    const first = Array.isArray(questions) ? questions[0] : null;
    if (!first) return null;
    const prompt = firstString(first.question, first.prompt) || "";
    const header = firstString(first.header, first.title) || "";
    const labels = Array.isArray(first.options)
      ? first.options.map((option) => firstString(option?.label, option?.title, option)).filter(Boolean)
      : [];
    const looksLikePlanExit =
      header === "Build Agent" ||
      /Plan at .+ is complete\./.test(prompt) ||
      (labels.includes("Yes") && labels.includes("No") && /switch to the build agent/i.test(prompt));
    if (!looksLikePlanExit) return null;

    const match = prompt.match(/Plan at (.+?) is complete\./);
    const rawPlanPath = match?.[1]?.trim();
    const planFilePath = resolveSessionPlanPath(sid, rawPlanPath);
    let plan = null;
    if (planFilePath) {
      try {
        plan = readPlanFile(planFilePath);
      } catch (_) {}
    }
    return {
      sid,
      question: prompt,
      plan: plan || prompt || "OpenCode plan is ready for review.",
      planFilePath,
    };
  };

  const handleExitPlanDecision = async (sid, requestId, decision) => {
    const mode = decision?.mode || "manual";
    const feedback = normalizeText(decision?.feedback, 1800);

    if (feedback) {
      await replyQuestion(requestId, [["No"]]);
      await sendPlanFeedback(
        sid,
        `User rejected the plan via cmux Feed and wants this change: ${feedback}\n\nUpdate the plan file, then call plan_exit again.`
      );
      return;
    }

    if (mode === "deny") {
      await replyQuestion(requestId, [["No"]]);
      return;
    }

    if (mode === "ultraplan") {
      await replyQuestion(requestId, [["No"]]);
      await sendPlanFeedback(
        sid,
        "User chose Ultraplan via cmux Feed. Refine the plan more deeply, update the plan file, then call plan_exit again."
      );
      return;
    }

    const rules = permissionRulesForExitPlanMode(mode);
    let permissionsApplied = true;
    try {
      permissionsApplied = await updateSessionPermission(sid, rules);
    } catch (_) {
      permissionsApplied = false;
    }
    if (!permissionsApplied) {
      await replyQuestion(requestId, [["No"]]);
      await sendPlanFeedback(
        sid,
        "cmux could not apply the selected permission mode. Ask the user to approve the plan again before switching to build mode."
      );
      return;
    }
    await replyQuestion(requestId, [["Yes"]]);
  };

  const resolvePending = (requestId, value) => {
    if (!requestId) return;
    const map = pending.has(requestId)
      ? pending
      : blockingPending.has(requestId)
        ? blockingPending
        : null;
    if (!map) return;
    const resolver = map.get(requestId);
    map.delete(requestId);
    resolver(value);
  };

  // Shared-connection teardown fails the RPCs that ride it. Blocking
  // pushes are deliberately spared: they park on dedicated connections
  // and must survive shared-connection churn (the app's idle reaper
  // closes a quiet shared connection in ~30s while a 120s decision wait
  // is still legitimately parked).
  const failPending = () => {
    for (const requestId of pending.keys()) {
      resolvePending(requestId, { status: "timed_out" });
    }
    buffered = "";
  };

  const connect = () => {
    try {
      const conn = net.createConnection(socketPath || DEFAULT_SOCKET);
      conn.setEncoding("utf8");
      conn.on("data", (chunk) => {
        buffered += chunk;
        let idx;
        while ((idx = buffered.indexOf("\n")) >= 0) {
          const line = buffered.slice(0, idx);
          buffered = buffered.slice(idx + 1);
          if (!line) continue;
          try {
            const msg = JSON.parse(line);
            // The socket sends either V2 responses (id/ok/result/error)
            // or push frames keyed by request_id. For responses the echoed
            // frame id is authoritative; request_id keys only route
            // app-initiated frames (whose ids are app-minted).
            const responseId =
              typeof msg?.id === "string" && msg.id.startsWith("opencode-")
                ? msg.id.slice("opencode-".length)
                : null;
            const requestId = responseId || msg?.result?.request_id || msg?.request_id;
            resolvePending(requestId, msg.result || msg);
          } catch (e) {
            // swallow - malformed line, keep the connection alive.
          }
        }
      });
      // A dropped socket usually means the cmux app restarted. Mirror
      // workspace/surface ids are minted per attach, so the cached pane
      // resolution is stale the moment the connection dies: forget it and
      // re-resolve against the new app instance. Identity is re-read from
      // tmux too: a replacement cmux may pin a new socket.
      //
      // 'end' is handled EXACTLY like 'close': an app-side shutdown can
      // deliver only the FIN, leaving this side half-open — writable into
      // the void, no 'close', no 'error' — so nothing would ever trigger
      // recovery (the restart-loses-running-dot bug). Destroying our side
      // on FIN completes the pair; the teardown itself runs once.
      let disconnectHandled = false;
      const handleDisconnect = (reason) => {
        if (client === conn) client = null;
        conn.destroy();
        if (disconnectHandled) return;
        disconnectHandled = true;
        feedDebugLog("socket disconnected:", reason);
        remoteTarget = null;
        // remoteResolvePromise is deliberately NOT cleared here: it only
        // ever holds an IN-FLIGHT cycle (the cycle clears it on both
        // outcomes), and that cycle's remaining attempts already retry
        // against fresh connections. Clearing mid-flight let every
        // disconnect mint one more concurrent cycle, each repainting on
        // success (duplicate lifecycle lines, duplicate resolve RPCs).
        identityPromise = null;
        failPending();
        noteDisconnected();
      };
      conn.on("end", () => handleDisconnect("end"));
      conn.on("close", () => handleDisconnect("close"));
      conn.on("error", (error) => {
        handleDisconnect(error?.code || error?.message || String(error));
      });
      return conn;
    } catch (e) {
      failPending();
      return null;
    }
  };

  const write = (frame) => {
    if (!client) client = connect();
    if (!client) return false;
    try {
      client.write(JSON.stringify(frame) + "\n");
      return true;
    } catch (e) {
      failPending();
      return false;
    }
  };

  // Raw V1 line on the same connection. The socket dispatches per line
  // (JSON frame -> V2, anything else -> V1 text command), and the data
  // handler above ignores non-JSON replies like "OK", so V1 and V2 mix
  // safely on one connection.
  const writeLine = (line) => {
    if (!client) client = connect();
    if (!client) return false;
    try {
      client.write(line + "\n");
      return true;
    } catch (e) {
      failPending();
      return false;
    }
  };

  // Keeps the shared connection out of the app's idle reaper and probes
  // half-open sockets. Runs for the plugin's whole life; write errors
  // surface through the socket's own error event. While any session is
  // busy it also refreshes the deduped "running" lifecycle line, so an
  // app-side clear (the shell-clear safety net firing on a suspended
  // agent) heals within one keepalive instead of waiting for a busy edge.
  const keepaliveTimer = setInterval(() => {
    if (!client) return;
    try {
      client.write("\n");
    } catch (_) {}
    if (
      lastLifecycleSent === "running"
      && remoteTarget
      && [...sessions.values()].some((state) => state.confirmedLocal && state.isBusy)
    ) {
      writeLine(
        `set_agent_lifecycle opencode running --tab=${remoteTarget.workspaceId} --panel=${remoteTarget.surfaceId}`
      );
    }
  }, KEEPALIVE_INTERVAL_MS);
  if (typeof keepaliveTimer.unref === "function") keepaliveTimer.unref();

  // V2 request/reply for non-feed verbs, reusing the pending map: replies
  // correlate through the frame id (`opencode-<requestId>`).
  const requestWithReply = (method, params, requestId, timeoutMs) => {
    const reply = new Promise((resolve) => {
      pending.set(requestId, resolve);
      setTimeout(() => {
        if (pending.has(requestId)) {
          pending.delete(requestId);
          resolve({ status: "timed_out" });
        }
      }, timeoutMs);
    });
    const wrote = write({
      id: `opencode-${requestId}`,
      method,
      params,
    });
    if (!wrote) {
      resolvePending(requestId, { status: "timed_out" });
    }
    return reply;
  };

  // Maps this agent's tmux pane to the mirrored workspace/surface UUIDs.
  // Resolved once and cached; retried with backoff because the mirror may
  // still be building panels in the seconds right after attach. A total
  // miss (pane not mirrored, old cmux) leaves events unbound - the feed
  // still works, only sidebar attribution is lost.
  const resolveRemoteTarget = () => {
    if (!isRemote()) return Promise.resolve(null);
    if (remoteTarget) return Promise.resolve(remoteTarget);
    if (!remoteResolvePromise) {
      remoteResolvePromise = (async () => {
        for (let attempt = 0; attempt < REMOTE_RESOLVE_ATTEMPTS; attempt++) {
          if (attempt > 0) {
            await new Promise((resolve) => setTimeout(resolve, 1500 * attempt));
          }
          const result = await requestWithReply(
            "remote.tmux.resolve_pane",
            { host_key: remoteHostKey, pane_id: remotePaneId },
            `resolve-pane-${Date.now()}-${attempt}`,
            REMOTE_RESOLVE_TIMEOUT_MS
          );
          const workspaceId = firstString(result?.workspace_id);
          const surfaceId = firstString(result?.surface_id);
          if (result?.resolved === true && workspaceId && surfaceId) {
            remoteTarget = { workspaceId, surfaceId };
            // Single-flight: the cache only ever holds an in-flight
            // cycle. remoteTarget carries the success from here; a
            // disconnect nulls it and the next caller starts fresh.
            remoteResolvePromise = null;
            afterResolveRecovered(remoteTarget);
            return remoteTarget;
          }
          feedDebugLog(
            "resolve attempt", attempt, "failed:",
            JSON.stringify(result).slice(0, 200)
          );
        }
        remoteResolvePromise = null; // allow a later event to retry
        return null;
      })();
    }
    return remoteResolvePromise;
  };

  // Remote agents self-report lifecycle: there is no local PID for cmux's
  // process watcher, so running/idle comes from opencode's own event bus.
  // A missing target (first event, or invalidated by a socket drop after an
  // app restart) re-resolves asynchronously so the state still lands.
  // A socket drop while a turn is open starts the recovery loop: snapshot
  // the open turns (their completions would otherwise vanish into the dead
  // socket) and retry identity + resolve on a timer, because an agent deep
  // in a long tool call emits no bus events to drive the lazy path.
  const noteDisconnected = () => {
    if (!remotePaneId) return;
    // Turn-completes sent just before the drop may sit in the dead
    // socket's buffer: re-mark them owed so recovery redelivers them
    // (at-least-once; the duplicate window is only entered by an app
    // exit racing a settle).
    const now = Date.now();
    for (const [sid, sentAt] of recentTurnCompleteSends) {
      if (now - sentAt <= TURN_COMPLETE_REDELIVERY_WINDOW_MS) {
        const state = sessions.get(sid);
        if (state && !state.parentId) state.completionOwed = true;
      }
    }
    recentTurnCompleteSends.clear();
    const anythingToRecover = [...sessions.values()].some(
      (state) => (state.confirmedLocal && state.isBusy) || state.completionOwed
    );
    feedDebugLog(
      "disconnected; recover =", anythingToRecover,
      "timer =", reconnectRecoveryTimer != null
    );
    if (!anythingToRecover || reconnectRecoveryTimer) return;
    reconnectRecoveryTimer = setInterval(() => {
      void (async () => {
        feedDebugLog("recovery tick; resolveInFlight =", remoteResolvePromise != null);
        await ensureIdentity();
        if (!isRemote()) return;
        await resolveRemoteTarget();
      })();
    }, RECONNECT_RECOVERY_INTERVAL_MS);
    if (typeof reconnectRecoveryTimer.unref === "function") {
      reconnectRecoveryTimer.unref();
    }
  };

  // Runs on every successful resolve (event-driven or recovery timer):
  // repaint the running state for a turn still in flight, deliver the
  // turn-complete notifications for turns that ENDED while disconnected,
  // and stop the recovery loop.
  const afterResolveRecovered = (target) => {
    feedDebugLog("resolved", target.workspaceId, target.surfaceId);
    if (reconnectRecoveryTimer) {
      clearInterval(reconnectRecoveryTimer);
      reconnectRecoveryTimer = null;
    }
    const busy = [...sessions.values()].some(
      (state) => state.confirmedLocal && state.isBusy
    );
    if (busy) {
      lastLifecycleSent = "running";
      writeLine(
        `set_agent_lifecycle opencode running --tab=${target.workspaceId} --panel=${target.surfaceId}`
      );
    } else {
      // A fresh cmux instance knows nothing about this pane; the next
      // aggregate edge must write even if it matches the pre-drop state.
      lastLifecycleSent = null;
    }
    // Recovery is already seconds late, so owed completions of settled
    // (idle) sessions fire without re-waiting the settle grace. A send
    // that fails again keeps the debt for the next recovery.
    for (const [sid, state] of sessions) {
      if (state.completionOwed && !state.isBusy && !state.parentId) {
        sendRemoteTurnCompleteNotification(sid);
      }
    }
    for (const [requestId, queuedAt] of [...pendingConcludes]) {
      pendingConcludes.delete(requestId);
      // Past the wait timeout the app-side waiter has expired on its
      // own; nothing is left to conclude.
      if (Date.now() - queuedAt > REPLY_TIMEOUT_MS) continue;
      concludeBlockingRequest(requestId, queuedAt);
    }
  };

  // Tells the app a parked blocking decision resolved in the agent's own
  // UI. Confirmed request/reply: a conclude lost to a dead socket leaves
  // "needs input" stuck until wait-timeout expiry, so unconfirmed sends
  // stay queued and are redelivered after the next successful resolve
  // (feed.conclude is idempotent app-side).
  const concludeBlockingRequest = (requestId, queuedAt = Date.now()) => {
    pendingConcludes.set(requestId, queuedAt);
    void requestWithReply(
      "feed.conclude",
      { request_id: requestId },
      `conclude-${requestId}-${Date.now()}`,
      5_000
    ).then((result) => {
      if (result?.status !== "timed_out") pendingConcludes.delete(requestId);
    });
  };

  const sendRemoteLifecycle = (state) => {
    if (!isRemote()) return;
    if (state === "idle") clearActivityStatus();
    if (state === "running" && idleGraceTimer) {
      // A parked idle write must never land on top of a fresher running
      // one (the timer's own busy re-check covers tracked sessions, but
      // direct writers like the sid-less prompt fallback bypass them).
      clearTimeout(idleGraceTimer);
      idleGraceTimer = null;
    }
    lastLifecycleSent = state;
    if (!remoteTarget) {
      void resolveRemoteTarget().then((target) => {
        if (!target) return;
        writeLine(
          `set_agent_lifecycle opencode ${state} --tab=${target.workspaceId} --panel=${target.surfaceId}`
        );
      });
      return;
    }
    writeLine(
      `set_agent_lifecycle opencode ${state} --tab=${remoteTarget.workspaceId} --panel=${remoteTarget.surfaceId}`
    );
  };

  // One-line "what is the agent doing right now" for the sidebar row.
  // Derived from tool parts (concrete: the tool and its target); the pane
  // shares one slot across every session in this process, so the newest
  // running tool wins. The wire value must never smuggle a flag token.
  const activityTextFromPart = (part) => {
    if (!part || part.type !== "tool") return null;
    const state = isObject(part.state) ? part.state : {};
    if (state.status !== "running" && state.status !== "pending") return null;
    const toolName = firstString(part.tool) || "tool";
    const input = isObject(state.input) ? state.input : {};
    const detail = firstString(
      state.title,
      input.description,
      input.command,
      input.filePath,
      input.path,
      input.pattern,
      input.url,
      input.prompt
    );
    const raw = detail ? `${toolName}: ${detail}` : toolName;
    const normalized = normalizeText(raw, ACTIVITY_TEXT_MAX);
    if (!normalized) return null;
    return normalized.replace(/--/g, "-");
  };

  const writeActivityStatus = (text) => {
    if (!isRemote() || !remoteTarget) return;
    lastActivitySentText = text;
    lastActivitySentAt = Date.now();
    writeLine(
      `set_status ${ACTIVITY_STATUS_KEY} ${text} --priority=-1 ` +
        `--tab=${remoteTarget.workspaceId} --panel=${remoteTarget.surfaceId}`
    );
  };

  // Throttled with a trailing flush: the first update in a quiet window
  // lands immediately, later ones coalesce to the newest text at the
  // interval boundary. Identical text never re-sends (the app-side write
  // dedupe would drop it anyway; skipping saves the socket line).
  const noteActivity = (text) => {
    if (!text || !isRemote()) return;
    pendingActivityText = text;
    if (activityFlushTimer) return;
    const sinceLastSend = Date.now() - lastActivitySentAt;
    if (sinceLastSend >= ACTIVITY_STATUS_INTERVAL_MS) {
      if (pendingActivityText !== lastActivitySentText) {
        writeActivityStatus(pendingActivityText);
      }
      return;
    }
    activityFlushTimer = setTimeout(() => {
      activityFlushTimer = null;
      if (pendingActivityText && pendingActivityText !== lastActivitySentText) {
        writeActivityStatus(pendingActivityText);
      }
    }, ACTIVITY_STATUS_INTERVAL_MS - sinceLastSend);
    if (typeof activityFlushTimer.unref === "function") activityFlushTimer.unref();
  };

  // Drops the row's activity line. Runs when the pane settles idle and
  // when a blocking decision parks (the needs-input line takes over); a
  // no-op while nothing was ever sent.
  const clearActivityStatus = () => {
    if (activityFlushTimer) {
      clearTimeout(activityFlushTimer);
      activityFlushTimer = null;
    }
    pendingActivityText = null;
    if (lastActivitySentText === null) return;
    lastActivitySentText = null;
    lastActivitySentAt = 0;
    if (!isRemote() || !remoteTarget) return;
    writeLine(
      `clear_status ${ACTIVITY_STATUS_KEY} --tab=${remoteTarget.workspaceId}`
    );
  };

  // The pane's lifecycle entry is ONE slot shared by every session in this
  // opencode process (the lead + all its subagents). Per-session busy/idle
  // events must therefore aggregate: the slot is "running" while ANY
  // session is busy and "idle" only when NONE is. Writing per-event
  // (last-writer-wins) made a lead running a swarm flicker running/idle on
  // every worker turn boundary. Deduped: only edges write; reconnects
  // reset the dedup so a fresh cmux always gets repainted. The idle edge
  // additionally waits out a grace window (goal loops re-prompt moments
  // after idling; the strobe served no one) and is cancelled by busy
  // returning first.
  const updateAggregateLifecycle = () => {
    // Only sessions PROVEN to run in this process count: a mirrored
    // sibling's busy edge (whose idle never crosses) would otherwise pin
    // every same-folder pane to "running" forever.
    const desired = [...sessions.values()].some(
      (state) => state.confirmedLocal && state.isBusy
    )
      ? "running"
      : "idle";
    if (desired === "running") {
      if (idleGraceTimer) {
        clearTimeout(idleGraceTimer);
        idleGraceTimer = null;
      }
      if (lastLifecycleSent !== "running") sendRemoteLifecycle("running");
      return;
    }
    if (lastLifecycleSent === "idle" || idleGraceTimer) return;
    idleGraceTimer = setTimeout(() => {
      idleGraceTimer = null;
      const stillIdle = ![...sessions.values()].some(
        (state) => state.confirmedLocal && state.isBusy
      );
      if (stillIdle && lastLifecycleSent !== "idle") sendRemoteLifecycle("idle");
    }, IDLE_LIFECYCLE_GRACE_MS);
    if (typeof idleGraceTimer.unref === "function") idleGraceTimer.unref();
  };

  // The wire payload is |-separated; fields must never smuggle a separator.
  const sanitizeNotifyField = (value, max) =>
    (normalizeText(value, max) || "").replace(/\|/g, "/");

  // Remote turn-complete notification, mirroring the local hooks' categorized
  // `notify_target_async` line so the SAME user notification settings gate it
  // (turn complete: always / when idle / never). Local sessions never send
  // this: the locally installed hooks own local notifications, and sending
  // here too would double-notify.
  const sendRemoteTurnCompleteNotification = (sid) => {
    if (!isRemote()) return;
    const state = sessionState(sid);
    // The debt is the send token: every path re-checks it at write time,
    // so a settle firing during downtime (whose deferred resolve races the
    // recovery flush toward the same toast) can never deliver twice.
    if (!state.completionOwed) return;
    const subtitle = sanitizeNotifyField(state.lastUserMessage, 120);
    const body = sanitizeNotifyField(state.assistantPreamble, 160) || "Finished a turn";
    const send = (target) => {
      if (!state.completionOwed) return;
      recentTurnCompleteSends.set(sid, Date.now());
      const wrote = writeLine(
        `notify_target_async ${target.workspaceId} ${target.surfaceId} ` +
          `OpenCode|${subtitle}|${body}|c=turn-complete;p=0`
      );
      // The debt clears only when the line actually left: a write into a
      // dead socket keeps it owed for the recovery flush.
      if (wrote) state.completionOwed = false;
    };
    if (!remoteTarget) {
      void resolveRemoteTarget().then((target) => {
        if (target) send(target);
      });
      return;
    }
    send(remoteTarget);
  };

  // One settle timer per session: the notification fires only when the
  // session stays idle for the whole grace (busy returning cancels it and
  // the debt carries to the next idle). This is what turns "a goal loop
  // iterated 40 times" into ONE toast at the end instead of 40.
  const armCompletionSettle = (sid, state) => {
    if (state.settleTimer) clearTimeout(state.settleTimer);
    state.settleTimer = setTimeout(() => {
      state.settleTimer = null;
      if (!sessions.has(sid) || state.isBusy || !state.completionOwed) return;
      sendRemoteTurnCompleteNotification(sid);
    }, TURN_SETTLE_GRACE_MS);
    if (typeof state.settleTimer.unref === "function") state.settleTimer.unref();
  };

  // Turn-boundary tracker shared by "session.status" (current builds) and the
  // deprecated "session.idle" (older builds, co-published on current ones).
  // A turn OPENS only on a real typed user prompt and completes on the next
  // idle, so the co-published pair cannot double-fire — and background busy
  // cycles (auto-compaction, cache keepalive) update the running/idle
  // spinner without minting spurious "finished a turn" notifications.
  // Subagent sessions never open turns: their prompts are engine
  // deliveries, and a swarm's workers finishing would otherwise spam
  // green unseen-done flashes while the lead is still mid-goal.
  const noteSessionBusyState = (sid, busy, opensTurn = false) => {
    const state = sessionState(sid);
    feedDebugLog("busyState", sid, "busy =", busy, "opensTurn =", opensTurn);
    if (busy) {
      state.isBusy = true;
      // Busy returning inside the settle grace is a goal loop (or queued
      // follow-up) continuing: hold the debt, cancel the pending toast.
      if (state.settleTimer) {
        clearTimeout(state.settleTimer);
        state.settleTimer = null;
      }
      if (opensTurn && !state.parentId) state.turnOpen = true;
      updateAggregateLifecycle();
      return;
    }
    const hadOpenTurn = state.turnOpen === true;
    state.isBusy = false;
    state.turnOpen = false;
    updateAggregateLifecycle();
    if (hadOpenTurn && !state.parentId) state.completionOwed = true;
    if (state.completionOwed && !state.parentId) armCompletionSettle(sid, state);
  };

  const base = (sessionId, extra) => {
    const state = sessionState(sessionId);
    const context = extra?.context || contextForSession(sessionId);
    const workspaceId =
      typeof process.env.CMUX_WORKSPACE_ID === "string" && process.env.CMUX_WORKSPACE_ID.trim()
        ? process.env.CMUX_WORKSPACE_ID.trim()
        : null;
    const event = {
      session_id: `opencode-${sessionId}`,
      _source: "opencode",
      cwd: extra?.cwd || state.cwd || ctx?.directory,
      ...extra,
    };
    if (isRemote()) {
      // PID quarantine: never send a remote PID - the local cmux would
      // watch (or signal) an unrelated local process with that id.
      if (remoteTarget) {
        event.workspace_id = remoteTarget.workspaceId;
        event.surface_id = remoteTarget.surfaceId;
      } else {
        feedDebugLog(
          "frame without workspace binding:", extra?.hook_event_name || "?"
        );
      }
    } else {
      event._ppid = process.pid;
      if (workspaceId) event.workspace_id = workspaceId;
    }
    if (context) event.context = context;
    return event;
  };

  const trackMessage = (event) => {
    const props = event.properties || {};
    if (event.type === "message.updated") {
      const info = props.info || props.message || {};
      const messageId = info.id || props.messageID;
      const sessionId = info.sessionID || props.sessionID;
      const role = info.role || props.role;
      if (messageId && sessionId && role) {
        messageRoles.set(messageId, { sessionId, role });
        if (messageRoles.size > 300) {
          messageRoles.delete(messageRoles.keys().next().value);
        }
      }
      return null;
    }

    if (event.type !== "message.part.updated") return null;
    const part = props.part || {};
    if (part.type !== "text" || !part.messageID) return null;
    const meta = messageRoles.get(part.messageID);
    if (!meta) return null;
    const text = normalizeText(part.text || part.textDelta || part.content);
    if (!text) return null;
    const state = sessionState(meta.sessionId);
    if (meta.role === "user") {
      // Engine-authored parts carry `synthetic: true`: goal-loop
      // continuation nudges, subagent reports delivered to the lead,
      // watch/schedule cards, task prompts fanned out to workers, and
      // scaffolding attached to real prompts. None of them is the user
      // typing, so none may open a turn — counting them made every goal
      // iteration and every worker report mint a "finished a turn"
      // green flash plus a notification while the agent was still
      // working. Only a really typed part is a user turn (the same rule
      // the TUI uses to tell deliveries from prompts).
      if (part.synthetic === true) return null;
      state.lastUserMessage = text;
      // Streaming re-delivers the same part as it grows; one prompt is
      // one turn, so later updates of a message already counted only
      // refresh the notification subtitle above.
      if (promptedMessageIds.has(part.messageID)) return null;
      promptedMessageIds.add(part.messageID);
      if (promptedMessageIds.size > 300) {
        promptedMessageIds.delete(promptedMessageIds.keys().next().value);
      }
      const frame = base(meta.sessionId, {
        hook_event_name: "UserPromptSubmit",
        tool_input: { prompt: text },
        context: { lastUserMessage: text },
      });
      // Message parts mirror across same-folder processes; a sibling
      // pane's typed prompt must not open a turn here or paint this
      // pane's row with the sibling's text. Queue the prompt work until
      // this session proves local (first streaming delta confirms it,
      // seconds at most), then it flushes with the turn debt intact.
      if (!state.confirmedLocal) {
        state.pendingPromptOpensTurn = true;
        queueTelemetryUntilConfirmed(meta.sessionId, frame);
        return null;
      }
      return frame;
    }
    if (meta.role === "assistant") {
      state.assistantPreamble = text;
    }
    return null;
  };

  // The app serves each socket connection strictly line-by-line, so a
  // parked blocking push would head-of-line block every later frame on
  // the shared connection (lifecycle, telemetry, pane resolves, missed
  // turn-completes, and the out-of-band feed.conclude that ENDS the very
  // block) for the full wait timeout. Observed live: "needs input" stuck
  // after answering in the agent's own UI, resolves timing out behind a
  // parked permission, finish notifications delayed two minutes. Blocking
  // pushes therefore ride a DEDICATED connection each; the shared one
  // stays fluid.
  const pushBlocking = async (event, requestId) => {
    // Bind late: a disconnect between frame build and write nulls
    // remoteTarget, and an unbound blocking frame reaches the app as
    // unattributable (attention skipped, "needs input" stuck on the
    // wrong panel). The resolve promise is cached, so this is free on
    // the hot path.
    if (isRemote() && !event.workspace_id) {
      const target = await resolveRemoteTarget();
      if (target) {
        event.workspace_id = target.workspaceId;
        event.surface_id = target.surfaceId;
      }
    }
    // The row's needs-input line takes over while the decision parks; a
    // stale "running tool" line under it would read as still working.
    clearActivityStatus();
    const reply = new Promise((resolve) => {
      blockingPending.set(requestId, resolve);
      setTimeout(() => {
        if (blockingPending.has(requestId)) {
          blockingPending.delete(requestId);
          resolve({ status: "timed_out" });
        }
      }, REPLY_TIMEOUT_MS);
    });
    let conn = null;
    try {
      conn = net.createConnection(socketPath || DEFAULT_SOCKET);
      conn.setEncoding("utf8");
      let lineBuffer = "";
      conn.on("data", (chunk) => {
        lineBuffer += chunk;
        let index;
        while ((index = lineBuffer.indexOf("\n")) >= 0) {
          const line = lineBuffer.slice(0, index);
          lineBuffer = lineBuffer.slice(index + 1);
          if (!line) continue;
          try {
            const msg = JSON.parse(line);
            const responseId =
              typeof msg?.id === "string" && msg.id.startsWith("opencode-")
                ? msg.id.slice("opencode-".length)
                : null;
            resolvePending(
              responseId || msg?.result?.request_id || msg?.request_id,
              msg.result || msg
            );
          } catch (_) {
            // Non-JSON replies (V1 "OK") are irrelevant here.
          }
        }
      });
      // This connection dying means the wait itself is dead (app
      // restart or reap); a settled push already emptied its map entry,
      // so the late 'close' from our own destroy() is a no-op.
      const settleDead = () => resolvePending(requestId, { status: "timed_out" });
      conn.on("error", settleDead);
      conn.on("end", settleDead);
      conn.on("close", settleDead);
      conn.write(JSON.stringify({
        id: `opencode-${requestId}`,
        method: "feed.push",
        params: { event, wait_timeout_seconds: REPLY_TIMEOUT_MS / 1000 },
      }) + "\n");
    } catch (_) {
      resolvePending(requestId, { status: "timed_out" });
    }
    return reply.then((value) => {
      if (conn) conn.destroy();
      return value;
    });
  };

  const pushTelemetry = (event) => {
    write({
      id: `opencode-telemetry-${Date.now()}`,
      method: "feed.push",
      params: { event, wait_timeout_seconds: 0 },
    });
  };

  return {
    event: async ({ event }) => {
      await ensureIdentity();
      if (isRemote()) await resolveRemoteTarget();
      if (event.type === "message.part.delta") {
        // Streaming deltas exist only in the process that runs the
        // session: the cheapest and earliest ownership proof.
        const deltaSid = firstString(event.properties?.sessionID);
        if (deltaSid) confirmSessionLocal(deltaSid);
      }
      if (event.type === "message.part.updated") {
        const part = event.properties?.part;
        const partSid = firstString(part?.sessionID);
        if (partSid && sessionState(partSid).confirmedLocal) {
          const activity = activityTextFromPart(part);
          if (activity) noteActivity(activity);
        }
      }
      const tracked = trackMessage(event);
      if (tracked) {
        if (tracked.hook_event_name === "UserPromptSubmit") {
          const sid =
            typeof tracked.session_id === "string" && tracked.session_id.startsWith("opencode-")
              ? tracked.session_id.slice("opencode-".length)
              : null;
          if (sid) {
            noteSessionBusyState(sid, true, true);
          } else {
            sendRemoteLifecycle("running");
          }
        }
        pushTelemetry(tracked);
        return;
      }
      switch (event.type) {
        case "session.created": {
          const info = event.properties?.info || {};
          const sid = info.id || "unknown";
          const state = sessionState(sid);
          state.cwd = info.directory || ctx?.directory || state.cwd;
          if (typeof info.parentID === "string" && info.parentID) {
            state.parentId = info.parentID;
          }
          // Workers run inside their lead's process: a confirmed parent
          // confirms the child. A mirrored sibling's session (its parent
          // is unknown here) stays quarantined.
          if (state.parentId && sessions.get(state.parentId)?.confirmedLocal) {
            confirmSessionLocal(sid);
          }
          // Creation is not busyness: a freshly opened session idles until
          // its first prompt, and a spawned worker's busy arrives as its
          // own session.status. The old unconditional "running" here
          // painted the spinner for idle sessions and re-wrote the slot on
          // every worker spawn.
          updateAggregateLifecycle();
          queueTelemetryUntilConfirmed(sid, base(sid, {
            hook_event_name: "SessionStart",
            cwd: state.cwd,
          }));
          pruneUnconfirmedSessions();
          break;
        }
        case "session.idle": {
          const sid = event.properties?.sessionID;
          if (!sid) break;
          // Idle edges never mirror across processes: proof of ownership.
          confirmSessionLocal(sid);
          noteSessionBusyState(sid, false);
          pushTelemetry(base(sid, {
            hook_event_name: "Stop",
          }));
          break;
        }
        case "session.status": {
          // The authoritative busy/idle stream on current opencode builds
          // ("session.idle" is deprecated there and can be cut off by
          // process exit in one-shot runs). Lifecycle + turn boundary only:
          // the Stop feed event still rides "session.idle" so feed
          // semantics are unchanged where both fire. Mirrored siblings
          // deliver BUSY edges (never idle): busy is recorded but only
          // confirmed-local sessions drive the pane's aggregate.
          const sid = event.properties?.sessionID;
          if (!sid) break;
          const status = event.properties?.status;
          const statusType = typeof status === "string" ? status : status?.type;
          if (statusType === "idle") {
            confirmSessionLocal(sid);
            noteSessionBusyState(sid, false);
          } else if (statusType === "busy" || statusType === "retry") {
            noteSessionBusyState(sid, true);
          }
          break;
        }
        case "session.deleted": {
          const sid = event.properties?.info?.id;
          if (!sid) break;
          const wasConfirmed = sessions.get(sid)?.confirmedLocal === true;
          sessions.delete(sid);
          // A deleted worker must not blank the spinner while its lead
          // (or any sibling) is still busy: recompute, don't overwrite.
          updateAggregateLifecycle();
          if (wasConfirmed) {
            pushTelemetry(base(sid, {
              hook_event_name: "SessionEnd",
            }));
          }
          break;
        }
        case "todo.updated": {
          const sid = event.properties?.sessionID;
          if (!sid) break;
          queueTelemetryUntilConfirmed(sid, base(sid, {
            hook_event_name: "TodoWrite",
            tool_input: event.properties?.todos || [],
          }));
          break;
        }
        case "permission.replied":
        case "question.replied":
        case "question.rejected": {
          // The decision resolved in the agent's own UI (or through cmux,
          // in which case this is an idempotent no-op app-side). Conclude
          // the parked blocking item NOW so the sidebar's needs-input state
          // and any banner clear instead of lingering until the reply
          // timeout, and resolve the local waiter with a non-"resolved"
          // status so pushBlocking exits without re-replying to opencode.
          const requestId = firstString(
            event.properties?.requestID,
            event.properties?.requestId
          );
          if (!requestId) break;
          concludeBlockingRequest(requestId);
          resolvePending(requestId, { status: "concluded_externally" });
          break;
        }
        case "permission.asked": {
          const props = event.properties || {};
          const requestId = props.id;
          if (!requestId) break;
          const sid = props.sessionID || "unknown";
          // A blocking ask parks THIS process's tool call: ownership proof.
          confirmSessionLocal(sid);
          const permission = firstString(props.permission, props.tool?.name) || "permission";
          const metadata = isObject(props.metadata) ? props.metadata : {};
          const frame = base(sid, {
            hook_event_name: "PermissionRequest",
            _opencode_request_id: requestId,
            tool_name: permission,
            tool_input: {
              permission,
              patterns: Array.isArray(props.patterns) ? props.patterns : [],
              always: Array.isArray(props.always) ? props.always : [],
              metadata,
              tool: props.tool,
            },
            context: {
              ...(contextForSession(sid) || {}),
              permissionMode: "opencode",
            },
          });
          // Detached on purpose: this event hook must return while the
          // push parks. Serialized bus dispatch otherwise queues every
          // later event behind the wait, including the permission.replied
          // that concludes it, so an in-agent answer could not clear the
          // "needs input" state until wait-timeout expiry.
          void (async () => {
            const result = await pushBlocking(frame, requestId);
            if (result?.status !== "resolved" || result.decision?.kind !== "permission") return;
            const mode = result.decision.mode;
            try {
              await updateSessionPermission(sid, permissionSessionRulesForMode(permission, mode));
            } catch (_) {}
            try {
              await replyPermission({
                sessionId: sid,
                requestId,
                reply: permissionReplyForMode(mode),
                message: mode === "deny" ? "User denied permission via cmux Feed." : undefined,
              });
            } catch (e) { /* ignore - opencode already moved on */ }
          })();
          break;
        }
        case "question.asked": {
          const props = event.properties || {};
          const requestId = props.id;
          const sid = props.sessionID || "unknown";
          if (!requestId) break;
          // A blocking ask parks THIS process's tool call: ownership proof.
          confirmSessionLocal(sid);
          const questions = (props.questions || []).map((q, idx) => ({
            id: q.id || `q${idx}`,
            header: q.header || q.title,
            question: q.question || q.prompt || "",
            multiSelect: q.multiSelect === true || q.multiple === true,
            options: (q.options || []).map((o, optionIdx) => ({
              id: o.id || `opt${optionIdx}`,
              label: o.label || o.title || String(o),
              description: o.description || o.detail,
            })),
          }));
          const planExit = planExitInfo(sid, questions);
          if (planExit) {
            const frame = base(sid, {
              hook_event_name: "ExitPlanMode",
              _opencode_request_id: requestId,
              tool_name: "plan_exit",
              tool_input: {
                plan: planExit.plan,
                planFilePath: planExit.planFilePath,
                question: planExit.question,
              },
              context: {
                ...(contextForSession(sid) || {}),
                permissionMode: "plan",
              },
            });
            // Detached like permission.asked: the hook must not park.
            void (async () => {
              const result = await pushBlocking(frame, requestId);
              if (result?.status !== "resolved" || result.decision?.kind !== "exit_plan") return;
              try {
                await handleExitPlanDecision(sid, requestId, result.decision);
              } catch (_) {}
            })();
            break;
          }

          const frame = base(sid, {
            hook_event_name: "AskUserQuestion",
            _opencode_request_id: requestId,
            tool_name: "question",
            tool_input: { questions },
          });
          // Detached like permission.asked: the hook must not park.
          void (async () => {
            const result = await pushBlocking(frame, requestId);
            if (result?.status !== "resolved" || result.decision?.kind !== "question") return;
            try {
              await replyQuestion(requestId, questionAnswers(result.decision.selections));
            } catch (_) {
              try { await rejectQuestion(requestId); } catch (_) {}
            }
          })();
          break;
        }
        default:
          // Non-Feed-worthy events pass silently to keep the plugin cheap.
          break;
      }
    },
  };
};
