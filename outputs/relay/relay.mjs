#!/usr/bin/env node
import { createPrivateKey, randomUUID, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import http from "node:http";
import http2 from "node:http2";

const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 8788;
const DEFAULT_COMMAND_TIMEOUT_MS = 70000;
const DEFAULT_POLL_TIMEOUT_MS = 25000;

function parseArgs(argv) {
  const options = {
    host: process.env.RELAY_HOST || DEFAULT_HOST,
    port: Number(process.env.RELAY_PORT || DEFAULT_PORT),
    bridgeToken: process.env.RELAY_BRIDGE_TOKEN || "",
    clientToken: process.env.RELAY_CLIENT_TOKEN || "",
    commandTimeoutMs: Number(process.env.RELAY_COMMAND_TIMEOUT_MS || DEFAULT_COMMAND_TIMEOUT_MS),
    pollTimeoutMs: Number(process.env.RELAY_POLL_TIMEOUT_MS || DEFAULT_POLL_TIMEOUT_MS),
    apnsKeyPath: process.env.APNS_KEY_PATH || "",
    apnsKeyId: process.env.APNS_KEY_ID || "",
    apnsTeamId: process.env.APNS_TEAM_ID || "",
    apnsTopic: process.env.APNS_TOPIC || "",
    apnsEnvironment: process.env.APNS_ENV || "sandbox",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--host") options.host = argv[++index];
    else if (arg === "--port") options.port = Number(argv[++index]);
    else if (arg === "--bridge-token") options.bridgeToken = argv[++index];
    else if (arg === "--client-token") options.clientToken = argv[++index];
    else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    }
  }

  if (!Number.isInteger(options.port) || options.port <= 0) {
    throw new Error(`Invalid port: ${options.port}`);
  }
  if (!Number.isInteger(options.commandTimeoutMs) || options.commandTimeoutMs <= 0) {
    throw new Error(`Invalid command timeout: ${options.commandTimeoutMs}`);
  }
  if (!Number.isInteger(options.pollTimeoutMs) || options.pollTimeoutMs <= 0) {
    throw new Error(`Invalid poll timeout: ${options.pollTimeoutMs}`);
  }

  return options;
}

