#!/usr/bin/env node
const DEFAULT_GITHUB_API_URL = "https://api.github.com";
const DEFAULT_BRIDGE_URL = "http://127.0.0.1:8787";
const DEFAULT_POLL_MS = 15000;
const RECONNECT_DELAY_MS = 3000;
const ISSUE_MARKER = "codex-remote-processed:issue";
const COMMENT_MARKER = "codex-remote-processed:comment";
const THREAD_MARKER = "codex-remote-thread";
const COMPLETED_MARKER = "codex-remote-completed";

function parseArgs(argv) {
  const options = {
    apiUrl: process.env.GITHUB_API_URL || DEFAULT_GITHUB_API_URL,
    token: process.env.GITHUB_TOKEN || "",
    owner: process.env.GITHUB_OWNER || "",
    repo: process.env.GITHUB_REPO || "",
    taskLabel: process.env.GITHUB_TASK_LABEL || "codex-remote",
    notifyUsername: process.env.GITHUB_NOTIFY_USERNAME || "",
    allowPublicRepo: process.env.GITHUB_ALLOW_PUBLIC_REPO === "1",
    pollMs: Number(process.env.GITHUB_POLL_MS || DEFAULT_POLL_MS),
    bridgeUrl: process.env.BRIDGE_URL || DEFAULT_BRIDGE_URL,
    bridgeToken: process.env.BRIDGE_TOKEN || "",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--api-url") options.apiUrl = argv[++index];
    else if (arg === "--token") options.token = argv[++index];
    else if (arg === "--owner") options.owner = argv[++index];
    else if (arg === "--repo") options.repo = argv[++index];
    else if (arg === "--label") options.taskLabel = argv[++index];
    else if (arg === "--poll-ms") options.pollMs = Number(argv[++index]);
    else if (arg === "--bridge") options.bridgeUrl = argv[++index];
    else if (arg === "--bridge-token") options.bridgeToken = argv[++index];
    else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    }
  }

  options.apiUrl = options.apiUrl.replace(/\/+$/, "");
  options.bridgeUrl = options.bridgeUrl.replace(/\/+$/, "");
  if (!options.token) throw new Error("GITHUB_TOKEN is required");
  if (!options.owner) throw new Error("GITHUB_OWNER is required");
  if (!options.repo) throw new Error("GITHUB_REPO is required");
  if (!Number.isInteger(options.pollMs) || options.pollMs < 5000) {
    throw new Error("GITHUB_POLL_MS must be at least 5000");
  }
  return options;
}

