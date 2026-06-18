#!/usr/bin/env node
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const outputDir = path.dirname(fileURLToPath(import.meta.url));
const doctorScript = path.join(outputDir, "home-mac-bridge", "doctor-github-inbox.sh");

let repoPrivate = true;
let labels = new Set(["codex-remote", "codex-done"]);
let createdLabels = new Set();

function json(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");
  if (req.method === "GET" && url.pathname === "/repos/test/codex") {
    json(res, 200, { full_name: "test/codex", private: repoPrivate, has_issues: true });
    return;
  }
  const labelMatch = url.pathname.match(/^\/repos\/test\/codex\/labels\/([^/]+)$/);
  if (req.method === "GET" && labelMatch) {
    const label = decodeURIComponent(labelMatch[1]);
    json(res, labels.has(label) ? 200 : 404, labels.has(label) ? { name: label } : { message: "Not Found" });
    return;
  }
  if (req.method === "GET" && url.pathname === "/users/alice") {
    json(res, 200, { login: "alice" });
    return;
  }
  if (req.method === "POST" && url.pathname === "/repos/test/codex/labels") {
    let raw = "";
    req.setEncoding("utf8");
    for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw || "{}");
    labels.add(body.name);
    createdLabels.add(body.name);
    json(res, 201, { name: body.name });
    return;
  }
  json(res, 404, { message: "Not Found" });
});

function listen() {
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve(server.address()));
  });
}

function makeEnvFile(apiUrl) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "codex-remote-doctor-"));
  const envPath = path.join(dir, "home-mac.env");
  fs.writeFileSync(envPath, [
    `GITHUB_API_URL=${apiUrl}`,
    "GITHUB_TOKEN=local-test-token",
    "GITHUB_OWNER=test",
    "GITHUB_REPO=codex",
    "GITHUB_TASK_LABEL=codex-remote",
    "GITHUB_DONE_LABEL=codex-done",
    "GITHUB_NOTIFY_ASSIGNEES=alice",
    "",
  ].join("\n"));
  return { dir, envPath };
}

function runDoctor(apiUrl, args = []) {
  const { dir, envPath } = makeEnvFile(apiUrl);
  return new Promise((resolve) => {
    const child = spawn("bash", [doctorScript, "--env", envPath, ...args], {
      cwd: outputDir,
      env: {
        ...process.env,
        GITHUB_TOKEN: "",
        GITHUB_TOKEN_COMMAND: "",
        GH_BIN: "",
      },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
    }, 10000);
    child.on("close", (status) => {
      clearTimeout(timer);
      fs.rmSync(dir, { recursive: true, force: true });
      resolve({ status, stdout, stderr });
    });
  });
}

function assert(condition, message, details = "") {
  if (!condition) {
    console.error(message);
    if (details) console.error(details);
    process.exit(1);
  }
}

const address = await listen();
const apiUrl = `http://${address.address}:${address.port}`;

try {
  repoPrivate = true;
  labels = new Set(["codex-remote", "codex-done"]);
  let result = await runDoctor(apiUrl);
  assert(result.status === 0, "Private inbox should pass.", result.stdout + result.stderr);
  assert(result.stdout.includes("GitHub inbox check passed."), "Expected success message.", result.stdout);

  repoPrivate = false;
  labels = new Set(["codex-remote", "codex-done"]);
  result = await runDoctor(apiUrl);
  assert(result.status !== 0, "Public inbox should be rejected.");
  assert((result.stdout + result.stderr).includes("Repository is public"), "Expected public repo warning.", result.stdout + result.stderr);

  repoPrivate = true;
  labels = new Set();
  createdLabels = new Set();
  result = await runDoctor(apiUrl, ["--create-label"]);
  assert(result.status === 0, "Missing label should be created with --create-label.", result.stdout + result.stderr);
  assert(createdLabels.has("codex-remote") && createdLabels.has("codex-done"), "Expected local mock label creation.");

  console.log("GitHub inbox doctor smoke passed: private pass, public reject, and label creation are working.");
} finally {
  server.close();
}
