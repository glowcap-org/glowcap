// Dialing a live feed: connect, disconnect, inbox, and the wasm peer.

import { assert, assertEquals } from "@std/assert";
import { LiveFeed, type LivePeerFactory } from "../connection.ts";
import { startLiveMode } from "../mode.ts";
import type { TimelineEvent } from "../../timeline.ts";
import type { PancakeWebModule } from "../pancake-web-api.ts";

Deno.test("connect: an invalid sturdyref is reported, not thrown", () => {
  const feed = new LiveFeed("w");
  const seen: string[] = [];
  feed.onError((e) => seen.push(e.detail));
  feed.connect();
  assertEquals(seen.length, 1);
  assert(
    seen[0]!.includes('"w"'),
    `the report names the value; got ${seen[0]}`,
  );
  feed.disconnect();
});

Deno.test("startLiveMode: an invalid sturdyref still returns a live handle", () => {
  const seen: string[] = [];
  const handle = startLiveMode({
    sturdyref: "ws:/",
    onError: (e) => seen.push(e.detail),
  });
  assertEquals(seen.length, 1);
  assert(handle.engine.doc.id === "live");
  handle.dispose();
});

type ControlledPeer = {
  closeCount: number;
  finish: () => void;
};

function controlledFactory(): {
  factory: LivePeerFactory;
  peers: ControlledPeer[];
  records: Array<(line: string) => void>;
} {
  const peers: ControlledPeer[] = [];
  const records: Array<(line: string) => void> = [];
  const factory: LivePeerFactory = (_ref, onRecord) => {
    let finish!: () => void;
    const closed = new Promise<void>((resolve) => finish = resolve);
    const control: ControlledPeer = { closeCount: 0, finish };
    peers.push(control);
    records.push(onRecord);
    return Promise.resolve({
      closed,
      close: () => {
        control.closeCount += 1;
        finish();
      },
    });
  };
  return { factory, peers, records };
}

Deno.test("disconnect closes the exact peer once and a late close reaches nobody", async () => {
  const controlled = controlledFactory();
  const feed = new LiveFeed(
    "ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
    controlled.factory,
  );
  let connected: boolean | null = null;
  feed.onConnectionChange((v) => connected = v);
  feed.connect();
  await Promise.resolve();
  assertEquals(connected, true);
  feed.disconnect();
  assertEquals(controlled.peers[0]?.closeCount, 1);
  connected = null;
  controlled.peers[0]?.finish();
  await Promise.resolve();
  assertEquals(
    connected,
    null,
    "a disposed feed wrote its close into a live subscriber",
  );
});

Deno.test("onConnectionChange: the unsubscribe releases the slot", async () => {
  const controlled = controlledFactory();
  const feed = new LiveFeed(
    "ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
    controlled.factory,
  );
  let connected: boolean | null = null;
  const off = feed.onConnectionChange((v) => connected = v);
  feed.connect();
  off();
  await Promise.resolve();
  assertEquals(connected, null);
  feed.disconnect();
});

Deno.test("records arrive through the hosted inbox callback", async () => {
  const controlled = controlledFactory();
  const feed = new LiveFeed(
    "ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
    controlled.factory,
  );
  const seen: TimelineEvent[] = [];
  feed.subscribe((ev) => seen.push(ev));
  feed.connect();
  await Promise.resolve();
  controlled.records[0]?.(JSON.stringify({
    v: 1,
    sim_t_ns: 0,
    seq: 10,
    epoch: 1,
    kind: "ocapn.session-opened",
    session: "p0/s1",
    a: "rooms",
    b: "alice",
    codec: "syrup",
  }));
  assertEquals(seen.filter((ev) => ev.kind === "session-opened").length, 1);
  feed.disconnect();
});

Deno.test("old replay sequence numbers still form an authoritative snapshot", async () => {
  const controlled = controlledFactory();
  const feed = new LiveFeed(
    "ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
    controlled.factory,
  );
  const seen: TimelineEvent[] = [];
  feed.subscribe((ev) => seen.push(ev));
  feed.connect();
  await Promise.resolve();
  const open = {
    v: 1,
    sim_t_ns: 0,
    seq: 10,
    epoch: 1,
    kind: "ocapn.session-opened",
    session: "p0/s1",
    a: "rooms",
    b: "alice",
    codec: "syrup",
  };
  controlled.records[0]?.(JSON.stringify(open));
  controlled.records[0]?.(JSON.stringify({ ...open, replay: true }));
  controlled.records[0]?.(JSON.stringify({
    v: 1,
    sim_t_ns: 1_000_000,
    epoch: 1,
    kind: "trace.replay-end",
  }));
  assertEquals(
    seen.filter((ev) => ev.kind === "session-unobserved").length,
    0,
    "stale-sequence suppression discarded current snapshot state",
  );
  feed.disconnect();
});

