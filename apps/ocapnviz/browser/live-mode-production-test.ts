#!/usr/bin/env -S deno run -A
/** Production-bundle proof for capability-native Live mode.
 *
 * The Vite build happens in the owning task. This process serves only `dist/`,
 * starts the real native viz endpoint, and drives an actual Chromium tab. */

import { chromium, type Page } from "playwright";

const TEST_TIMEOUT_MS = 45_000;
const UI_TIMEOUT_MS = 10_000;
const MAX_ANNOUNCEMENT_BYTES = 8 * 1024;
const distRoot = new URL("../dist/", import.meta.url);
const repositoryRoot = new URL("../../../", import.meta.url);
const vizHostScript = new URL(
  "../../rooms/test/viz_browser_host.ts",
  import.meta.url,
);
const requiredAssets = [
  "index.html",
  "pancake_host.wasm",
  "favicon.svg",
  "fonts/DepartureMono-Regular.woff2",
  "sw.js",
];

type WorldSnapshot = {
  peers: Array<{ id: string; label: string }>;
  sessions: string[];
};

type VizAnnouncement = {
  port: number;
  sturdyref: string;
};

function fail(message: string): never {
  throw new Error(message);
}

async function readVizAnnouncement(
  stdout: ReadableStream<Uint8Array>,
): Promise<VizAnnouncement> {
  const reader = stdout.getReader();
  const decoder = new TextDecoder();
  let line = "";
  try {
    while (!line.includes("\n")) {
      const { value, done } = await reader.read();
      if (done) fail("viz host exited before announcing its endpoint");
      line += decoder.decode(value, { stream: true });
      if (line.length > MAX_ANNOUNCEMENT_BYTES) {
        fail("viz host announcement exceeded its bound");
      }
    }
  } finally {
    reader.releaseLock();
  }

  const parsed: unknown = JSON.parse(line.slice(0, line.indexOf("\n")));
  if (
    typeof parsed !== "object" || parsed === null ||
    !("port" in parsed) || !Number.isInteger(parsed.port) ||
    (parsed.port as number) < 1 || (parsed.port as number) > 65_535 ||
    !("sturdyref" in parsed) || typeof parsed.sturdyref !== "string" ||
    parsed.sturdyref.length === 0
  ) {
    fail(`invalid viz host announcement: ${JSON.stringify(parsed)}`);
  }
  return {
    port: parsed.port as number,
    sturdyref: parsed.sturdyref,
  };
}

