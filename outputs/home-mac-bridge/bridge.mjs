#!/usr/bin/env node
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import http from "node:http";

const DEFAULT_CODEX_PATH = "/Applications/Codex.app/Contents/Resources/codex";
const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 8787;

function parseArgs(argv) {
  const options = {
    codexPath: process.env.CODEX_PATH || DEFAULT_CODEX_PATH,
    host: process.env.BRIDGE_HOST || DEFAULT_HOST,
    port: Number(process.env.BRIDGE_PORT || DEFAULT_PORT),
    token: process.env.BRIDGE_TOKEN || "",
    cwd: process.env.BRIDGE_CWD || process.cwd(),
    debugEvents: process.env.BRIDGE_DEBUG_EVENTS === "1",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--codex") options.codexPath = argv[++index];
    else if (arg === "--host") options.host = argv[++index];
    else if (arg === "--port") options.port = Number(argv[++index]);
    else if (arg === "--token") options.token = argv[++index];
    else if (arg === "--cwd") options.cwd = argv[++index];
    else if (arg === "--debug-events") options.debugEvents = true;
    else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    }
  }

  if (!Number.isInteger(options.port) || options.port <= 0) {
    throw new Error(`Invalid port: ${options.port}`);
  }
  return options;
}

function printHelp() {
  console.log(`Codex Home Mac Bridge

Usage:
  node bridge.mjs [--port 8787] [--host 127.0.0.1] [--token TOKEN] [--cwd PATH]

Environment:
  CODEX_PATH    Path to the Codex CLI bundled inside Codex.app
  BRIDGE_HOST   HTTP bind host, defaults to 127.0.0.1
  BRIDGE_PORT   HTTP bind port, defaults to 8787
  BRIDGE_TOKEN  Optional bearer token for local HTTP requests
  BRIDGE_CWD    Working directory used when starting new threads
  BRIDGE_DEBUG_EVENTS=1 includes stderr and account/token usage events in SSE
`);
}

function jsonResponse(res, status, payload) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "authorization, content-type",
    "access-control-allow-methods": "GET, POST, OPTIONS",
  });
  res.end(body);
}

function notFound(res) {
  jsonResponse(res, 404, { error: "not_found" });
}

function methodNotAllowed(res) {
  jsonResponse(res, 405, { error: "method_not_allowed" });
}

function parseJsonBody(req, maxBytes = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let raw = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      raw += chunk;
      if (Buffer.byteLength(raw) > maxBytes) {
        reject(new Error("request body too large"));
        req.destroy();
      }
    });
    req.on("end", () => {
      if (!raw.trim()) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch (error) {
        reject(new Error(`invalid JSON body: ${error.message}`));
      }
    });
    req.on("error", reject);
  });
}

function compactThread(thread) {
  const preview = typeof thread?.preview === "string" ? thread.preview.trim() : "";
  const previewLimit = 500;
  const previewShort = preview.length > previewLimit ? `${preview.slice(0, previewLimit)}...` : preview;
  const name = typeof thread?.name === "string" ? thread.name.trim() : "";
  return {
    id: thread?.id ?? null,
    sessionId: thread?.sessionId ?? null,
    name: name || preview.split("\n")[0] || "(untitled)",
    preview: previewShort,
    previewTruncated: preview.length > previewLimit,
    cwd: thread?.cwd ?? null,
    source: thread?.source ?? null,
    threadSource: thread?.threadSource ?? null,
    status: thread?.status ?? null,
    modelProvider: thread?.modelProvider ?? null,
    ephemeral: Boolean(thread?.ephemeral),
    createdAt: thread?.createdAt ?? null,
    updatedAt: thread?.updatedAt ?? null,
    turnCount: Array.isArray(thread?.turns) ? thread.turns.length : 0,
  };
}

