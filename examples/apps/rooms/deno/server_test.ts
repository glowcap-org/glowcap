import { type Connection, connect, connectIrohUri, Reachability } from "../../../../bindings/deno/pancake.ts";
import { ROOM, SUBSCRIBE } from "./protocol.ts";

const ROOT = new URL("../../../../", import.meta.url).pathname;
const SERVER = new URL("./server.ts", import.meta.url).pathname;
const RACKET_CLIENT = new URL("../racket/client.rkt", import.meta.url).pathname;
const DENO_FLAGS = ["run", "--allow-ffi", "--allow-read", "--allow-net"];
// iroh dials through the sidecar over nonblocking FFI, which needs broader
// permissions and --unstable-ffi; the server reads its own lib path.
const IROH_FLAGS = ["run", "-A", "--unstable-ffi"];

// The optional iroh ABI superset library (`zig build iroh-abi`, needs cargo).
// The iroh tests below skip when it is absent, matching the demo's
// join-when-available posture, so this suite stays green without cargo.
const IROH_LIB = new URL(
  `../../../../zig-out/lib/${
    Deno.build.os === "darwin"
      ? "libpancake_iroh.dylib"
      : Deno.build.os === "windows"
      ? "pancake_iroh.dll"
      : "libpancake_iroh.so"
  }`,
  import.meta.url,
).pathname;