function printHelp() {
  console.log(`Codex Remote Relay

Usage:
  node relay.mjs [--port 8788] [--host 127.0.0.1]

Environment:
  RELAY_HOST                 HTTP bind host, defaults to 127.0.0.1
  RELAY_PORT                 HTTP bind port, defaults to 8788
  RELAY_CLIENT_TOKEN         Optional bearer token for phone/watch clients
  RELAY_BRIDGE_TOKEN         Optional bearer token for the Home Mac connector
  RELAY_COMMAND_TIMEOUT_MS   How long client API calls wait for Mac results
  RELAY_POLL_TIMEOUT_MS      How long Mac long-poll requests wait for commands
  APNS_KEY_PATH              Optional .p8 auth key for completion push notifications
  APNS_KEY_ID                APNs auth key id
  APNS_TEAM_ID               Apple Developer team id
  APNS_TOPIC                 App bundle id, for example com.chuxiaoyi.CodexRemote
  APNS_ENV                   sandbox or production
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

function emptyResponse(res, status) {
  res.writeHead(status, {
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "authorization, content-type",
    "access-control-allow-methods": "GET, POST, OPTIONS",
  });
  res.end();
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

function requireBearer(req, expectedToken) {
  if (!expectedToken) return true;
  return req.headers.authorization === `Bearer ${expectedToken}`;
}

function isAllowedClientCommand(method, pathname) {
  const parts = pathname.split("/").filter(Boolean);
  if (method === "GET" && pathname === "/threads") return true;
  if (method === "POST" && pathname === "/threads") return true;
  if (parts[0] === "threads" && parts[1] && parts.length === 2 && method === "GET") return true;
  if (parts[0] === "threads" && parts[1] && parts[2] === "messages" && parts.length === 3 && method === "POST") {
    return true;
  }
  return false;
}

function base64urlJson(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function truncateText(value, limit) {
  if (typeof value !== "string") return "";
  const compact = value.replace(/\s+/g, " ").trim();
  return compact.length > limit ? `${compact.slice(0, limit - 3)}...` : compact;
}

function relayResultToHttp(res, result) {
  const status = Number.isInteger(result?.status) ? result.status : 502;
  const body = result?.body ?? { error: "empty_bridge_result" };
  if (typeof body === "string") {
    res.writeHead(status, {
      "content-type": "text/plain; charset=utf-8",
      "access-control-allow-origin": "*",
      "access-control-allow-headers": "authorization, content-type",
      "access-control-allow-methods": "GET, POST, OPTIONS",
    });
    res.end(body);
    return;
  }
  jsonResponse(res, status, body);
}

class Relay {
  constructor(options) {
    this.options = options;
    this.startedAt = new Date();
    this.commandQueue = [];
    this.commandWaiters = [];
    this.pendingResults = new Map();
    this.recentEvents = [];
    this.sseClients = new Set();
    this.devices = new Map();
    this.apns = new ApnsClient(options);
  }

  async start() {
    this.server = http.createServer((req, res) => this.handle(req, res));
    await new Promise((resolve) => this.server.listen(this.options.port, this.options.host, resolve));
  }

  stop() {
    this.server?.close();
    for (const res of this.sseClients) res.end();
    for (const waiter of this.commandWaiters) waiter.finish(null);
    for (const pending of this.pendingResults.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error("relay stopped"));
    }
    this.commandWaiters = [];
    this.pendingResults.clear();
  }

  async handle(req, res) {
    res.setHeader("access-control-allow-origin", "*");
    res.setHeader("access-control-allow-headers", "authorization, content-type");
    res.setHeader("access-control-allow-methods", "GET, POST, OPTIONS");

    if (req.method === "OPTIONS") {
      emptyResponse(res, 204);
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
        if (!requireBearer(req, this.options.clientToken)) {
          jsonResponse(res, 401, { error: "unauthorized" });
          return;
        }
        this.handleEvents(req, res);
        return;
      }

      if (req.method === "POST" && url.pathname === "/devices") {
        if (!requireBearer(req, this.options.clientToken)) {
          jsonResponse(res, 401, { error: "unauthorized" });
          return;
        }
        await this.handleDeviceRegistration(req, res);
        return;
      }

      if (req.method === "GET" && url.pathname === "/bridge/commands") {
        if (!requireBearer(req, this.options.bridgeToken)) {
          jsonResponse(res, 401, { error: "unauthorized" });
          return;
        }
        this.handleBridgePoll(req, res, url);
        return;
      }

      if (req.method === "POST" && parts[0] === "bridge" && parts[1] === "commands" && parts[2] && parts[3] === "result") {
        if (!requireBearer(req, this.options.bridgeToken)) {
          jsonResponse(res, 401, { error: "unauthorized" });
          return;
        }
        await this.handleBridgeResult(req, res, parts[2]);
        return;
      }

      if (req.method === "POST" && url.pathname === "/bridge/events") {
        if (!requireBearer(req, this.options.bridgeToken)) {
          jsonResponse(res, 401, { error: "unauthorized" });
          return;
        }
        await this.handleBridgeEvent(req, res);
        return;
      }

      if (!requireBearer(req, this.options.clientToken)) {
        jsonResponse(res, 401, { error: "unauthorized" });
        return;
      }

      if (!isAllowedClientCommand(req.method ?? "", url.pathname)) {
        jsonResponse(res, 404, { error: "not_found" });
        return;
      }

      const body = req.method === "POST" ? await parseJsonBody(req) : null;
      const result = await this.enqueueCommand({
        method: req.method,
        path: `${url.pathname}${url.search}`,
        body,
      });
      relayResultToHttp(res, result);
    } catch (error) {
      jsonResponse(res, 500, {
        error: "relay_error",
        message: error.message,
      });
    }
  }

  health() {
    return {
      ok: true,
      startedAt: this.startedAt.toISOString(),
      uptimeSeconds: Math.round(process.uptime()),
      queuedCommands: this.commandQueue.length,
      pendingResults: this.pendingResults.size,
      waitingBridgePolls: this.commandWaiters.length,
      eventClients: this.sseClients.size,
      registeredDevices: this.devices.size,
      bridgeTokenRequired: Boolean(this.options.bridgeToken),
      clientTokenRequired: Boolean(this.options.clientToken),
      apnsConfigured: this.apns.isConfigured,
    };
  }

  enqueueCommand(commandInput) {
    const command = {
      id: randomUUID(),
      createdAt: new Date().toISOString(),
      ...commandInput,
    };

    this.broadcast({
      type: "relay_command_queued",
      commandId: command.id,
      method: command.method,
      path: command.path,
    });

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingResults.delete(command.id);
        reject(new Error(`timed out waiting for Home Mac result: ${command.id}`));
      }, this.options.commandTimeoutMs);

      this.pendingResults.set(command.id, {
        resolve: (result) => {
          clearTimeout(timer);
          resolve(result);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
        timer,
      });

      this.dispatchCommand(command);
    });
  }

  dispatchCommand(command) {
    const waiter = this.commandWaiters.shift();
    if (waiter) {
      waiter.finish(command);
      return;
    }
    this.commandQueue.push(command);
  }

  handleBridgePoll(req, res, url) {
    const command = this.commandQueue.shift();
    if (command) {
      jsonResponse(res, 200, { command });
      return;
    }

    const requestedWaitMs = Number(url.searchParams.get("waitMs") || this.options.pollTimeoutMs);
    const waitMs = Math.max(1000, Math.min(requestedWaitMs, this.options.pollTimeoutMs));
    let finished = false;
    const finish = (nextCommand) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      this.commandWaiters = this.commandWaiters.filter((waiter) => waiter.finish !== finish);
      if (nextCommand) jsonResponse(res, 200, { command: nextCommand });
      else emptyResponse(res, 204);
    };
    const timer = setTimeout(() => finish(null), waitMs);
    this.commandWaiters.push({ finish });
    req.on("close", () => finish(null));
  }

  async handleBridgeResult(req, res, commandId) {
    const pending = this.pendingResults.get(commandId);
    if (!pending) {
      jsonResponse(res, 404, { error: "unknown_command", commandId });
      return;
    }

    const body = await parseJsonBody(req);
    this.pendingResults.delete(commandId);
    pending.resolve(body);
    this.broadcast({
      type: "relay_command_completed",
      commandId,
      status: body.status ?? null,
    });
    jsonResponse(res, 200, { ok: true });
  }

  async handleBridgeEvent(req, res) {
    const body = await parseJsonBody(req);
    const event = body.event ?? body;
    this.broadcast({
      type: "bridge_event",
      event,
      receivedAt: new Date().toISOString(),
    });
    if (event?.type === "turn/completed") {
      await this.handleTurnCompleted(event);
    }
    jsonResponse(res, 202, { ok: true });
  }

  async handleDeviceRegistration(req, res) {
    const body = await parseJsonBody(req);
    const token = typeof body.token === "string" ? body.token.trim() : "";
    if (!token) {
      jsonResponse(res, 400, { error: "missing_device_token" });
      return;
    }

    const device = {
      token,
      platform: typeof body.platform === "string" ? body.platform : "unknown",
      appName: typeof body.appName === "string" ? body.appName : "CodexRemote",
      registeredAt: new Date().toISOString(),
    };
    this.devices.set(token, device);
    this.broadcast({
      type: "device_registered",
      platform: device.platform,
      appName: device.appName,
      registeredDevices: this.devices.size,
    });
    jsonResponse(res, 201, { ok: true, registeredDevices: this.devices.size });
  }

  async handleTurnCompleted(event) {
    const agentText = truncateText(event.agentText ?? event.summary, 140);
    const threadId = event.params?.threadId ?? event.threadId ?? null;
    const turnId = event.params?.turn?.id ?? event.turnId ?? event.turn?.id ?? null;
    const title = "Codex finished";
    const body = agentText || "A Codex task completed on your Home Mac.";
    const notification = {
      title,
      body,
      threadId,
      turnId,
    };

    if (!this.apns.isConfigured) {
      this.broadcast({
        type: "notification_ready",
        reason: "apns_not_configured",
        notification,
        registeredDevices: this.devices.size,
      });
      return;
    }

    for (const device of this.devices.values()) {
      try {
        await this.apns.send(device.token, notification);
        this.broadcast({
          type: "notification_sent",
          platform: device.platform,
          threadId,
        });
      } catch (error) {
        this.broadcast({
          type: "notification_failed",
          platform: device.platform,
          threadId,
          message: error.message,
        });
      }
    }
  }

  handleEvents(req, res) {
    req.socket.setTimeout(0);
    res.writeHead(200, {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache, no-transform",
      connection: "keep-alive",
      "access-control-allow-origin": "*",
    });
    res.write(`data: ${JSON.stringify({ type: "relay_connected", recentEvents: this.recentEvents })}\n\n`);
    this.sseClients.add(res);
    req.on("close", () => {
      this.sseClients.delete(res);
    });
  }

  broadcast(event) {
    const payload = {
      id: randomUUID(),
      receivedAt: new Date().toISOString(),
      ...event,
    };
    this.recentEvents.push(payload);
    if (this.recentEvents.length > 200) this.recentEvents.shift();

    const line = `data: ${JSON.stringify(payload)}\n\n`;
    for (const res of this.sseClients) res.write(line);
  }
}

class ApnsClient {
  constructor(options) {
    this.keyPath = options.apnsKeyPath;
    this.keyId = options.apnsKeyId;
    this.teamId = options.apnsTeamId;
    this.topic = options.apnsTopic;
    this.environment = options.apnsEnvironment;
    this.privateKey = null;

    if (this.keyPath && this.keyId && this.teamId && this.topic) {
      this.privateKey = createPrivateKey(readFileSync(this.keyPath, "utf8"));
    }
  }

  get isConfigured() {
    return Boolean(this.privateKey && this.keyId && this.teamId && this.topic);
  }

  endpoint() {
    return this.environment === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";
  }

  jwt() {
    const header = base64urlJson({ alg: "ES256", kid: this.keyId });
    const claims = base64urlJson({
      iss: this.teamId,
      iat: Math.floor(Date.now() / 1000),
    });
    const signingInput = `${header}.${claims}`;
    const signature = sign("sha256", Buffer.from(signingInput), this.privateKey).toString("base64url");
    return `${signingInput}.${signature}`;
  }

  send(deviceToken, notification) {
    if (!this.isConfigured) return Promise.reject(new Error("APNs is not configured"));

    const payload = JSON.stringify({
      aps: {
        alert: {
          title: notification.title,
          body: notification.body,
        },
        sound: "default",
      },
      threadId: notification.threadId,
      turnId: notification.turnId,
    });

    return new Promise((resolve, reject) => {
      const client = http2.connect(this.endpoint());
      const chunks = [];
      let status = 0;

      client.on("error", reject);

      const req = client.request({
        ":method": "POST",
        ":path": `/3/device/${deviceToken}`,
        "authorization": `bearer ${this.jwt()}`,
        "apns-topic": this.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
      });

      req.setEncoding("utf8");
      req.on("response", (headers) => {
        status = Number(headers[":status"] ?? 0);
      });
      req.on("data", (chunk) => chunks.push(chunk));
      req.on("end", () => {
        client.close();
        const body = chunks.join("");
        if (status >= 200 && status < 300) {
          resolve();
        } else {
          reject(new Error(`APNs ${status}: ${body}`));
        }
      });
      req.on("error", (error) => {
        client.close();
        reject(error);
      });
      req.end(payload);
    });
  }
}

const options = parseArgs(process.argv.slice(2));
const relay = new Relay(options);

process.on("SIGINT", () => {
  relay.stop();
  process.exit(130);
});

process.on("SIGTERM", () => {
  relay.stop();
  process.exit(143);
});

relay.start().then(() => {
  console.log(`Codex Remote Relay listening on http://${options.host}:${options.port}`);
  if (!options.clientToken || !options.bridgeToken) {
    console.log("Set RELAY_CLIENT_TOKEN and RELAY_BRIDGE_TOKEN before exposing this relay outside localhost.");
  }
}).catch((error) => {
  console.error(error);
  process.exit(1);
});