function compactTurn(turn) {
  return {
    id: turn?.id ?? null,
    status: turn?.status ?? null,
    startedAt: turn?.startedAt ?? null,
    completedAt: turn?.completedAt ?? null,
    itemCount: Array.isArray(turn?.items) ? turn.items.length : 0,
  };
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function isActiveStatus(status) {
  if (typeof status === "string") return status === "active";
  if (!status || typeof status !== "object") return false;
  return status.type === "active" || status.kind === "active";
}

function isInProgressTurn(turn) {
  const status = turn?.status;
  if (typeof status === "string") {
    return status === "inProgress" || status === "in_progress" || status === "running";
  }
  if (status && typeof status === "object") {
    return status.type === "inProgress" || status.type === "in_progress" || status.type === "running";
  }
  return false;
}

function activeTurnIdFromStatus(status) {
  if (!status || typeof status !== "object") return null;
  return nonEmptyString(status.turnId)
    ?? nonEmptyString(status.turn_id)
    ?? nonEmptyString(status.activeTurnId)
    ?? nonEmptyString(status.active_turn_id)
    ?? nonEmptyString(status.turn?.id)
    ?? nonEmptyString(status.activeTurn?.id);
}

function activeTurnIdFromThread(thread) {
  const fromStatus = activeTurnIdFromStatus(thread?.status);
  if (fromStatus) return fromStatus;

  const turns = Array.isArray(thread?.turns) ? thread.turns : [];
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    const turn = turns[index];
    if (isInProgressTurn(turn)) return nonEmptyString(turn.id);
  }
  return null;
}

function extractMismatchedActiveTurnId(error) {
  const pattern = /expected active turn id `[^`]+` but found `([^`]+)`/;
  const candidates = [
    error?.message,
    error?.payload?.message,
    error?.payload?.data?.message,
    error?.payload ? JSON.stringify(error.payload) : null,
  ].filter(Boolean);

  for (const candidate of candidates) {
    const match = pattern.exec(candidate);
    if (match?.[1]) return match[1];
  }
  return null;
}

function isActiveTurnNotSteerable(error) {
  const details = [
    error?.message,
    error?.payload?.message,
    error?.payload?.data?.message,
    error?.payload ? JSON.stringify(error.payload) : null,
  ].filter(Boolean).join("\n");

  return details.includes("active_turn_not_steerable")
    || details.includes("no active turn to steer")
    || details.includes("cannot steer a review turn")
    || details.includes("cannot steer a compact turn");
}

function compactSteerResult(result, fallbackTurnId) {
  const turn = result?.turn ?? null;
  return {
    turnId: nonEmptyString(result?.turnId) ?? nonEmptyString(turn?.id) ?? fallbackTurnId,
    turn: turn ? compactTurn(turn) : null,
  };
}

class CodexAppServer extends EventEmitter {
  constructor({ codexPath, cwd }) {
    super();
    this.codexPath = codexPath;
    this.cwd = cwd;
    this.child = null;
    this.buffer = "";
    this.nextId = 1;
    this.pending = new Map();
    this.initialized = null;
    this.agentTextByTurn = new Map();
  }

  async start() {
    if (this.child) return this.initialized;

    this.child = spawn(this.codexPath, ["app-server", "--stdio"], {
      cwd: this.cwd,
      stdio: ["pipe", "pipe", "pipe"],
    });

    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (chunk) => this.handleStdout(chunk));

    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (chunk) => {
      process.stderr.write(chunk);
      this.emitBridgeEvent({ type: "codex_stderr", chunk });
    });

    this.child.on("exit", (code, signal) => {
      const error = new Error(`codex app-server exited with code=${code} signal=${signal}`);
      for (const pending of this.pending.values()) pending.reject(error);
      this.pending.clear();
      this.emitBridgeEvent({ type: "codex_exit", code, signal });
      this.child = null;
      this.initialized = null;
    });

    this.initialized = await this.request("initialize", {
      clientInfo: {
        name: "codex-home-mac-bridge",
        version: "0.1.0",
        title: "Codex Home Mac Bridge",
      },
      capabilities: { experimentalApi: true },
    });

    this.emitBridgeEvent({ type: "bridge_initialized", result: this.initialized });
    return this.initialized;
  }

  stop() {
    if (!this.child) return;
    this.child.stdin.end();
    this.child.kill("SIGTERM");
  }

  request(method, params = {}, timeoutMs = 30000) {
    if (!this.child) {
      return Promise.reject(new Error("codex app-server is not running"));
    }

    const id = this.nextId++;
    const payload = { jsonrpc: "2.0", id, method, params };

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`request timed out: ${method}`));
      }, timeoutMs);

      this.pending.set(id, {
        method,
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      });

      this.child.stdin.write(JSON.stringify(payload) + "\n");
    });
  }

  handleStdout(chunk) {
    this.buffer += chunk;
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline === -1) break;
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;
      try {
        this.handleMessage(JSON.parse(line));
      } catch (error) {
        this.emitBridgeEvent({ type: "parse_error", error: error.message, line });
      }
    }
  }

  handleMessage(message) {
    if (message.method && message.id !== undefined) {
      this.handleServerRequest(message);
      return;
    }

    if (message.method) {
      this.handleNotification(message);
      return;
    }

    const pending = this.pending.get(message.id);
    if (!pending) return;
    this.pending.delete(message.id);

    if (message.error) {
      const error = new Error(message.error.message || `Codex request failed: ${pending.method}`);
      error.payload = message.error;
      pending.reject(error);
      return;
    }

    pending.resolve(message.result);
  }

  handleServerRequest(message) {
    this.emitBridgeEvent({
      type: "server_request",
      method: message.method,
      params: message.params ?? null,
    });

    this.child.stdin.write(JSON.stringify({
      jsonrpc: "2.0",
      id: message.id,
      error: {
        code: -32601,
        message: `Bridge prototype does not handle server request ${message.method}`,
      },
    }) + "\n");
  }

  handleNotification(message) {
    const event = {
      type: message.method,
      params: message.params ?? {},
      receivedAt: new Date().toISOString(),
    };

    if (message.method === "item/agentMessage/delta") {
      const { turnId, delta = "" } = event.params;
      if (turnId) {
        this.agentTextByTurn.set(turnId, `${this.agentTextByTurn.get(turnId) ?? ""}${delta}`);
      }
    }

    if (message.method === "turn/completed") {
      const turnId = event.params?.turn?.id;
      event.agentText = turnId ? (this.agentTextByTurn.get(turnId) ?? "").trim() : "";
      if (turnId) this.agentTextByTurn.delete(turnId);
    }

    this.emitBridgeEvent(event);
  }

  emitBridgeEvent(event) {
    this.emit("event", event);
  }
}