function printHelp() {
  console.log(`Codex GitHub Issues Relay Client

Usage:
  GITHUB_TOKEN=... GITHUB_OWNER=you GITHUB_REPO=codex-remote node github-issues-client.mjs

Environment:
  GITHUB_TOKEN       Fine-grained token with Issues read/write on one private repo
  GITHUB_OWNER       Repository owner
  GITHUB_REPO        Repository name
  GITHUB_TASK_LABEL  Issue label to poll, defaults to codex-remote
  GITHUB_NOTIFY_USERNAME  Optional username to mention on completion comments
  GITHUB_ALLOW_PUBLIC_REPO=1 allows using a public repo as the task inbox
  GITHUB_POLL_MS     Poll interval, defaults to 15000
  BRIDGE_URL         Local Home Mac Bridge URL
  BRIDGE_TOKEN       Optional bearer token for local Bridge
`);
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function truncateText(value, limit) {
  if (typeof value !== "string") return "";
  const compact = value.replace(/\s+/g, " ").trim();
  return compact.length > limit ? `${compact.slice(0, limit - 3)}...` : compact;
}

function marker(name, value) {
  return `<!-- ${name}:${String(value).replaceAll("--", "")} -->`;
}

function hasMarker(body, name, value) {
  return String(body || "").includes(marker(name, value));
}

function findFirstMarkerValue(body, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = String(body || "").match(new RegExp(`<!--\\s*${escaped}:([^>]+?)\\s*-->`));
  return match?.[1]?.trim() || null;
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

function stripCommand(body, commands) {
  const text = String(body || "").trim();
  const [firstLine = "", ...rest] = text.split(/\r?\n/);
  const normalized = firstLine.trim().toLowerCase();
  if (commands.includes(normalized)) return rest.join("\n").trim();
  return text;
}

function textFromIssue(issue) {
  const body = stripCommand(issue.body || "", ["/codex new", "/codex"]);
  if (body) return body;
  return issue.title || "Codex task from GitHub Issue";
}

function textFromComment(comment) {
  return stripCommand(comment.body || "", ["/codex send", "/codex", "/codex comment"]);
}

function isOwnComment(comment) {
  return String(comment.body || "").includes("<!-- codex-remote-");
}

class GitHubIssuesClient {
  constructor(options) {
    this.options = options;
    this.stopping = false;
    this.threadToIssue = new Map();
  }

  stop() {
    this.stopping = true;
    this.eventsAbortController?.abort();
  }

  async start() {
    console.log(`Connecting GitHub ${this.options.owner}/${this.options.repo} to local bridge ${this.options.bridgeUrl}`);
    await this.validateRepository();
    await Promise.all([
      this.pollLoop(),
      this.forwardEventsLoop(),
    ]);
  }

  repoPath(path) {
    return `/repos/${encodeURIComponent(this.options.owner)}/${encodeURIComponent(this.options.repo)}${path}`;
  }

  async github(path, init = {}) {
    const response = await fetch(`${this.options.apiUrl}${path}`, {
      ...init,
      headers: {
        accept: "application/vnd.github+json",
        authorization: `Bearer ${this.options.token}`,
        "x-github-api-version": "2022-11-28",
        ...(init.body ? { "content-type": "application/json" } : {}),
        ...(init.headers || {}),
      },
    });

    if (!response.ok) {
      throw new Error(`GitHub ${response.status}: ${await response.text()}`);
    }

    if (response.status === 204) return null;
    return parseResponseBody(response);
  }

  async validateRepository() {
    const repo = await this.github(this.repoPath(""));
    if (repo.private !== true && !this.options.allowPublicRepo) {
      throw new Error(
        "GitHub task inbox repository is public. Make it private, or set GITHUB_ALLOW_PUBLIC_REPO=1 if you intentionally want public tasks.",
      );
    }
    if (repo.has_issues === false) {
      throw new Error("GitHub Issues are disabled for this repository.");
    }

    try {
      await this.github(this.repoPath(`/labels/${encodeURIComponent(this.options.taskLabel)}`));
    } catch (error) {
      throw new Error(`GitHub label '${this.options.taskLabel}' is missing or not readable: ${error.message}`);
    }
  }

  async bridge(path, init = {}) {
    const response = await fetch(`${this.options.bridgeUrl}${path}`, {
      ...init,
      headers: {
        ...authHeaders(this.options.bridgeToken),
        ...(init.body ? { "content-type": "application/json" } : {}),
        ...(init.headers || {}),
      },
    });

    const body = await parseResponseBody(response);
    if (!response.ok) {
      throw new Error(`Bridge ${response.status}: ${JSON.stringify(body)}`);
    }
    return body;
  }

  async pollLoop() {
    while (!this.stopping) {
      try {
        await this.pollOnce();
      } catch (error) {
        if (!this.stopping) {
          console.error(`github issue poll error: ${error.message}`);
          await delay(RECONNECT_DELAY_MS);
        }
      }
      await delay(this.options.pollMs);
    }
  }

  async pollOnce() {
    const labels = encodeURIComponent(this.options.taskLabel);
    const issues = await this.github(this.repoPath(`/issues?state=open&labels=${labels}&sort=updated&direction=asc&per_page=30`));
    for (const issue of issues || []) {
      if (issue.pull_request) continue;
      await this.handleIssue(issue);
    }
  }

  async handleIssue(issue) {
    const comments = await this.listComments(issue.number);
    const threadId = this.findThreadId(issue, comments);
    if (threadId) this.threadToIssue.set(threadId, issue.number);

    if (!this.isIssueProcessed(issue, comments)) {
      await this.createThreadFromIssue(issue);
      return;
    }

    await this.handleCommandsFromComments(issue, comments, threadId);
  }

  async listComments(issueNumber) {
    return this.github(this.repoPath(`/issues/${encodeURIComponent(issueNumber)}/comments?per_page=100`));
  }

  isIssueProcessed(issue, comments) {
    if (hasMarker(issue.body, ISSUE_MARKER, issue.id)) return true;
    return comments.some((comment) => hasMarker(comment.body, ISSUE_MARKER, issue.id));
  }

  findThreadId(issue, comments) {
    const fromIssue = findFirstMarkerValue(issue.body, THREAD_MARKER);
    if (fromIssue) return fromIssue;
    for (const comment of comments) {
      const threadId = findFirstMarkerValue(comment.body, THREAD_MARKER);
      if (threadId) return threadId;
    }
    return null;
  }

  async createThreadFromIssue(issue) {
    const text = textFromIssue(issue);
    const result = await this.bridge("/threads", {
      method: "POST",
      body: JSON.stringify({
        text,
        ephemeral: false,
        threadSource: "github-issues-relay",
      }),
    });
    const threadId = result?.thread?.id || "unknown";
    this.threadToIssue.set(threadId, issue.number);
    await this.createComment(issue.number, [
      marker(ISSUE_MARKER, issue.id),
      marker(THREAD_MARKER, threadId),
      `Started Codex thread \`${threadId}\`.`,
      "",
      "Reply in this issue to send another instruction to the same Codex thread.",
    ].join("\n"));
  }

  async handleCommandsFromComments(issue, comments, threadId) {
    for (const comment of comments) {
      if (isOwnComment(comment)) continue;
      if (this.isCommentProcessed(comment, comments)) continue;
      await this.handleUserComment(issue, comment, threadId);
    }
  }

  isCommentProcessed(comment, comments) {
    return comments.some((candidate) => hasMarker(candidate.body, COMMENT_MARKER, comment.id));
  }

  async handleUserComment(issue, comment, threadId) {
    const raw = String(comment.body || "").trim();
    if (!raw) return;

    if (raw.toLowerCase().startsWith("/codex list")) {
      const result = await this.bridge("/threads?limit=10");
      const lines = (result.data || []).map((thread) => `- \`${thread.id}\` ${thread.name || thread.preview || "(untitled)"}`);
      await this.createComment(issue.number, [
        marker(COMMENT_MARKER, comment.id),
        "Recent Codex threads:",
        "",
        ...(lines.length ? lines : ["- No threads found."]),
      ].join("\n"));
      return;
    }

    if (!threadId) {
      await this.createComment(issue.number, [
        marker(COMMENT_MARKER, comment.id),
        "I do not know which Codex thread this issue maps to yet. Create a new issue with the task text, or wait until the first task is started.",
      ].join("\n"));
      return;
    }

    const text = textFromComment(comment);
    if (!text) return;
    await this.bridge(`/threads/${encodeURIComponent(threadId)}/messages`, {
      method: "POST",
      body: JSON.stringify({
        text,
        responsesapiClientMetadata: {
          source: "github-issues-relay",
          issue: String(issue.number),
          comment: String(comment.id),
        },
      }),
    });
    await this.createComment(issue.number, [
      marker(COMMENT_MARKER, comment.id),
      `Sent to Codex thread \`${threadId}\`.`,
    ].join("\n"));
  }

  async createComment(issueNumber, body) {
    return this.github(this.repoPath(`/issues/${encodeURIComponent(issueNumber)}/comments`), {
      method: "POST",
      body: JSON.stringify({ body }),
    });
  }

  async forwardEventsLoop() {
    while (!this.stopping) {
      try {
        await this.forwardEventsOnce();
      } catch (error) {
        if (!this.stopping) {
          console.error(`github event loop error: ${error.message}`);
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
        if (event) await this.handleBridgeEvent(event);
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

  async handleBridgeEvent(event) {
    if (event?.type !== "turn/completed") return;
    const threadId = event.params?.threadId ?? event.threadId ?? null;
    const turnId = event.params?.turn?.id ?? event.turnId ?? null;
    if (!threadId || !turnId) return;

    const issueNumber = this.threadToIssue.get(threadId);
    if (!issueNumber) return;

    const comments = await this.listComments(issueNumber);
    if (comments.some((comment) => hasMarker(comment.body, COMPLETED_MARKER, turnId))) return;

    const summary = truncateText(event.agentText ?? event.summary, 1800) || "Codex finished this turn.";
    const mention = this.options.notifyUsername ? `@${this.options.notifyUsername} ` : "";
    await this.createComment(issueNumber, [
      marker(COMPLETED_MARKER, turnId),
      `${mention}Codex finished turn \`${turnId}\` on thread \`${threadId}\`.`,
      "",
      summary,
    ].join("\n"));
  }
}

const options = parseArgs(process.argv.slice(2));
const client = new GitHubIssuesClient(options);

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
