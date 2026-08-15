// Puppet agent for the attention harness: loads the REAL cmux feed plugin
// (remote mode, real tmux pane, real socket) and replays whatever opencode
// bus events the driver writes to the control FIFO, one JSON event per
// line. The FIFO is consumed with ASYNC streams: a real agent process has
// a live event loop at all times, and the plugin's disconnect handling and
// recovery timer depend on it (a blocking read here would freeze both and
// simulate a bug that doesn't exist).
//
// Env:
//   ATTN_PLUGIN_PATH  absolute path to opencode-plugin.js
//   ATTN_EVENTS_FIFO  absolute path to the control fifo
const fs = require("node:fs");

const pluginPath = process.env.ATTN_PLUGIN_PATH;
const fifoPath = process.env.ATTN_EVENTS_FIFO;
if (!pluginPath || !fifoPath) {
  console.error("puppet: ATTN_PLUGIN_PATH and ATTN_EVENTS_FIFO are required");
  process.exit(2);
}

const mod = await import(pluginPath);
const hooks = await mod.CMUXFeed({ directory: process.cwd() });
console.log("puppet: plugin loaded; awaiting events");

// Events process strictly in order through a promise chain, while the
// event loop stays free for the plugin's sockets and timers.
let queue = Promise.resolve();
const dispatch = (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  queue = queue.then(async () => {
    try {
      const event = JSON.parse(trimmed);
      await hooks.event({ event });
      console.log(
        `puppet[${new Date().toISOString().slice(11, 23)}]: handled`,
        event.type
      );
    } catch (error) {
      console.error("puppet: event failed:", String(error));
    }
  });
};

let carry = "";
const consume = () => {
  const stream = fs.createReadStream(fifoPath, { encoding: "utf8" });
  stream.on("data", (chunk) => {
    carry += chunk;
    let index;
    while ((index = carry.indexOf("\n")) >= 0) {
      dispatch(carry.slice(0, index));
      carry = carry.slice(index + 1);
    }
  });
  stream.on("end", () => {
    dispatch(carry);
    carry = "";
    consume();
  });
  stream.on("error", (error) => {
    console.error("puppet: fifo error:", String(error));
    setTimeout(consume, 500);
  });
};
consume();

// Keep the process alive forever.
setInterval(() => {}, 1 << 30);
