// cmux-feed-plugin-marker v3
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
  const messageRoles = new Map();
  const sessions = new Map();

  // Identity is mutable: tmux-first with process env fallback, refreshed
  // after a socket drop so a new cmux instance's pins are picked up live.
  let socketPath = (process.env.CMUX_SOCKET_PATH || "").trim() || null;
  let remoteHostKey = (process.env.CMUX_REMOTE_HOST_KEY || "").trim() || null;
  const remotePaneId = (process.env.TMUX_PANE || "").trim() || null;
  let identityPromise = null;

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
      });
    }
    return sessions.get(key);
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
    if (!requestId || !pending.has(requestId)) return;
    const resolver = pending.get(requestId);
    pending.delete(requestId);
    resolver(value);
  };

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
            // or push frames keyed by request_id. We only care about
            // results whose result.decision matches a waiter.
            const responseId =
              typeof msg?.id === "string" && msg.id.startsWith("opencode-")
                ? msg.id.slice("opencode-".length)
                : null;
            const requestId = msg?.result?.request_id || msg?.request_id || responseId;
            resolvePending(requestId, msg.result || msg);
          } catch (e) {
            // swallow - malformed line, keep the connection alive.
          }
        }
      });
      conn.on("close", () => {
        client = null;
        // A dropped socket usually means the cmux app restarted. Mirror
        // workspace/surface ids are minted per attach, so the cached pane
        // resolution is stale the moment the connection dies: forget it and
        // re-resolve lazily against the new app instance. Identity is
        // re-read from tmux too: a replacement cmux may pin a new socket.
        remoteTarget = null;
        remoteResolvePromise = null;
        identityPromise = null;
        failPending();
      });
      conn.on("error", () => {
        client = null;
        remoteTarget = null;
        remoteResolvePromise = null;
        identityPromise = null;
        failPending();
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
            // A fresh resolution usually follows a socket drop (cmux
            // restarted mid-turn). Repaint the current state now instead
            // of leaving the sidebar blank until the next busy/idle flip.
            const busy = [...sessions.values()].some((state) => state.isBusy);
            if (busy) {
              writeLine(
                `set_agent_lifecycle opencode running --tab=${workspaceId} --panel=${surfaceId}`
              );
            }
            return remoteTarget;
          }
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
  const sendRemoteLifecycle = (state) => {
    if (!isRemote()) return;
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
    const subtitle = sanitizeNotifyField(state.lastUserMessage, 120);
    const body = sanitizeNotifyField(state.assistantPreamble, 160) || "Finished a turn";
    const send = (target) => {
      writeLine(
        `notify_target_async ${target.workspaceId} ${target.surfaceId} ` +
          `OpenCode|${subtitle}|${body}|c=turn-complete;p=0`
      );
    };
    if (!remoteTarget) {
      void resolveRemoteTarget().then((target) => {
        if (target) send(target);
      });
      return;
    }
    send(remoteTarget);
  };

  // Turn-boundary tracker shared by "session.status" (current builds) and the
  // deprecated "session.idle" (older builds, co-published on current ones).
  // A turn OPENS only on a user prompt and completes on the next idle, so
  // the co-published pair cannot double-fire — and background busy cycles
  // (auto-compaction, cache keepalive) update the running/idle spinner
  // without minting spurious "finished a turn" notifications.
  const noteSessionBusyState = (sid, busy, opensTurn = false) => {
    const state = sessionState(sid);
    if (busy) {
      state.isBusy = true;
      if (opensTurn) state.turnOpen = true;
      sendRemoteLifecycle("running");
      return;
    }
    const hadOpenTurn = state.turnOpen === true;
    state.isBusy = false;
    state.turnOpen = false;
    sendRemoteLifecycle("idle");
    if (hadOpenTurn) sendRemoteTurnCompleteNotification(sid);
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
      state.lastUserMessage = text;
      return base(meta.sessionId, {
        hook_event_name: "UserPromptSubmit",
        tool_input: { prompt: text },
        context: { lastUserMessage: text },
      });
    }
    if (meta.role === "assistant") {
      state.assistantPreamble = text;
    }
    return null;
  };

  const pushBlocking = (event, requestId) => {
    const reply = new Promise((resolve) => {
      pending.set(requestId, resolve);
      setTimeout(() => {
        if (pending.has(requestId)) {
          pending.delete(requestId);
          resolve({ status: "timed_out" });
        }
      }, REPLY_TIMEOUT_MS);
    });
    const wrote = write({
      id: `opencode-${requestId}`,
      method: "feed.push",
      params: { event, wait_timeout_seconds: REPLY_TIMEOUT_MS / 1000 },
    });
    if (!wrote) {
      resolvePending(requestId, { status: "timed_out" });
    }
    return reply;
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
          const state = sessionState(info.id || "unknown");
          state.cwd = info.directory || ctx?.directory || state.cwd;
          sendRemoteLifecycle("running");
          pushTelemetry(base(info.id || "unknown", {
            hook_event_name: "SessionStart",
            cwd: state.cwd,
          }));
          break;
        }
        case "session.idle": {
          const sid = event.properties?.sessionID;
          if (!sid) break;
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
          // semantics are unchanged where both fire.
          const sid = event.properties?.sessionID;
          if (!sid) break;
          const status = event.properties?.status;
          const statusType = typeof status === "string" ? status : status?.type;
          if (statusType === "idle") {
            noteSessionBusyState(sid, false);
          } else if (statusType === "busy" || statusType === "retry") {
            noteSessionBusyState(sid, true);
          }
          break;
        }
        case "session.deleted": {
          const sid = event.properties?.info?.id;
          if (!sid) break;
          sessions.delete(sid);
          sendRemoteLifecycle("idle");
          pushTelemetry(base(sid, {
            hook_event_name: "SessionEnd",
          }));
          break;
        }
        case "todo.updated": {
          const sid = event.properties?.sessionID;
          if (!sid) break;
          pushTelemetry(base(sid, {
            hook_event_name: "TodoWrite",
            tool_input: event.properties?.todos || [],
          }));
          break;
        }
        case "permission.asked": {
          const props = event.properties || {};
          const requestId = props.id;
          if (!requestId) break;
          const sid = props.sessionID || "unknown";
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
          const result = await pushBlocking(frame, requestId);
          if (result?.status === "resolved" && result.decision?.kind === "permission") {
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
          }
          break;
        }
        case "question.asked": {
          const props = event.properties || {};
          const requestId = props.id;
          const sid = props.sessionID || "unknown";
          if (!requestId) break;
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
            const result = await pushBlocking(frame, requestId);
            if (result?.status === "resolved" && result.decision?.kind === "exit_plan") {
              try {
                await handleExitPlanDecision(sid, requestId, result.decision);
              } catch (_) {}
            }
            break;
          }

          const frame = base(sid, {
            hook_event_name: "AskUserQuestion",
            _opencode_request_id: requestId,
            tool_name: "question",
            tool_input: { questions },
          });
          const result = await pushBlocking(frame, requestId);
          if (result?.status === "resolved" && result.decision?.kind === "question") {
            try {
              await replyQuestion(requestId, questionAnswers(result.decision.selections));
            } catch (_) {
              try { await rejectQuestion(requestId); } catch (_) {}
            }
          }
          break;
        }
        default:
          // Non-Feed-worthy events pass silently to keep the plugin cheap.
          break;
      }
    },
  };
};
