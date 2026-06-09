// Deno dogfood of the Zig libpancake C ABI, through the idiomatic `pancake.ts`
// module: drive OCapN with native values and typed events — no FFI in sight.
// This is the consumer `zig build bindings` runs.

import {
  type Argument,
  AsyncConnection,
  abiVersion,
  Connection,
  Context,
  type Event,
  far,
  FarRef,
  type HostAllocator,
  Peer,
  Ref,
  Vat,
} from "./pancake.ts";

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

// A counter behavior reused by the actor tests: "add" adds args[0] to the
// count and returns it, "get" reads it, anything else throws (a break).
function counterBehavior(start: bigint): (verb: string, args: Argument[]) => Argument {
  let count = start;
  return (verb: string, args: Argument[]): Argument => {
    if (verb === "add") {
      const n = args[0];
      count += typeof n === "bigint" ? n : BigInt(n as number);
      return count;
    }
    if (verb === "get") return count;
    throw new Error(`unknown verb ${verb}`);
  };
}

// Actor layer: publish a counter actor at export 7 and drive it from a syrup
// deliver. The leading symbol is the verb.
{
  const actorPeer = new Peer();
  try {
    const vat = new Vat(actorPeer);
    vat.publish(7n, counterBehavior(10n));

    // counter.add(5) with answer 11: <10'op:deliver<11'desc:export7+>[3'add5+]11+f>
    actorPeer.feed(new TextEncoder().encode("<10'op:deliver<11'desc:export7+>[3'add5+]11+f>"));
    const ev: Event | null = actorPeer.poll();
    assert(ev?.kind === "deliver", `actor vat saw a deliver, got ${ev?.kind}`);
    assert(vat.serve(ev!), "vat served the deliver to the published export");

    actorPeer.step();
    const reply = actorPeer.takeOutbound();
    assert(reply !== null, "vat emitted a resolve frame");
    const text = new TextDecoder().decode(reply!);
    assert(text.includes("op:resolve"), `actor reply is an op:resolve, got ${text}`);
    assert(text.includes("15+"), `actor reply fulfills the new count 15, got ${text}`);
  } finally {
    actorPeer.release();
  }
  console.log("deno zig-smoke OK: drove a published actor round-trip");
}

// Far-send round-trip across the local|far seam. Two fresh peers (no handshake):
// peerB's vat publishes a counter at export 7; peerA's vat far-sends
// counter.add(5) to far(7), gets a far vow, and registers an `on` listener.
// Shuttle A's outbound to B, B serves the deliver (count 10 -> 15, resolves),
// shuttle the resolve back, A serves it (fires the listener) -> captured 15.
{
  const peerA = new Peer();
  const peerB = new Peer();
  try {
    const vatA = new Vat(peerA);
    const vatB = new Vat(peerB);

    // peerB hosts the counter; peerA holds it as an import it can far-send to.
    vatB.publish(7n, counterBehavior(10n));
    peerA.registerImport(7n);

    // peerA: location-transparent send to a far ref returns a far vow.
    const vow = vatA.send(new FarRef(far(7n)), "add", [5n]);
    assert(vow.location === "far", "a far send returns a far vow");
    let captured: bigint | null = null;
    vatA.on(vow, (value: Argument) => {
      captured = typeof value === "bigint" ? value : null;
    });

    // Shuttle A -> B: deliver.
    peerA.step();
    const toB = peerA.takeOutbound();
    assert(toB !== null, "peerA emitted the far deliver");
    peerB.feed(toB!);
    const deliverEv = peerB.poll();
    assert(deliverEv?.kind === "deliver", `peerB saw a deliver, got ${deliverEv?.kind}`);
    assert(vatB.serve(deliverEv!), "vatB served the far deliver");

    // Shuttle B -> A: resolve.
    peerB.step();
    const toA = peerB.takeOutbound();
    assert(toA !== null, "peerB emitted the resolve");
    peerA.feed(toA!);
    const resolveEv = peerA.poll();
    assert(resolveEv?.kind === "resolve", `peerA saw a resolve, got ${resolveEv?.kind}`);
    assert(vatA.serve(resolveEv!), "vatA served the resolve, firing the far vow");

    assert(captured === 15n, `far vow fired with the new count 15, got ${captured}`);
  } finally {
    peerA.release();
    peerB.release();
  }
  console.log("deno zig-smoke OK: drove a far-send round-trip across the local|far seam");
}

// Connection surface: an outstanding `send` rejects when the wire drops instead
// of hanging on a reply that can never arrive. The server reads the client's
// deliver and then closes without answering; the client's awaited far `send`
// must settle broken once `serve` sees the disconnect.
{
  const listener = Deno.listen({ port: 0 });
  const port = (listener.addr as Deno.NetAddr).port;

  async function server(): Promise<void> {
    const tcp = await listener.accept();
    // Complete the responder handshake (the client's `connect` handshakes), then
    // read the client's deliver and drop the connection unanswered.
    const peer = Peer.newNegotiating();
    peer.registerExport(7n); // admit the client's deliver instead of aborting it
    const ac = AsyncConnection.fromConn(peer, tcp);
    const la = tcp.localAddr as Deno.NetAddr;
    peer.startSessionKeyed({
      transport: "tcp",
      designator: `${la.hostname}:${la.port}`,
      seed: crypto.getRandomValues(new Uint8Array(32)),
      hintsEmptyFalse: true,
    });
    await ac.flush();
    while (!peer.sessionIsOpen()) {
      if ((await ac.nextEvent()) === null) return;
    }
    await ac.nextEvent(); // the client's deliver
    ac.close();
  }

  async function client(): Promise<void> {
    const conn = await Connection.connect("127.0.0.1", port);
    conn.serve().catch(() => {}); // a disconnect ends the serve loop; expected here
    conn.peer.registerImport(7n);
    let rejected = false;
    try {
      await conn.send(new Ref(far(7n), null), "ping", []);
    } catch (_err) {
      rejected = true;
    }
    assert(rejected, "an outstanding send rejects when the connection drops");
    conn.close();
  }

  try {
    await Promise.all([server(), client()]);
  } finally {
    listener.close();
  }
  console.log("deno zig-smoke OK: an outstanding send rejects on disconnect");
}

console.log("deno zig-smoke OK: drove OCapN through the idiomatic pancake API");
