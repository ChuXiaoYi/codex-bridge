#!/usr/bin/env node
const DEFAULT_RELAY_URL = "http://127.0.0.1:8788";
const DEFAULT_BRIDGE_URL = "http://127.0.0.1:8787";
const DEFAULT_POLL_WAIT_MS = 25000;
const RECONNECT_DELAY_MS = 1500;

function parseArgs(argv) {
  const options = {
    relayUrl: process.env.RELAY_URL || DEFAULT_RELAY_URL,
    bridgeUrl: process.env.BRIDGE_URL || DEFAULT_BRIDGE_URL,
    relayBridgeToken: process.env.RELAY_BRIDGE_TOKEN || "",
    bridgeToken: process.env.BRIDGE_TOKEN || "",
    pollWaitMs: Number(process.env.RELAY_POLL_WAIT_MS || DEFAULT_POLL_WAIT_MS),
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--relay") options.relayUrl = argv[++index];
    else if (arg === "--bridge") options.bridgeUrl = argv[++index];
    else if (arg === "--relay-bridge-token") options.relayBridgeToken = argv[++index];
    else if (arg === "--bridge-token") options.bridgeToken = argv[++index];
    else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    }
  }

  options.relayUrl = options.relayUrl.replace(/\/+$/, "");
  options.bridgeUrl = options.bridgeUrl.replace(/\/+$/, "");
  if (!Number.isInteger(options.pollWaitMs) || options.pollWaitMs <= 0) {
    throw new Error(`Invalid poll wait: ${options.pollWaitMs}`);
  }
  return options;
}