Deno.test({
  name: "a dropped peer reconnects with a fresh session and inbox",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const controlled = controlledFactory();
    const feed = new LiveFeed(
      "ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
      controlled.factory,
    );
    const states: boolean[] = [];
    feed.onConnectionChange((connected) => states.push(connected));
    feed.connect();
    await Promise.resolve();
    controlled.peers[0]?.finish();
    await new Promise((resolve) => setTimeout(resolve, 550));
    await Promise.resolve();
    assertEquals(controlled.peers.length, 2);
    assert(controlled.records[0] !== controlled.records[1]);
    assertEquals(states, [true, false, true]);
    feed.disconnect();
    assertEquals(controlled.peers[1]?.closeCount, 1);
  },
});

const browserWasm = new URL(
  "../../../../zig-out/wasm/pancake_host.wasm",
  import.meta.url,
);
let browserWasmExists = true;
try {
  await Deno.stat(browserWasm);
} catch (error) {
  if (error instanceof Deno.errors.NotFound) browserWasmExists = false;
  else throw error;
}

Deno.test({
  name: "the lazy wasm browser peer enlivens, subscribes, and receives a live record",
  ignore: !browserWasmExists,
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const root = new URL("../../../../", import.meta.url);
    const hostScript = new URL(
      "../../../rooms/test/viz_browser_host.ts",
      import.meta.url,
    );
    const child = new Deno.Command(Deno.execPath(), {
      args: ["run", "-A", hostScript.pathname],
      cwd: root.pathname,
      stdout: "piped",
      stderr: "inherit",
    }).spawn();
    const reader = child.stdout.getReader();
    let wasmObjectUrl: string | null = null;
    let feed: LiveFeed | null = null;
    let publisher: WebSocket | null = null;
    try {
      const ready = await readJsonLine(reader) as {
        port: number;
        sturdyref: string;
      };
      const registry = globalThis as Record<symbol, unknown>;
      const adapterKey = Symbol.for("pancake.runtime.adapter");
      assertEquals(
        registry[adapterKey],
        undefined,
        "importing LiveFeed eagerly initialized the browser runtime",
      );

      const wasm = await Deno.readFile(browserWasm);
      wasmObjectUrl = URL.createObjectURL(
        new Blob([wasm], { type: "application/wasm" }),
      );
      (globalThis as { __OCV_PANCAKE_WASM_URL?: string })
        .__OCV_PANCAKE_WASM_URL = wasmObjectUrl;
      const webModuleName: string = "@pancake/web";
      (globalThis as {
        __OCV_PANCAKE_WEB_LOADER?: () => Promise<PancakeWebModule>;
      }).__OCV_PANCAKE_WEB_LOADER = () => import(webModuleName) as unknown as Promise<PancakeWebModule>;

      let connected!: () => void;
      const didConnect = new Promise<void>((resolve) => connected = resolve);
      feed = new LiveFeed(ready.sturdyref);
      let fail!: (cause: unknown) => void;
      const didFail = new Promise<never>((_, reject) => fail = reject);
      feed.onError((error) => fail(error.cause ?? new Error(error.detail)));
      feed.onConnectionChange((value) => {
        if (value) connected();
      });
      const received: TimelineEvent[] = [];
      let sawSession!: () => void;
      const didReceive = new Promise<void>((resolve) => sawSession = resolve);
      feed.subscribe((event) => {
        received.push(event);
        if (event.kind === "session-opened") sawSession();
      });
      feed.connect();
      await Promise.race([didConnect, didFail]);
      assert(
        registry[adapterKey] !== undefined,
        "Live mode did not initialize wasm",
      );

      publisher = new WebSocket(`ws://127.0.0.1:${ready.port}/publish`);
      await new Promise<void>((resolve, reject) => {
        publisher!.onopen = () => resolve();
        publisher!.onerror = () => reject(new Error("publisher did not open"));
      });
      publisher.send(JSON.stringify({
        v: 1,
        sim_t_ns: 0,
        kind: "ocapn.session-opened",
        session: "browser-proof-s1",
        a: "rooms",
        b: "alice",
        codec: "syrup",
      }));
      await Promise.race([didReceive, didFail]);
      assertEquals(
        received.filter((event) => event.kind === "session-opened").length,
        1,
      );
    } finally {
      publisher?.close();
      feed?.disconnect();
      delete (globalThis as { __OCV_PANCAKE_WASM_URL?: string })
        .__OCV_PANCAKE_WASM_URL;
      delete (globalThis as { __OCV_PANCAKE_WEB_LOADER?: unknown })
        .__OCV_PANCAKE_WEB_LOADER;
      if (wasmObjectUrl !== null) URL.revokeObjectURL(wasmObjectUrl);
      reader.releaseLock();
      try {
        child.kill("SIGTERM");
      } catch {
        // already exited
      }
      await child.status;
    }
  },
});

async function readJsonLine(
  reader: ReadableStreamDefaultReader<Uint8Array>,
): Promise<unknown> {
  const decoder = new TextDecoder();
  let buffered = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) {
      throw new Error("viz host exited before announcing its capability");
    }
    buffered += decoder.decode(value, { stream: true });
    const newline = buffered.indexOf("\n");
    if (newline >= 0) return JSON.parse(buffered.slice(0, newline));
  }
}
