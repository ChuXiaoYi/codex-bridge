#!/usr/bin/env node
import { spawn } from "node:child_process";
import http from "node:http";
import { setTimeout as delay } from "node:timers/promises";

const issues = [
  {
    id: 101,
    number: 1,
    title: "Mock Codex task",
    body: "Reply exactly: MOCK_GITHUB_OK",
    labels: [{ name: "codex-remote" }],
  },
];
const comments = [];
const messages = [];
const bridgeEventClients = new Set();
let nextCommentId = 1000;

function json(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      raw += chunk;
    });
    req.on("end", () => {
      try {
        resolve(raw ? JSON.parse(raw) : {});
      } catch (error) {
        reject(error);
      }
    });
    req.on("error", reject);
  });
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      resolve(`http://127.0.0.1:${address.port}`);
    });
  });
}

function waitFor(predicate, label, timeoutMs = 12000) {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      if (predicate()) {
        resolve();
        return;
      }
      if (Date.now() - started > timeoutMs) {
        reject(new Error(`Timed out waiting for ${label}`));
        return;
      }
      setTimeout(tick, 100);
    };
    tick();
  });
}

const githubServer = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");
  if (req.method === "GET" && url.pathname === "/repos/test/codex/issues") {
    json(res, 200, issues);
    return;
  }
  if (req.method === "GET" && url.pathname === "/repos/test/codex/issues/1/comments") {
    json(res, 200, comments);
    return;
  }
  if (req.method === "POST" && url.pathname === "/repos/test/codex/issues/1/comments") {
    const body = await readBody(req);
    const comment = {
      id: nextCommentId++,
      body: body.body,
      user: { login: "codex-bot" },
    };
    comments.push(comment);
    json(res, 201, comment);
    return;
  }
  json(res, 404, { error: "not_found", path: url.pathname });
});

const bridgeServer = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");
  if (req.method === "GET" && url.pathname === "/health") {
    json(res, 200, { ok: true });
    return;
  }
  if (req.method === "GET" && url.pathname === "/events") {
    res.writeHead(200, {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache",
      connection: "keep-alive",
    });
    res.write(`data: ${JSON.stringify({ type: "bridge_connected", recentEvents: [] })}\n\n`);
    bridgeEventClients.add(res);
    req.on("close", () => bridgeEventClients.delete(res));
    return;
  }
  if (req.method === "GET" && url.pathname === "/threads") {
    json(res, 200, {
      data: [{ id: "thread-1", name: "Mock thread", preview: "Mock", status: { type: "idle" } }],
      nextCursor: null,
    });
    return;
  }
  if (req.method === "POST" && url.pathname === "/threads") {
    await readBody(req);
    json(res, 202, {
      thread: { id: "thread-1", name: "Mock thread", preview: "Mock", status: { type: "active" } },
      turn: { id: "turn-1" },
      status: "accepted",
    });
    return;
  }
  if (req.method === "POST" && url.pathname === "/threads/thread-1/messages") {
    messages.push(await readBody(req));
    json(res, 202, { status: "accepted", turn: { id: "turn-2" } });
    return;
  }
  json(res, 404, { error: "not_found", path: url.pathname });
});

let client;
try {
  const githubUrl = await listen(githubServer);
  const bridgeUrl = await listen(bridgeServer);
  client = spawn(process.execPath, ["outputs/home-mac-bridge/github-issues-client.mjs"], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      GITHUB_API_URL: githubUrl,
      GITHUB_TOKEN: "fake",
      GITHUB_OWNER: "test",
      GITHUB_REPO: "codex",
      GITHUB_POLL_MS: "5000",
      GITHUB_NOTIFY_USERNAME: "alice",
      BRIDGE_URL: bridgeUrl,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  client.stdout.on("data", (chunk) => process.stdout.write(chunk));
  client.stderr.on("data", (chunk) => process.stderr.write(chunk));

  await waitFor(
    () => comments.some((comment) => comment.body.includes("codex-remote-thread:thread-1")),
    "thread marker comment",
  );

  comments.push({
    id: 9001,
    body: "Add more detail to the answer",
    user: { login: "alice" },
  });

  await waitFor(
    () => messages.length === 1 && comments.some((comment) => comment.body.includes("codex-remote-processed:comment:9001")),
    "processed user comment",
  );

  const completionEvent = {
    type: "turn/completed",
    threadId: "thread-1",
    turnId: "turn-2",
    summary: "Mock completion finished.",
  };
  for (const res of bridgeEventClients) {
    res.write(`data: ${JSON.stringify(completionEvent)}\n\n`);
  }

  await waitFor(
    () => comments.some((comment) => comment.body.includes("codex-remote-completed:turn-2") && comment.body.includes("@alice")),
    "completion comment",
  );

  console.log("GitHub Issues smoke passed: issue task, comment instruction, and completion comment are working.");
} finally {
  client?.kill("SIGTERM");
  await delay(100);
  githubServer.close();
  bridgeServer.close();
}
