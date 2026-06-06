// Deno dogfood of the Zig libpancake C ABI, through the idiomatic `pancake.ts`
// module: drive OCapN with native values and typed events — no FFI in sight.
// This is the consumer `zig build bindings` runs.

import { AsyncConnection, abiVersion, Context, type Event, far, type HostAllocator, Peer } from "./pancake.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) {
    console.error(`deno zig-smoke FAILED: ${msg}`);
    Deno.exit(1);
  }
}

function eqBytes(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

// The linked library reports a real ABI version.
const [major, minor, patch] = abiVersion();
assert(major + minor + patch > 0, `abiVersion is nonzero, got ${major}.${minor}.${patch}`);

// Drive a peer created in a context backed by a host allocator, and feed it an
// owned frame: the bytes transfer into the inbound queue and a deliver surfaces.
{
  let allocs = 0, frees = 0;
  const allocator: HostAllocator = {
    alloc(size, _alignment) {
      allocs++;
      return new Uint8Array(size);
    },
    free(_block, _size, _alignment) {
      frees++;
    },
  };
  using ctx = Context.withAllocator(allocator);
  using peer = Peer.newIn(ctx);
  peer.registerExport(7n);
  peer.feedOwned(new TextEncoder().encode("<10'op:deliver<11'desc:export7+>[5:hello]11+f>"));
  peer.step();
  const event: Event | null = peer.poll();
  assert(event?.kind === "deliver", `feedOwned-in-context surfaced a deliver, got ${event?.kind}`);
  if (event?.kind === "deliver") {
    assert(event.target.kind === "near" && event.target.id === 7n, "owned target is near export 7");
    assert(event.args.length === 1 && event.args[0] instanceof Uint8Array, "owned deliver has one bytes arg");
  }
  assert(allocs > 0, `custom allocator served allocations, got ${allocs}`);
}

// Construct a call with native args and read it back as a typed Event.
const caller = new Peer();
try {
  caller.registerImport(5n);
  caller.sendDeliver(far(5n), [42n, new TextEncoder().encode("hi")], 9n);
  caller.step();
  const wire = caller.takeOutbound();
  assert(wire !== null, "took an outbound frame");
  assert(
    new TextDecoder().decode(wire!).startsWith("<10'op:deliver"),
    "constructed a real op:deliver",
  );
} finally {
  caller.release();
}

const callee = new Peer();
try {
  callee.registerExport(7n);
  callee.feed(new TextEncoder().encode("<10'op:deliver<11'desc:export7+>[5:hello]11+f>"));
  const event: Event | null = callee.poll();
  assert(event?.kind === "deliver", `expected a deliver, got ${event?.kind}`);
  if (event?.kind === "deliver") {
    assert(event.target.kind === "near" && event.target.id === 7n, "target is near export 7");
    assert(event.answer === 11n, "answer is 11");
    assert(event.args.length === 1 && event.args[0] instanceof Uint8Array, "one bytes arg");
    assert(eqBytes(event.args[0] as Uint8Array, new TextEncoder().encode("hello")), "arg is 'hello'");
  }
} finally {
  callee.release();
}

// An inbound abort surfaces as a typed Event.
const peer = new Peer();
try {
  peer.feed(new TextEncoder().encode('<8\'op:abort3"bye>'));
  const abort = peer.poll();
  assert(abort?.kind === "other" && abort.eventKind === 7, "abort surfaced as a typed event");
  assert(peer.poll() === null, "no further events");
} finally {
  peer.release();
}

// Native async: a loopback over Deno networking. The server exports 7 and
// replies to the first deliver with a Fulfill; the client imports 7, calls it
// with answer 9, and awaits a Resolve settling 9 with the fulfilled value.
{
  const listener = Deno.listen({ port: 0 });
  const port = (listener.addr as Deno.NetAddr).port;

  async function server(): Promise<void> {
    const conn = await listener.accept();
    const peer = new Peer();
    peer.registerExport(7n);
    const ac = AsyncConnection.fromConn(peer, conn);
    try {
      const ev = await ac.nextEvent();
      assert(ev?.kind === "deliver", `server saw a deliver, got ${ev?.kind}`);
      if (ev?.kind === "deliver") {
        assert(ev.target.kind === "near" && ev.target.id === 7n, "server target is near export 7");
        assert(ev.answer === 9n, "server deliver carries answer 9");
        assert(ev.args.length === 1 && ev.args[0] === 42n, "server deliver has one integer arg 42");
        await ac.sendResolve(ev.answer!, { fulfill: 1337n });
      }
    } finally {
      ac.close();
    }
  }

  async function client(): Promise<void> {
    const ac = await AsyncConnection.connect("127.0.0.1", port);
    try {
      ac.peer.registerImport(7n);
      await ac.sendDeliver(far(7n), [42n], 9n);
      const ev = await ac.nextEvent();
      assert(ev?.kind === "resolve", `client saw a resolve, got ${ev?.kind}`);
      if (ev?.kind === "resolve") {
        assert(ev.answer === 9n, "client resolve settles answer 9");
        assert("fulfill" in ev.resolution, "client resolve is a fulfill");
        if ("fulfill" in ev.resolution) {
          assert(ev.resolution.fulfill === 1337n, "client resolve fulfills with 1337");
        }
      }
    } finally {
      ac.close();
    }
  }

  try {
    await Promise.all([server(), client()]);
  } finally {
    listener.close();
  }
  console.log("deno zig-smoke OK: drove OCapN async over Deno networking");
}

console.log("deno zig-smoke OK: drove OCapN through the idiomatic pancake API");