function irohLibPresent(): boolean {
  try {
    Deno.statSync(IROH_LIB);
    return true;
  } catch {
    return false; // not built (no cargo) — skip the iroh tests
  }
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assertMatch(value: string, pattern: RegExp): void {
  if (!pattern.test(value)) {
    throw new Error(`expected ${JSON.stringify(value)} to match ${pattern}`);
  }
}

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function onPath(cmd: string): Promise<boolean> {
  try {
    const out = await new Deno.Command(cmd, {
      args: ["--version"],
      stdout: "null",
      stderr: "null",
    }).output();
    return out.success;
  } catch {
    return false;
  }
}

async function readPort(proc: Deno.ChildProcess): Promise<number> {
  const reader = proc.stdout.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  const deadline = Date.now() + 10_000;
  try {
    while (Date.now() < deadline) {
      const remaining = deadline - Date.now();
      const chunk = await Promise.race([
        reader.read(),
        delay(remaining).then(() => undefined),
      ]);
      if (chunk === undefined) break;
      const { value, done } = chunk;
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      const match = buf.match(/ROOMS-SERVER-LISTENING (\d+)/);
      if (match) return Number(match[1]);
    }
  } finally {
    reader.releaseLock();
  }
  throw new Error("rooms server never announced its port");
}

async function withServer(fn: (port: number) => Promise<void>): Promise<void> {
  const proc = new Deno.Command("deno", {
    args: [...DENO_FLAGS, SERVER, "0"],
    cwd: ROOT,
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  try {
    await fn(await readPort(proc));
  } finally {
    try {
      proc.kill("SIGTERM");
    } catch {
      // Already gone.
    }
    await proc.status;
  }
}

/** Read the server's announce token (`ROOMS-SERVER-LISTENING <token>`), the iroh
 * ocapn:// URI a client dials. Like `readPort`, but the token is a URI, not a
 * port. */
async function readAnnounce(proc: Deno.ChildProcess): Promise<string> {
  const reader = proc.stdout.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  const deadline = Date.now() + 10_000;
  try {
    while (Date.now() < deadline) {
      const remaining = deadline - Date.now();
      const chunk = await Promise.race([
        reader.read(),
        delay(remaining).then(() => undefined),
      ]);
      if (chunk === undefined) break;
      const { value, done } = chunk;
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      const match = buf.match(/ROOMS-SERVER-LISTENING (\S+)/);
      if (match) return match[1];
    }
  } finally {
    reader.releaseLock();
  }
  throw new Error("rooms server never announced its locator");
}

/** Run the rooms server over iroh and hand its dialable ocapn:// URI to `fn`. */
async function withIrohServer(fn: (uri: string) => Promise<void>): Promise<void> {
  const proc = new Deno.Command("deno", {
    args: [...IROH_FLAGS, SERVER, "--transport=iroh"],
    cwd: ROOT,
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  try {
    await fn(await readAnnounce(proc));
  } finally {
    try {
      proc.kill("SIGTERM");
    } catch {
      // Already gone.
    }
    await proc.status;
  }
}

/** Subscribe one member over an already-dialed connection, return its welcome,
 * and close. The transport (TCP or iroh) is whatever the connection rides. */
async function subscribeOnceConn(conn: Connection, nick: string): Promise<string> {
  conn.serve().catch(() => {});
  const room = await conn.fetch(ROOM);
  const inbox = conn.spawn(() => null);
  const welcome = await conn.send(room, SUBSCRIBE, [nick, inbox]);
  conn.close();
  await conn.serve().catch(() => {});
  return typeof welcome === "string" ? welcome : "";
}

async function subscribeOnce(port: number, nick: string): Promise<string> {
  return subscribeOnceConn(await connect("127.0.0.1", port), nick);
}

async function subscribeOnceIroh(uri: string, nick: string): Promise<string> {
  // Rooms URIs carry direct-addresses, so dial with the explicit `.direct` posture.
  return subscribeOnceConn(await connectIrohUri(uri, Reachability.Direct), nick);
}

async function trySubscribe(port: number, nick: string): Promise<{
  ok: boolean;
  error?: string;
  leave: () => Promise<void>;
}> {
  const conn = await connect("127.0.0.1", port);
  conn.serve().catch(() => {});
  try {
    const room = await conn.fetch(ROOM);
    const inbox = conn.spawn(() => null);
    await conn.send(room, SUBSCRIBE, [nick, inbox]);
    return {
      ok: true,
      leave: async () => {
        conn.close();
        await conn.serve().catch(() => {});
      },
    };
  } catch (err) {
    conn.close();
    await conn.serve().catch(() => {});
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
      leave: async () => {},
    };
  }
}

async function subscribeTwiceAndClose(port: number): Promise<void> {
  const conn = await connect("127.0.0.1", port);
  conn.serve().catch(() => {});
  const room = await conn.fetch(ROOM);
  const inbox = conn.spawn(() => null);
  await conn.send(room, SUBSCRIBE, ["first-a", inbox]);
  await conn.send(room, SUBSCRIBE, ["first-b", inbox]);
  conn.close();
  await conn.serve().catch(() => {});
}

async function resubscribeAndHold(port: number): Promise<{
  leave: () => Promise<void>;
}> {
  const conn = await connect("127.0.0.1", port);
  conn.serve().catch(() => {});
  const room = await conn.fetch(ROOM);
  const inbox = conn.spawn(() => null);
  await conn.send(room, SUBSCRIBE, ["first-a", inbox]);
  await conn.send(room, SUBSCRIBE, ["first-b", inbox]);
  return {
    leave: async () => {
      conn.close();
      await conn.serve().catch(() => {});
    },
  };
}

async function waitForMatch(
  getValue: () => Promise<string>,
  pattern: RegExp,
): Promise<string> {
  const deadline = Date.now() + 2_000;
  let last = "";
  while (Date.now() < deadline) {
    last = await getValue();
    if (pattern.test(last)) return last;
    await delay(25);
  }
  throw new Error(`expected ${JSON.stringify(last)} to match ${pattern}`);
}

async function watchRoomConn(conn: Connection, nick: string): Promise<{
  lines: string[];
  leave: () => Promise<void>;
}> {
  conn.serve().catch(() => {});
  const lines: string[] = [];
  const room = await conn.fetch(ROOM);
  const inbox = conn.spawn((_verb, args) => {
    const from = typeof args[0] === "string" ? args[0] : "?";
    const text = typeof args[1] === "string" ? args[1] : "";
    lines.push(`${from}: ${text}`);
    return null;
  });
  await conn.send(room, SUBSCRIBE, [nick, inbox]);
  return {
    lines,
    leave: async () => {
      conn.close();
      await conn.serve().catch(() => {});
    },
  };
}

async function watchRoom(port: number, nick: string) {
  return watchRoomConn(await connect("127.0.0.1", port), nick);
}

async function watchRoomIroh(uri: string, nick: string) {
  // Rooms URIs carry direct-addresses, so dial with the explicit `.direct` posture.
  return watchRoomConn(await connectIrohUri(uri, Reachability.Direct), nick);
}

async function waitForLine(lines: string[], pattern: RegExp): Promise<string> {
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    const found = lines.find((line) => pattern.test(line));
    if (found) return found;
    await delay(25);
  }
  throw new Error(`expected ${JSON.stringify(lines)} to contain ${pattern}`);
}

Deno.test("rooms server removes members that close cleanly", async () => {
  await withServer(async (port) => {
    assertMatch(await subscribeOnce(port, "first"), /1 in the room: first$/);

    await waitForMatch(
      () => subscribeOnce(port, "second"),
      /1 in the room: second$/,
    );
  });
});

Deno.test("rooms server removes every membership for a closed connection", async () => {
  await withServer(async (port) => {
    await subscribeTwiceAndClose(port);

    await waitForMatch(
      () => subscribeOnce(port, "second"),
      /1 in the room: second$/,
    );
  });
});

Deno.test("rooms server grants each live nickname once", async () => {
  await withServer(async (port) => {
    const first = await trySubscribe(port, "Claimed");
    assert(first.ok, "first claim should succeed");
    const duplicate = await trySubscribe(port, "claimed");
    assert(!duplicate.ok, "duplicate live claim should fail");
    assertMatch(duplicate.error ?? "", /name "claimed" is already claimed/);

    await first.leave();

    const reclaimed = await trySubscribe(port, "CLAIMED");
    assert(reclaimed.ok, "released name should be claimable again");
    await reclaimed.leave();
  });
});

Deno.test("rooms server resubscribe replaces one connection's claimed nickname", async () => {
  await withServer(async (port) => {
    const holder = await resubscribeAndHold(port);

    const oldName = await trySubscribe(port, "first-a");
    assert(oldName.ok, "old name should be released by resubscribe");
    const currentName = await trySubscribe(port, "first-b");
    assert(
      !currentName.ok,
      "new name should remain claimed while holder lives",
    );
    assertMatch(currentName.error ?? "", /name "first-b" is already claimed/);

    await oldName.leave();
    await holder.leave();
  });
});

Deno.test("rooms server announces members leaving", async () => {
  await withServer(async (port) => {
    const watcher = await watchRoom(port, "watcher");
    const leaver = await watchRoom(port, "leaver");
    await waitForLine(watcher.lines, /^room: leaver joined \(2 here\)$/);

    await leaver.leave();

    await waitForLine(watcher.lines, /^room: leaver left \(1 here\)$/);
    await watcher.leave();
  });
});

Deno.test("racket one-shot client exits by its deadline while unrelated traffic continues", async () => {
  if (!(await onPath("racket"))) return;

  await withServer(async (port) => {
    const proc = new Deno.Command("racket", {
      args: [
        RACKET_CLIENT,
        `127.0.0.1:${port}`,
        "rkt-alan",
        "hello from racket",
        "rkt-alan,missing",
        "250",
      ],
      cwd: ROOT,
      stdout: "piped",
      stderr: "piped",
    }).spawn();

    let keepNoising = true;
    const noise = (async () => {
      for (let i = 0; keepNoising; i += 1) {
        await subscribeOnce(port, `noise-${i}`).catch(() => {});
        await delay(40);
      }
    })();

    const timedOut = { kind: "timed out" } as const;
    const result = await Promise.race([
      proc.output(),
      delay(2_000).then(() => timedOut),
    ]);
    keepNoising = false;
    await noise;
    if ("kind" in result) {
      try {
        proc.kill("SIGTERM");
      } catch {
        // Already gone.
      }
      await proc.status;
      throw new Error(
        "racket client did not exit when the roster could not complete",
      );
    }

    const stderr = new TextDecoder().decode(result.stderr);
    assert(
      !result.success,
      "racket client should fail for an impossible roster",
    );
    assertMatch(stderr, /roster did not complete/);
    assertMatch(stderr, /missing: missing/);
    assert(
      !stderr.includes("missing: rkt-alan"),
      "local member should not be reported missing",
    );
  });
});

// The same room semantics over iroh's encrypted QUIC instead of TCP. These dial
// the server's announced ocapn:// URI through the iroh ABI superset, so they
// skip cleanly when that optional library is not built (no cargo). The room's
// wire and behavior are identical — only the transport differs.

Deno.test("rooms server over iroh welcomes a subscriber by its ocapn:// URI", async () => {
  if (!irohLibPresent()) return; // needs `zig build iroh-abi` (cargo)
  await withIrohServer(async (uri) => {
    assertMatch(uri, /^ocapn:\/\/[0-9a-f]+\.iroh/);
    assertMatch(await subscribeOnceIroh(uri, "iroh-first"), /1 in the room: iroh-first$/);
    // A name freed by a clean close is grantable again to the next dialer.
    await waitForMatch(
      () => subscribeOnceIroh(uri, "iroh-second"),
      /1 in the room: iroh-second$/,
    );
  });
});

Deno.test("rooms server over iroh broadcasts joins and leaves through the capability callback", async () => {
  if (!irohLibPresent()) return; // needs `zig build iroh-abi` (cargo)
  await withIrohServer(async (uri) => {
    const watcher = await watchRoomIroh(uri, "iroh-watcher");
    const leaver = await watchRoomIroh(uri, "iroh-leaver");
    await waitForLine(watcher.lines, /^room: iroh-leaver joined \(2 here\)$/);

    await leaver.leave();

    await waitForLine(watcher.lines, /^room: iroh-leaver left \(1 here\)$/);
    await watcher.leave();
  });
});