async function stopVizHost(process: Deno.ChildProcess): Promise<void> {
  try {
    process.kill("SIGTERM");
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
  await process.status;
}

function bytesDiffer(a: Uint8Array, b: Uint8Array): boolean {
  if (a.byteLength !== b.byteLength) return true;
  for (let i = 0; i < a.byteLength; i += 1) {
    if (a[i] !== b[i]) return true;
  }
  return false;
}

function contentType(pathname: string): string {
  if (pathname.endsWith(".html")) return "text/html; charset=utf-8";
  if (pathname.endsWith(".js")) return "text/javascript; charset=utf-8";
  if (pathname.endsWith(".css")) return "text/css; charset=utf-8";
  if (pathname.endsWith(".wasm")) return "application/wasm";
  if (pathname.endsWith(".svg")) return "image/svg+xml";
  if (pathname.endsWith(".woff2")) return "font/woff2";
  return "application/octet-stream";
}

async function worldSnapshot(page: Page): Promise<WorldSnapshot> {
  return await page.evaluate(() => {
    type Peer = { peer: { id: string; label: string } };
    type Session = { session: { id: string } };
    type Engine = {
      queries: {
        peers: Iterable<Peer>;
        sessions: Iterable<Session>;
      };
    };
    const engine = (globalThis as unknown as {
      __ocv?: { engine?: Engine };
    }).__ocv?.engine;
    if (engine === undefined) {
      throw new Error("ocapnviz did not expose its live engine");
    }
    return {
      peers: [...engine.queries.peers]
        .map((entity) => ({ ...entity.peer }))
        .sort((a, b) => a.id.localeCompare(b.id)),
      sessions: [...engine.queries.sessions]
        .map((entity) => entity.session.id)
        .sort(),
    };
  });
}

async function waitForWorld(
  page: Page,
  peers: number,
  sessions: number,
): Promise<void> {
  await page.waitForFunction(
    ([peerCount, sessionCount]) => {
      type Engine = {
        queries: { peers: Iterable<unknown>; sessions: Iterable<unknown> };
      };
      const engine = (globalThis as unknown as {
        __ocv?: { engine?: Engine };
      }).__ocv?.engine;
      return engine !== undefined &&
        [...engine.queries.peers].length === peerCount &&
        [...engine.queries.sessions].length === sessionCount;
    },
    [peers, sessions],
    { timeout: UI_TIMEOUT_MS },
  );
}

function assertWorld(
  actual: WorldSnapshot,
  expectedLabels: string[],
  expectedSessionSuffixes: string[],
): void {
  const labels = actual.peers.map((peer) => peer.label).sort();
  const wantedLabels = [...expectedLabels].sort();
  if (JSON.stringify(labels) !== JSON.stringify(wantedLabels)) {
    fail(
      `expected peer labels ${JSON.stringify(wantedLabels)}, got ${JSON.stringify(labels)}`,
    );
  }
  if (actual.sessions.length !== expectedSessionSuffixes.length) {
    fail(
      `expected ${expectedSessionSuffixes.length} sessions, got ${actual.sessions.length}: ` +
        JSON.stringify(actual.sessions),
    );
  }
  for (const suffix of expectedSessionSuffixes) {
    if (!actual.sessions.some((session) => session.endsWith(`/${suffix}`))) {
      fail(
        `missing session observation ${suffix}: ${JSON.stringify(actual.sessions)}`,
      );
    }
  }
}

async function openPublisher(port: number): Promise<WebSocket> {
  const socket = new WebSocket(`ws://127.0.0.1:${port}/publish`);
  await new Promise<void>((resolve, reject) => {
    socket.onopen = () => resolve();
    socket.onerror = () => reject(new Error("trace producer WebSocket did not open"));
  });
  return socket;
}

function openRecord(session: string, partner: string): string {
  return JSON.stringify({
    v: 1,
    sim_t_ns: 0,
    kind: "ocapn.session-opened",
    session,
    a: "rooms",
    b: partner,
    codec: "syrup",
  });
}

async function startRecording(page: Page): Promise<void> {
  await page.getByRole("button", { name: "Start recording" }).click();
  await page
    .getByRole("alertdialog", { name: "Discard the loaded document?" })
    .getByRole("button", { name: "Record", exact: true })
    .click();
  await page.getByRole("button", { name: "Stop recording" }).waitFor({
    state: "visible",
  });
  await page.getByTitle("The live feed is connected").waitFor({
    state: "visible",
  });
}

async function waitForPaint(page: Page): Promise<void> {
  await page.evaluate(() =>
    new Promise<void>((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
    })
  );
}

for (const asset of requiredAssets) {
  try {
    await Deno.stat(new URL(asset, distRoot));
  } catch {
    fail(`production build omitted ${asset}`);
  }
}

const deadline = setTimeout(() => {
  console.error(
    `FAIL: production Live-mode proof exceeded ${TEST_TIMEOUT_MS}ms`,
  );
  Deno.exit(1);
}, TEST_TIMEOUT_MS);

const staticAbort = new AbortController();
let announceHttp!: (port: number) => void;
const httpReady = new Promise<number>((resolve) => announceHttp = resolve);
const served = new Map<string, number>();
const staticServer = Deno.serve(
  {
    hostname: "127.0.0.1",
    port: 0,
    signal: staticAbort.signal,
    onListen: ({ port }) => announceHttp(port),
  },
  async (request) => {
    let pathname: string;
    try {
      pathname = decodeURIComponent(new URL(request.url).pathname);
    } catch {
      return new Response("bad path", { status: 400 });
    }
    const relative = pathname === "/" ? "index.html" : pathname.slice(1);
    if (relative.split("/").includes("..")) {
      return new Response("forbidden", { status: 403 });
    }
    try {
      const bytes = await Deno.readFile(new URL(relative, distRoot));
      served.set(pathname, (served.get(pathname) ?? 0) + 1);
      return new Response(bytes, {
        headers: {
          "Cache-Control": "no-store",
          "Content-Type": contentType(relative),
        },
      });
    } catch (error) {
      if (error instanceof Deno.errors.NotFound) {
        return new Response("not found", { status: 404 });
      }
      throw error;
    }
  },
);

let vizHost: Deno.ChildProcess | null = null;
let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
let publisher: WebSocket | null = null;

try {
  vizHost = new Deno.Command(Deno.execPath(), {
    args: ["run", "-A", vizHostScript.pathname],
    cwd: repositoryRoot.pathname,
    stdout: "piped",
    stderr: "inherit",
  }).spawn();
  const [httpPort, viz] = await Promise.all([
    httpReady,
    readVizAnnouncement(vizHost.stdout),
  ]);
  const { port: vizPort, sturdyref } = viz;
  publisher = await openPublisher(vizPort);

  browser = await chromium.launch({
    headless: true,
    args: ["--no-sandbox", "--disable-gpu"],
  });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    colorScheme: "dark",
  });
  await context.addInitScript(() => {
    localStorage.removeItem("ocapnviz:app-state");
    localStorage.removeItem("ocapnviz:theme");
  });
  const page = await context.newPage();
  page.setDefaultTimeout(UI_TIMEOUT_MS);
  const browserFailures: string[] = [];
  page.on(
    "pageerror",
    (error) => browserFailures.push(`pageerror: ${error.message}`),
  );
  page.on("console", (message) => {
    if (message.type() === "error") {
      browserFailures.push(`console: ${message.text()}`);
    }
  });
  page.on("requestfailed", (request) => {
    browserFailures.push(
      `request failed: ${request.url()} (${request.failure()?.errorText ?? "unknown"})`,
    );
  });
  page.on("response", (response) => {
    if (response.status() >= 400) {
      browserFailures.push(`HTTP ${response.status()}: ${response.url()}`);
    }
  });

  const pageUrl = `http://127.0.0.1:${httpPort}/?live=${encodeURIComponent(sturdyref)}`;
  await page.goto(pageUrl, { waitUntil: "networkidle" });
  const canvas = page.locator("canvas#ocv-pixi");
  await canvas.waitFor({ state: "visible" });
  await page.getByTitle("The live feed is connected").waitFor({
    state: "visible",
  });
  const emptyCanvas = await canvas.screenshot();

  // Establish the producer's first session through a live capture, then throw
  // that capture away. The next fresh capture can only learn it from replay.
  await startRecording(page);
  publisher.send(openRecord("replay-s1", "alice"));
  await waitForWorld(page, 2, 1);
  await page.getByRole("button", { name: "Discard recording" }).click();
  await page.getByRole("button", { name: "Start recording" }).waitFor({
    state: "visible",
  });

  await startRecording(page);
  await waitForWorld(page, 2, 1);
  await waitForPaint(page);
  const replay = await worldSnapshot(page);
  assertWorld(replay, ["alice", "rooms"], ["replay-s1"]);
  const replayCanvas = await canvas.screenshot();
  if (!bytesDiffer(emptyCanvas, replayCanvas)) {
    fail(
      "replayed topology reached the engine but did not change the rendered canvas",
    );
  }

  publisher.send(openRecord("live-s2", "bob"));
  await waitForWorld(page, 3, 2);
  await waitForPaint(page);
  const live = await worldSnapshot(page);
  assertWorld(live, ["alice", "bob", "rooms"], ["replay-s1", "live-s2"]);
  const liveCanvas = await canvas.screenshot();
  if (!bytesDiffer(replayCanvas, liveCanvas)) {
    fail(
      "live topology reached the engine but did not change the rendered canvas",
    );
  }

  const wasmInitialized = await page.evaluate(() =>
    (globalThis as Record<symbol, unknown>)[
      Symbol.for("pancake.runtime.adapter")
    ] !== undefined
  );
  if (!wasmInitialized) {
    fail("the production tab never installed the wasm runtime adapter");
  }
  if ((served.get("/pancake_host.wasm") ?? 0) < 1) {
    fail("the production tab never requested pancake_host.wasm");
  }
  if (browserFailures.length > 0) {
    fail(`browser failures:\n${browserFailures.join("\n")}`);
  }

  console.log(JSON.stringify({
    sturdyref,
    wasmRequests: served.get("/pancake_host.wasm") ?? 0,
    replay,
    live,
    observerSessionAbsent: replay.sessions.length === 1 &&
      live.sessions.length === 2,
    replayRendered: true,
    liveRendered: true,
  }));
  console.log(
    "PASS: production ocapnviz Live mode is a wasm-backed OCapN viewer",
  );
} finally {
  clearTimeout(deadline);
  publisher?.close();
  if (browser !== null) await browser.close();
  if (vizHost !== null) {
    await stopVizHost(vizHost);
  }
  staticAbort.abort();
  await staticServer.finished.catch(() => {});
}