function printHelp() {
  console.log(`Codex Home Mac Relay Client

Usage:
  node relay-client.mjs --relay http://127.0.0.1:8788 --bridge http://127.0.0.1:8787

Environment:
  RELAY_URL            Relay base URL
  RELAY_BRIDGE_TOKEN   Bearer token shared with the relay bridge endpoints
  BRIDGE_URL           Local Home Mac Bridge base URL
  BRIDGE_TOKEN         Optional bearer token for the local Bridge
  RELAY_POLL_WAIT_MS   Long-poll wait duration
`);
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function authHeaders(token) {
  return token ? { authorization: `Bearer ${token}` } : {};
}

async function parseResponseBody(response) {
  const contentType = response.headers.get("content-type") || "";
  if (contentType.includes("application/json")) return response.json();
  const text = await response.text();
  return text || null;
}

function safeCommandPath(path) {
  if (typeof path !== "string" || !path.startsWith("/")) {
    throw new Error("Relay command path must be absolute");
  }

  const url = new URL(path, "http://relay-command");
  const parts = url.pathname.split("/").filter(Boolean);
  const allowed = url.pathname === "/threads"
    || (parts[0] === "threads" && parts[1] && parts.length === 2)
    || (parts[0] === "threads" && parts[1] && parts[2] === "messages" && parts.length === 3);

  if (!allowed) throw new Error(`Relay command path is not allowed: ${path}`);
  return `${url.pathname}${url.search}`;
}

class RelayClient {
  constructor(options) {
    this.options = options;
    this.stopping = false;
  }

  stop() {
    this.stopping = true;
    this.abortController?.abort();
    this.eventsAbortController?.abort();
  }

  async start() {
    console.log(`Connecting relay ${this.options.relayUrl} to local bridge ${this.options.bridgeUrl}`);
    await Promise.all([
      this.commandLoop(),
      this.forwardEventsLoop(),
    ]);
  }

  async commandLoop() {
    while (!this.stopping) {
      try {
        const command = await this.pollCommand();
        if (!command) continue;
        await this.handleCommand(command);
      } catch (error) {
        if (!this.stopping) {
          console.error(`relay command loop error: ${error.message}`);
          await delay(RECONNECT_DELAY_MS);
        }
      }
    }
  }

  async pollCommand() {
    this.abortController = new AbortController();
    const url = `${this.options.relayUrl}/bridge/commands?waitMs=${encodeURIComponent(this.options.pollWaitMs)}`;
    const response = await fetch(url, {
      headers: authHeaders(this.options.relayBridgeToken),
      signal: this.abortController.signal,
    });

    if (response.status === 204) return null;
    if (!response.ok) {
      throw new Error(`relay poll failed: ${response.status} ${await response.text()}`);
    }

    const body = await response.json();
    return body.command ?? null;
  }

  async handleCommand(command) {
    const result = await this.forwardCommand(command).catch((error) => ({
      status: 502,
      body: {
        error: "bridge_forward_failed",
        message: error.message,
      },
    }));

    const response = await fetch(`${this.options.relayUrl}/bridge/commands/${encodeURIComponent(command.id)}/result`, {
      method: "POST",
      headers: {
        ...authHeaders(this.options.relayBridgeToken),
        "content-type": "application/json",
      },
      body: JSON.stringify(result),
    });

    if (!response.ok) {
      throw new Error(`relay result failed: ${response.status} ${await response.text()}`);
    }
  }

  async forwardCommand(command) {
    const path = safeCommandPath(command.path);
    const headers = {
      ...authHeaders(this.options.bridgeToken),
    };
    let body;

    if (command.method === "POST") {
      headers["content-type"] = "application/json";
      body = JSON.stringify(command.body ?? {});
    }

    const response = await fetch(`${this.options.bridgeUrl}${path}`, {
      method: command.method,
      headers,
      body,
    });

    return {
      status: response.status,
      body: await parseResponseBody(response),
    };
  }

  async forwardEventsLoop() {
    while (!this.stopping) {
      try {
        await this.forwardEventsOnce();
      } catch (error) {
        if (!this.stopping) {
          console.error(`relay event loop error: ${error.message}`);
          await delay(RECONNECT_DELAY_MS);
        }
      }
    }
  }

  async forwardEventsOnce() {
    this.eventsAbortController = new AbortController();
    const response = await fetch(`${this.options.bridgeUrl}/events`, {
      headers: authHeaders(this.options.bridgeToken),
      signal: this.eventsAbortController.signal,
    });

    if (!response.ok || !response.body) {
      throw new Error(`local bridge events failed: ${response.status} ${await response.text()}`);
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    for (;;) {
      const { value, done } = await reader.read();
      if (done) return;
      buffer += decoder.decode(value, { stream: true });

      for (;;) {
        const boundary = buffer.indexOf("\n\n");
        if (boundary === -1) break;
        const frame = buffer.slice(0, boundary);
        buffer = buffer.slice(boundary + 2);
        const event = this.parseSseFrame(frame);
        if (event) await this.postBridgeEvent(event);
      }
    }
  }

  parseSseFrame(frame) {
    const data = frame.split("\n")
      .filter((line) => line.startsWith("data:"))
      .map((line) => line.slice("data:".length).trimStart())
      .join("\n");
    if (!data) return null;
    try {
      return JSON.parse(data);
    } catch {
      return { type: "unparsed_sse_frame", data };
    }
  }

  async postBridgeEvent(event) {
    const response = await fetch(`${this.options.relayUrl}/bridge/events`, {
      method: "POST",
      headers: {
        ...authHeaders(this.options.relayBridgeToken),
        "content-type": "application/json",
      },
      body: JSON.stringify({ event }),
    });

    if (!response.ok) {
      throw new Error(`relay event post failed: ${response.status} ${await response.text()}`);
    }
  }
}

const options = parseArgs(process.argv.slice(2));
const client = new RelayClient(options);

process.on("SIGINT", () => {
  client.stop();
  process.exit(130);
});

process.on("SIGTERM", () => {
  client.stop();
  process.exit(143);
});

client.start().catch((error) => {
  console.error(error);
  process.exit(1);
});