class HomeMacBridge {
  constructor(options) {
    this.options = options;
    this.codex = new CodexAppServer({
      codexPath: options.codexPath,
      cwd: options.cwd,
    });
    this.startedAt = new Date();
    this.recentEvents = [];
    this.sseClients = new Set();

    this.codex.on("event", (event) => this.broadcast(event));
  }

  async start() {
    await this.codex.start();
    this.server = http.createServer((req, res) => this.handle(req, res));
    await new Promise((resolve) => this.server.listen(this.options.port, this.options.host, resolve));
  }

  stop() {
    this.codex.stop();
    this.server?.close();
    for (const res of this.sseClients) res.end();
  }

  broadcast(event) {
    if (!this.options.debugEvents && this.isDebugOnlyEvent(event)) return;

    const payload = {
      id: randomUUID(),
      ...event,
    };
    this.recentEvents.push(payload);
    if (this.recentEvents.length > 200) this.recentEvents.shift();

    const line = `data: ${JSON.stringify(payload)}\n\n`;
    for (const res of this.sseClients) res.write(line);
  }

  isDebugOnlyEvent(event) {
    return event.type === "codex_stderr"
      || event.type === "account/rateLimits/updated"
      || event.type === "thread/tokenUsage/updated";
  }

  authenticate(req) {
    if (!this.options.token) return true;
    return req.headers.authorization === `Bearer ${this.options.token}`;
  }

