import { Room } from "./room_client.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;
const WEB = new URL("./web.ts", import.meta.url).pathname;
const DENO_FLAGS = [
  "run",
  "--allow-ffi",
  "--allow-read",
  "--allow-net",
  "--allow-run",
];

type BrowserMessage = {
  from: string;
  text: string;
  fatal?: string;
  presence?: { kind: string; name?: string; names?: string[] } | null;
};

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function freePort(): number {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const port = (listener.addr as Deno.NetAddr).port;
  listener.close();
  return port;
}

async function waitForHttp(port: number): Promise<string> {
  const deadline = Date.now() + 10_000;
  let lastError: unknown;
  while (Date.now() < deadline) {
    try {
      return await fetch(`http://127.0.0.1:${port}/`).then((response) =>
        response.text()
      );
    } catch (err) {
      lastError = err;
      await delay(50);
    }
  }
  throw new Error(`rooms web UI did not start: ${lastError}`);
}

async function withWeb(
  fn: (httpPort: number, roomPort: number) => Promise<void>,
): Promise<void> {
  const httpPort = freePort();
  const roomPort = freePort();
  const proc = new Deno.Command("deno", {
    args: [...DENO_FLAGS, WEB, String(httpPort), String(roomPort)],
    cwd: ROOT,
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  try {
    await fn(httpPort, roomPort);
  } finally {
    try {
      proc.kill("SIGINT");
    } catch {
      // Already gone.
    }
    await proc.status;
  }
}

function openSocket(port: number, nick: string): Promise<{
  ws: WebSocket;
  messages: BrowserMessage[];
}> {
  const messages: BrowserMessage[] = [];
  const ws = new WebSocket(
    `ws://127.0.0.1:${port}/ws?nick=${encodeURIComponent(nick)}`,
  );
  return new Promise((resolve, reject) => {
    ws.onopen = () => resolve({ ws, messages });
    ws.onerror = () => reject(new Error("browser WebSocket failed to open"));
    ws.onmessage = (event) => messages.push(JSON.parse(String(event.data)));
  });
}

async function waitForPresence(
  messages: BrowserMessage[],
  match: (message: BrowserMessage) => boolean,
): Promise<BrowserMessage> {
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    const found = messages.find(match);
    if (found) return found;
    await delay(25);
  }
  throw new Error(`expected presence message in ${JSON.stringify(messages)}`);
}

async function waitForMessage(
  messages: BrowserMessage[],
  match: (message: BrowserMessage) => boolean,
): Promise<BrowserMessage> {
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    const found = messages.find(match);
    if (found) return found;
    await delay(25);
  }
  throw new Error(`expected browser message in ${JSON.stringify(messages)}`);
}

Deno.test("rooms web bridge sends browser presence for all room members", async () => {
  await withWeb(async (httpPort, roomPort) => {
    const page = await waitForHttp(httpPort);
    assert(
      page.includes('id="presenceSummary"'),
      "page should include the presence summary",
    );
    assert(
      page.includes('id="members"'),
      "page should include the presence list",
    );
    assert(
      page.includes('id="nickError"'),
      "page should include a username error region",
    );

    const { ws, messages } = await openSocket(httpPort, "browser-ada");
    try {
      await waitForPresence(
        messages,
        (message) =>
          message.presence?.kind === "roster" &&
          message.presence.names?.includes("browser-ada") === true,
      );

      const cli = await Room.join(`127.0.0.1:${roomPort}`, "cli-grace");
      await waitForPresence(
        messages,
        (message) =>
          message.presence?.kind === "join" &&
          message.presence.name === "cli-grace",
      );

      await cli.leave();
      await waitForPresence(
        messages,
        (message) =>
          message.presence?.kind === "leave" &&
          message.presence.name === "cli-grace",
      );
    } finally {
      ws.close();
    }
  });
});

Deno.test("rooms web bridge rejects a duplicate browser nickname", async () => {
  await withWeb(async (httpPort) => {
    await waitForHttp(httpPort);
    const first = await openSocket(httpPort, "Browser-Ada");
    const second = await openSocket(httpPort, "browser-ada");
    try {
      await waitForPresence(
        first.messages,
        (message) =>
          message.presence?.kind === "roster" &&
          message.presence.names?.includes("Browser-Ada") === true,
      );
      await waitForMessage(
        second.messages,
        (message) =>
          message.from === "room" &&
          message.fatal === "name-taken" &&
          /name "browser-ada" is already claimed/.test(message.text),
      );
    } finally {
      first.ws.close();
      second.ws.close();
    }
  });
});
