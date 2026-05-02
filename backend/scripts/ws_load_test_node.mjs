#!/usr/bin/env node
/**
 * Dependency-free WebSocket load test for VeriCall (Node 20+).
 *
 * Example (query-token auth):
 *   node scripts/ws_load_test_node.mjs \
 *     --url wss://vericall-api.fly.dev/ws \
 *     --token-file ./tokens.txt \
 *     --connections 500 \
 *     --duration 60 \
 *     --auth-mode query
 *
 * Example (auth-message mode used by older deployments):
 *   node scripts/ws_load_test_node.mjs \
 *     --url wss://vericall-api.fly.dev/ws \
 *     --token-file ./tokens.txt \
 *     --connections 500 \
 *     --duration 60 \
 *     --auth-mode message
 */

import fs from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";

function parseArgs(argv) {
  const args = {
    url: "",
    tokenFile: "",
    connections: 500,
    duration: 60,
    rampSeconds: 20,
    pingInterval: 15,
    connectTimeout: 10,
    authMode: "query",
  };

  for (let i = 2; i < argv.length; i++) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key.startsWith("--")) continue;
    if (value == null) break;

    switch (key) {
      case "--url":
        args.url = value;
        i++;
        break;
      case "--token-file":
        args.tokenFile = value;
        i++;
        break;
      case "--connections":
        args.connections = Number(value);
        i++;
        break;
      case "--duration":
        args.duration = Number(value);
        i++;
        break;
      case "--ramp-seconds":
        args.rampSeconds = Number(value);
        i++;
        break;
      case "--ping-interval":
        args.pingInterval = Number(value);
        i++;
        break;
      case "--connect-timeout":
        args.connectTimeout = Number(value);
        i++;
        break;
      case "--auth-mode":
        args.authMode = value === "message" ? "message" : "query";
        i++;
        break;
      default:
        break;
    }
  }

  if (!args.url || !args.tokenFile) {
    throw new Error("Missing required args: --url and --token-file");
  }
  if (!["query", "message"].includes(args.authMode)) {
    throw new Error("--auth-mode must be 'query' or 'message'");
  }
  return args;
}

function percentile(values, p) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.floor((sorted.length - 1) * p);
  return sorted[idx];
}

function loadTokens(path) {
  return fs
    .readFileSync(path, "utf8")
    .split("\n")
    .map((x) => x.trim())
    .filter(Boolean);
}

async function runClient(index, token, args, stopAt, stats) {
  stats.attempted += 1;
  const start = performance.now();

  const url =
    args.authMode === "query"
      ? `${args.url}?token=${encodeURIComponent(token)}`
      : args.url;

  let connected = false;
  let closed = false;
  let connectTimer = null;
  let pingTimer = null;
  let ws;

  const finish = (ok) => {
    if (closed) return;
    closed = true;
    if (connectTimer) clearTimeout(connectTimer);
    if (pingTimer) clearInterval(pingTimer);
    try {
      ws?.close();
    } catch (_) {
      // Ignore close errors
    }

    if (ok) {
      stats.connected += 1;
    } else {
      stats.failed += 1;
    }
  };

  try {
    ws = new WebSocket(url);
  } catch (_) {
    finish(false);
    return;
  }

  const armPingTimer = () => {
    if (pingTimer) clearInterval(pingTimer);
    pingTimer = setInterval(() => {
      if (Date.now() >= stopAt || ws.readyState !== WebSocket.OPEN) return;
      try {
        ws.send(JSON.stringify({ type: "ping" }));
        stats.pingsSent += 1;
      } catch (_) {
        // Ignore send failures; close handler will mark fail if needed.
      }
    }, args.pingInterval * 1000);
  };

  const markConnected = () => {
    if (connected) return;
    connected = true;
    stats.connectTimesMs.push(performance.now() - start);
    armPingTimer();
  };

  connectTimer = setTimeout(() => {
    if (closed) return;

    // Some deployments do not send an explicit "connected" payload.
    // If socket is open at timeout, treat it as connected.
    if (ws.readyState === WebSocket.OPEN) {
      markConnected();
    } else {
      finish(false);
    }
  }, args.connectTimeout * 1000);

  ws.addEventListener("open", () => {
    if (args.authMode === "message") {
      try {
        ws.send(JSON.stringify({ type: "auth", token }));
      } catch (_) {
        finish(false);
      }
    }
  });

  ws.addEventListener("message", (event) => {
    stats.messagesReceived += 1;

    let parsed = null;
    try {
      parsed = JSON.parse(String(event.data));
    } catch (_) {
      // Non-JSON message: still indicates connection is alive.
      markConnected();
      return;
    }

    if (parsed?.type === "error" && !connected) {
      finish(false);
      return;
    }

    markConnected();
  });

  ws.addEventListener("close", () => {
    if (!closed && !connected) {
      finish(false);
      return;
    }
    if (!closed) {
      finish(true);
    }
  });

  ws.addEventListener("error", () => {
    if (!closed) finish(false);
  });

  while (!closed && Date.now() < stopAt) {
    await sleep(200);
  }

  if (!closed) {
    if (connected) finish(true);
    else finish(false);
  }
}

async function main() {
  const args = parseArgs(process.argv);
  const tokens = loadTokens(args.tokenFile);
  if (tokens.length < args.connections) {
    throw new Error(
      `Need at least ${args.connections} tokens in ${args.tokenFile}, found ${tokens.length}`
    );
  }

  const stats = {
    attempted: 0,
    connected: 0,
    failed: 0,
    pingsSent: 0,
    messagesReceived: 0,
    connectTimesMs: [],
  };

  const delayMs =
    args.connections > 0 ? (args.rampSeconds * 1000) / args.connections : 0;
  const stopAt = Date.now() + args.duration * 1000;

  const tasks = [];
  for (let i = 0; i < args.connections; i++) {
    tasks.push(runClient(i, tokens[i], args, stopAt, stats));
    if (delayMs > 0) {
      await sleep(delayMs);
    }
  }

  console.log(
    `Started ${args.connections} clients for ${args.duration}s (auth-mode=${args.authMode})`
  );
  await Promise.allSettled(tasks);

  const successRate =
    stats.attempted > 0 ? (stats.connected / stats.attempted) * 100 : 0;

  console.log("");
  console.log("=== WebSocket Load Test Summary (Node) ===");
  console.log(`attempted: ${stats.attempted}`);
  console.log(`connected: ${stats.connected}`);
  console.log(`failed:    ${stats.failed}`);
  console.log(`success:   ${successRate.toFixed(2)}%`);
  console.log(`pings:     ${stats.pingsSent}`);
  console.log(`messages:  ${stats.messagesReceived}`);
  if (stats.connectTimesMs.length > 0) {
    console.log(`connect p50: ${percentile(stats.connectTimesMs, 0.5).toFixed(1)} ms`);
    console.log(`connect p95: ${percentile(stats.connectTimesMs, 0.95).toFixed(1)} ms`);
    console.log(`connect p99: ${percentile(stats.connectTimesMs, 0.99).toFixed(1)} ms`);
  }
}

main().catch((err) => {
  console.error(err.message || String(err));
  process.exit(1);
});