  async handle(req, res) {
    res.setHeader("access-control-allow-origin", "*");
    res.setHeader("access-control-allow-headers", "authorization, content-type");
    res.setHeader("access-control-allow-methods", "GET, POST, OPTIONS");

    if (req.method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }

    if (!this.authenticate(req)) {
      jsonResponse(res, 401, { error: "unauthorized" });
      return;
    }

    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
    const parts = url.pathname.split("/").filter(Boolean).map(decodeURIComponent);

    try {
      if (req.method === "GET" && url.pathname === "/health") {
        jsonResponse(res, 200, this.health());
        return;
      }

      if (req.method === "GET" && url.pathname === "/events") {
        this.handleEvents(req, res);
        return;
      }

      if (req.method === "GET" && url.pathname === "/threads") {
        await this.handleListThreads(url, res);
        return;
      }

      if (req.method === "POST" && url.pathname === "/threads") {
        await this.handleCreateThread(req, res);
        return;
      }

      if (parts[0] === "threads" && parts[1] && parts.length === 2) {
        if (req.method !== "GET") {
          methodNotAllowed(res);
          return;
        }
        await this.handleReadThread(parts[1], url, res);
        return;
      }

      if (parts[0] === "threads" && parts[1] && parts[2] === "messages" && parts.length === 3) {
        if (req.method !== "POST") {
          methodNotAllowed(res);
          return;
        }
        await this.handleSendMessage(req, res, parts[1]);
        return;
      }

      notFound(res);
    } catch (error) {
      jsonResponse(res, 500, {
        error: "bridge_error",
        message: error.message,
        codex: error.payload ?? null,
      });
    }
  }

  health() {
    return {
      ok: true,
      startedAt: this.startedAt.toISOString(),
      uptimeSeconds: Math.round(process.uptime()),
      codexUserAgent: this.codex.initialized?.userAgent ?? null,
      codexHome: this.codex.initialized?.codexHome ?? null,
      host: this.options.host,
      port: this.options.port,
      tokenRequired: Boolean(this.options.token),
    };
  }

  handleEvents(req, res) {
    req.socket.setTimeout(0);
    res.writeHead(200, {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache, no-transform",
      connection: "keep-alive",
      "access-control-allow-origin": "*",
    });
    res.write(`data: ${JSON.stringify({ type: "bridge_connected", recentEvents: this.recentEvents })}\n\n`);
    this.sseClients.add(res);
    req.on("close", () => {
      this.sseClients.delete(res);
    });
  }

  async handleListThreads(url, res) {
    const limit = Number(url.searchParams.get("limit") || 20);
    const archivedParam = url.searchParams.get("archived");
    const archived = archivedParam == null ? false : archivedParam === "true";
    const searchTerm = url.searchParams.get("search") || null;

    const result = await this.codex.request("thread/list", {
      archived,
      limit,
      searchTerm,
      sortKey: "updated_at",
      sortDirection: "desc",
      useStateDbOnly: true,
      sourceKinds: [],
    });

    jsonResponse(res, 200, {
      data: (result.data ?? []).map(compactThread),
      nextCursor: result.nextCursor ?? null,
      backwardsCursor: result.backwardsCursor ?? null,
    });
  }

  async handleReadThread(threadId, url, res) {
    const includeTurns = url.searchParams.get("includeTurns") === "true";
    const result = await this.codex.request("thread/read", { threadId, includeTurns });
    jsonResponse(res, 200, { thread: compactThread(result.thread) });
  }

  async handleCreateThread(req, res) {
    const body = await parseJsonBody(req);
    const text = typeof body.text === "string" ? body.text.trim() : "";

    const startResult = await this.codex.request("thread/start", {
      cwd: body.cwd || this.options.cwd,
      ephemeral: body.ephemeral === true,
      sandbox: body.sandbox || "read-only",
      approvalPolicy: body.approvalPolicy || "never",
      model: body.model || undefined,
      modelProvider: body.modelProvider || undefined,
      threadSource: body.threadSource || "home-mac-bridge",
    });

    const threadId = startResult.thread?.id;
    if (!text) {
      jsonResponse(res, 201, {
        thread: compactThread(startResult.thread),
        status: "created",
      });
      return;
    }

    const turnResult = await this.codex.request("turn/start", {
      threadId,
      clientUserMessageId: body.clientUserMessageId || randomUUID(),
      input: [{ type: "text", text }],
      approvalPolicy: body.approvalPolicy || "never",
      sandboxPolicy: body.sandboxPolicy || undefined,
      model: body.model || undefined,
      effort: body.effort || undefined,
    });

    jsonResponse(res, 202, {
      thread: compactThread(startResult.thread),
      turn: compactTurn(turnResult.turn),
      status: "accepted",
    });
  }

  async getActiveTurnId(threadId, thread) {
    const fromThread = activeTurnIdFromThread(thread);
    if (fromThread) return fromThread;

    const result = await this.codex.request("thread/read", {
      threadId,
      includeTurns: true,
    });
    return activeTurnIdFromThread(result.thread);
  }

  async steerActiveTurn({ threadId, text, body, clientUserMessageId, expectedTurnId }) {
    const metadata = body.responsesapiClientMetadata && typeof body.responsesapiClientMetadata === "object"
      ? body.responsesapiClientMetadata
      : {};
    const params = {
      threadId,
      clientUserMessageId,
      input: [{ type: "text", text }],
      expectedTurnId,
      responsesapiClientMetadata: {
        source: "home-mac-bridge",
        ...metadata,
      },
    };

    try {
      const result = await this.codex.request("turn/steer", params);
      return { result, expectedTurnId, retried: false };
    } catch (error) {
      const nextTurnId = extractMismatchedActiveTurnId(error);
      if (!nextTurnId || nextTurnId === expectedTurnId) throw error;

      const result = await this.codex.request("turn/steer", {
        ...params,
        expectedTurnId: nextTurnId,
      });
      return { result, expectedTurnId: nextTurnId, retried: true };
    }
  }

  async handleSendMessage(req, res, threadId) {
    const body = await parseJsonBody(req);
    const text = typeof body.text === "string" ? body.text.trim() : "";
    if (!text) {
      jsonResponse(res, 400, { error: "missing_text" });
      return;
    }

    const resumed = await this.codex.request("thread/resume", {
      threadId,
      excludeTurns: true,
    });
    const status = resumed.thread?.status ?? null;
    const clientUserMessageId = body.clientUserMessageId || randomUUID();

    if (isActiveStatus(status)) {
      const expectedTurnId = await this.getActiveTurnId(threadId, resumed.thread);
      if (!expectedTurnId) {
        jsonResponse(res, 409, {
          error: "missing_active_turn_id",
          message: "Thread is active, but Bridge could not find the active turn id.",
          status,
        });
        return;
      }

      try {
        const steer = await this.steerActiveTurn({
          threadId,
          text,
          body,
          clientUserMessageId,
          expectedTurnId,
        });
        const compact = compactSteerResult(steer.result, steer.expectedTurnId);
        jsonResponse(res, 202, {
          threadId,
          clientUserMessageId,
          expectedTurnId: steer.expectedTurnId,
          retried: steer.retried,
          ...compact,
          status: "steered",
        });
      } catch (error) {
        if (isActiveTurnNotSteerable(error)) {
          jsonResponse(res, 409, {
            error: "turn_not_steerable",
            message: error.message,
            status,
            codex: error.payload ?? null,
          });
          return;
        }
        throw error;
      }
      return;
    }

    const result = await this.codex.request("turn/start", {
      threadId,
      clientUserMessageId,
      input: [{ type: "text", text }],
      approvalPolicy: body.approvalPolicy || "never",
      sandboxPolicy: body.sandboxPolicy || undefined,
      cwd: body.cwd || undefined,
      model: body.model || undefined,
      effort: body.effort || undefined,
    });

    jsonResponse(res, 202, {
      threadId,
      clientUserMessageId,
      turn: compactTurn(result.turn),
      status: "accepted",
    });
  }
}

const options = parseArgs(process.argv.slice(2));
const bridge = new HomeMacBridge(options);

process.on("SIGINT", () => {
  bridge.stop();
  process.exit(130);
});

process.on("SIGTERM", () => {
  bridge.stop();
  process.exit(143);
});

bridge.start().then(() => {
  console.log(`Codex Home Mac Bridge listening on http://${options.host}:${options.port}`);
  console.log(`Codex path: ${options.codexPath}`);
  console.log(`Working directory: ${options.cwd}`);
  if (!options.token) {
    console.log("BRIDGE_TOKEN is not set; keep this bound to 127.0.0.1 for local-only use.");
  }
}).catch((error) => {
  console.error(error);
  process.exit(1);
});
