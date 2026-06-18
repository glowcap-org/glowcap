// Cross-runtime dogfood of the Zig pancake C ABI archives, through the idiomatic
// composable modules (`mod.ts` core + `tcp.ts`/`inproc.ts` transports): drive
// OCapN with native values and typed events — no FFI in sight. It runs
// identically on Deno, Bun, and (experimentally) Node, which is the proof the
// binding is runtime-neutral. This is the consumer `zig build bindings` runs.

import process from "node:process";
import {
	abiVersion,
	type AbortDetail,
	type AppValue,
	type Argument,
	AsyncConnection,
	Connection,
	connectTcp,
	Context,
	type Event,
	far,
	FarRef,
	FetchFailed,
	type HostAllocator,
	listen,
	listenTcp,
	type NetConn,
	PancakeError,
	Peer,
	PSet,
	Ref,
	Sym,
	Tagged,
	tagged,
	Vat,
	VowBroken,
} from "./mod.ts";
import { Netlayer as TcpNetlayer } from "./transport/tcp.ts";
import { Netlayer as InprocNetlayer } from "./transport/inproc.ts";

const runtime = typeof (globalThis as { Bun?: unknown }).Bun !== "undefined"
	? "bun"
	: typeof (globalThis as { Deno?: unknown }).Deno !== "undefined"
	? "deno"
	: "node";

function assert(cond: boolean, msg: string): void {
	if (!cond) {
		console.error(`${runtime} zig-smoke FAILED: ${msg}`);
		process.exit(1);
	}
}

function ok(msg: string): void {
	console.log(`${runtime} zig-smoke OK: ${msg}`);
}

function eqBytes(a: Uint8Array, b: Uint8Array): boolean {
	return a.length === b.length && a.every((v, i) => v === b[i]);
}

// The linked library reports a real ABI version.
const [major, minor, patch] = abiVersion();
assert(
	major + minor + patch > 0,
	`abiVersion is nonzero, got ${major}.${minor}.${patch}`,
);

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
	using peer = Peer.rawOpenIn(ctx);
	peer.registerExport(7n);
	peer.feedOwned(
		new TextEncoder().encode("<10'op:deliver<11'desc:export7+>[5:hello]11+f>"),
	);
	peer.step();
	const event: Event | null = peer.poll();
	assert(
		event?.kind === "deliver",
		`feedOwned-in-context surfaced a deliver, got ${event?.kind}`,
	);
	if (event?.kind === "deliver") {
		assert(
			event.target.kind === "near" && event.target.id === 7n,
			"owned target is near export 7",
		);
		assert(
			event.args.length === 1 && event.args[0] instanceof Uint8Array,
			"owned deliver has one bytes arg",
		);
	}
	assert(allocs > 0, `custom allocator served allocations, got ${allocs}`);
}

// Construct a call with native args and read it back as a typed Event.
const caller = Peer.rawOpen();
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

const callee = Peer.rawOpen();
try {
	callee.registerExport(7n);
	callee.feed(
		new TextEncoder().encode("<10'op:deliver<11'desc:export7+>[5:hello]11+f>"),
	);
	const event: Event | null = callee.poll();
	assert(event?.kind === "deliver", `expected a deliver, got ${event?.kind}`);
	if (event?.kind === "deliver") {
		assert(
			event.target.kind === "near" && event.target.id === 7n,
			"target is near export 7",
		);
		assert(event.answer === 11n, "answer is 11");
		assert(
			event.args.length === 1 && event.args[0] instanceof Uint8Array,
			"one bytes arg",
		);
		assert(
			eqBytes(event.args[0] as Uint8Array, new TextEncoder().encode("hello")),
			"arg is 'hello'",
		);
	}
} finally {
	callee.release();
}

// An inbound abort surfaces as a typed Event.
const peer = Peer.rawOpen();
try {
	peer.feed(new TextEncoder().encode("<8'op:abort3\"bye>"));
	const abort = peer.poll();
	assert(
		abort?.kind === "other" && abort.eventKind === 7,
		"abort surfaced as a typed event",
	);
	assert(peer.poll() === null, "no further events");
} finally {
	peer.release();
}

// Native async: a loopback over the runtime's sockets. The server exports 7 and
// replies to the first deliver with a Fulfill; the client imports 7, calls it
// with answer 9, and awaits a Resolve settling 9 with the fulfilled value.
{
	const listener = await listenTcp("127.0.0.1", 0);
	const port = listener.port;

	async function server(): Promise<void> {
		const conn = await listener.accept();
		const peer = Peer.rawOpen();
		peer.registerExport(7n);
		const ac = AsyncConnection.fromConn(peer, conn);
		try {
			const ev = await ac.nextEvent();
			assert(ev?.kind === "deliver", `server saw a deliver, got ${ev?.kind}`);
			if (ev?.kind === "deliver") {
				assert(
					ev.target.kind === "near" && ev.target.id === 7n,
					"server target is near export 7",
				);
				assert(ev.answer === 9n, "server deliver carries answer 9");
				assert(
					ev.args.length === 1 && ev.args[0] === 42n,
					"server deliver has one integer arg 42",
				);
				await ac.sendResolve(ev.answer!, { fulfill: 1337n });
			}
		} finally {
			ac.close();
		}
	}

	async function client(): Promise<void> {
		const conn = await connectTcp("127.0.0.1", port);
		const ac = AsyncConnection.fromConn(Peer.rawOpen(), conn);
		try {
			ac.peer.registerImport(7n);
			await ac.sendDeliver(far(7n), [42n], 9n);
			const ev = await ac.nextEvent();
			assert(ev?.kind === "resolve", `client saw a resolve, got ${ev?.kind}`);
			if (ev?.kind === "resolve") {
				assert(ev.answer === 9n, "client resolve settles answer 9");
				assert("fulfill" in ev.resolution, "client resolve is a fulfill");
				if ("fulfill" in ev.resolution) {
					assert(
						ev.resolution.fulfill === 1337n,
						"client resolve fulfills with 1337",
					);
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
	ok("drove OCapN async over the runtime's sockets");
}

// A counter behavior reused by the actor tests: "add" adds args[0] to the
// count and returns it, "get" reads it, anything else throws (a break).
function counterBehavior(
	start: bigint,
): (verb: string, args: Argument[]) => Argument {
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
	const actorPeer = Peer.rawOpen();
	try {
		const vat = new Vat(actorPeer);
		vat.publish(7n, counterBehavior(10n));

		// counter.add(5) with answer 11 and a V1.0 resolver callback.
		actorPeer.feed(
			new TextEncoder().encode(
				"<10'op:deliver<11'desc:export7+>[3'add5+]11+<19'desc:import-promise99+>>",
			),
		);
		const ev: Event | null = actorPeer.poll();
		assert(ev?.kind === "deliver", `actor vat saw a deliver, got ${ev?.kind}`);
		assert(vat.serve(ev!), "vat served the deliver to the published export");

		actorPeer.step();
		const reply = actorPeer.takeOutbound();
		assert(reply !== null, "vat emitted a resolver-callback frame");
		const text = new TextDecoder().decode(reply!);
		assert(
			text.includes("op:deliver"),
			`actor reply is a resolver-callback deliver, got ${text}`,
		);
		assert(
			text.includes("fulfill"),
			`actor reply fulfills the resolver callback, got ${text}`,
		);
		assert(
			text.includes("15+"),
			`actor reply fulfills the new count 15, got ${text}`,
		);
	} finally {
		actorPeer.release();
	}
	ok("drove a published actor round-trip");
}

{
	const peer = Peer.negotiated("pre-spec");
	try {
		peer.startSession({
			transport: "tcp",
			designator: "127.0.0.1:77",
			seed: new Uint8Array(32).fill(0x77),
		});
		peer.step();
		const frame = peer.takeOutbound();
		assert(frame !== null, "PreSpec peer emitted a start-session frame");
		const text = new TextDecoder().decode(frame!);
		assert(
			text.includes("op:start-session"),
			`PreSpec frame is a start-session, got ${text}`,
		);
	} finally {
		peer.release();
	}
	ok("queued an authenticated PreSpec start-session");
}

// Far-send round-trip across the local|far seam. Two fresh peers (no handshake):
// peerB's vat publishes a counter at export 7; peerA's vat far-sends
// counter.add(5) to far(7), gets a far vow, and registers an `on` listener.
// Shuttle A's outbound to B, B serves the deliver (count 10 -> 15, resolves),
// shuttle the V1.0 resolver-callback deliver back, A surfaces it as a typed
// resolve and serves it (fires the listener) -> captured 15.
{
	const peerA = Peer.rawOpen();
	const peerB = Peer.rawOpen();
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
		assert(
			deliverEv?.kind === "deliver",
			`peerB saw a deliver, got ${deliverEv?.kind}`,
		);
		assert(vatB.serve(deliverEv!), "vatB served the far deliver");

		// Shuttle B -> A: V1.0 resolver-callback deliver.
		peerB.step();
		const toA = peerB.takeOutbound();
		assert(toA !== null, "peerB emitted the resolver callback");
		peerA.feed(toA!);
		const resolveEv = peerA.poll();
		assert(
			resolveEv?.kind === "resolve",
			`peerA saw a resolve, got ${resolveEv?.kind}`,
		);
		assert(
			vatA.serve(resolveEv!),
			"vatA served the resolve, firing the far vow",
		);

		assert(
			captured === 15n,
			`far vow fired with the new count 15, got ${captured}`,
		);
	} finally {
		peerA.release();
		peerB.release();
	}
	ok("drove a far-send round-trip across the local|far seam");
}

// Connection surface: an outstanding `send` rejects when the wire drops instead
// of hanging on a reply that can never arrive. The server reads the client's
// deliver and then closes without answering; the client's awaited far `send`
// must settle broken once `serve` sees the disconnect.
{
	const listener = await listenTcp("127.0.0.1", 0);
	const port = listener.port;

	async function server(): Promise<void> {
		const tcp = await listener.accept();
		// Complete the responder handshake (the client's `connect` handshakes), then
		// read the client's deliver and drop the connection unanswered.
		const peer = new Peer();
		peer.registerExport(7n); // admit the client's deliver instead of aborting it
		const ac = AsyncConnection.fromConn(peer, tcp);
		const la = tcp.localAddr();
		peer.startSession({
			transport: "tcp",
			designator: `${la.hostname}:${la.port}`,
			seed: crypto.getRandomValues(new Uint8Array(32)),
			hintsEmptyFalse: true,
		});
		await ac.flush();
		await ac.driveUntilSessionOpen();
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
	ok("an outstanding send rejects on disconnect");
}

// Bounded inbox: a frame declaring more than max_frame_bytes is a typed
// refusal, never "read more". A connection's inbox keeps growing only while
// recvStream returns null, so this is the contract that stops a hostile
// partner from growing it without bound.
{
	using peer = Peer.rawOpen();
	peer.registerExport(7n);
	const overCap = new TextEncoder().encode(
		"<10'op:deliver<11'desc:export7+>[2000000:",
	);
	let code = 0;
	try {
		peer.recvStream(overCap);
	} catch (err) {
		if (err instanceof PancakeError) code = err.code;
	}
	assert(code === -11, `expected FRAME_TOO_LARGE (-11), got ${code}`);
	ok("an over-cap frame refuses typed instead of buffering");
}

// A refused frame names its typed cause: the flat PancakeError code says the
// failure family, the attached AbortDetail says the member.
{
	using peer = Peer.rawOpen();
	assert(peer.lastAbort() === null, "no dispatch failure recorded yet");
	let abort: AbortDetail | null = null;
	try {
		peer.feed(new TextEncoder().encode("this is not a frame"));
	} catch (err) {
		if (err instanceof PancakeError) abort = err.abort;
	}
	assert(abort !== null, "the refused frame carries its typed cause");
	assert(
		abort!.domain === "codec",
		`abort domain is codec, got ${abort!.domain}`,
	);
	assert(
		abort!.kind === "MalformedFrame",
		`abort kind is MalformedFrame, got ${abort!.kind}`,
	);
	assert(
		abort!.errorName === "MalformedFrame",
		`abort errorName is MalformedFrame, got ${abort!.errorName}`,
	);
	ok("a refused frame carries its typed abort cause");
}

// Application-surface structure: a PSet survives the round-trip as a PSet, a
// capability nested in a PSet or Tagged arrives as a sendable Ref, and a
// partner break rejects with the typed VowBroken.
{
	const listener = await listenTcp("127.0.0.1", 0);
	const port = listener.port;

	async function server(): Promise<void> {
		const tcp = await listener.accept();
		const conn = await Connection.accept(tcp);
		conn.publish("svc", (verb, args) => {
			if (verb === "boom") throw new Error("kaboom");
			assert(verb === "probe", `server expected probe, got ${verb}`);
			const probeSet = args[0];
			assert(probeSet instanceof PSet, "a Set argument arrives as a PSet");
			const items = (probeSet as PSet).items as AppValue[];
			assert(items[0] === 1n, "the set's plain item survived");
			const nested = items[1];
			assert(
				nested instanceof Ref,
				"a capability inside a PSet lifts to a Ref",
			);
			const note = args[1];
			assert(note instanceof Tagged, "a Tagged argument arrives as a Tagged");
			assert(
				((note as Tagged).value as AppValue[])[0] instanceof Ref,
				"a capability inside a Tagged lifts to a Ref",
			);
			// The nested capability is sendable: poke back through it.
			conn.tell(nested as Ref, "poke", []).catch(() => {});
			return new PSet([new Sym("ok"), 7n]);
		});
		await conn.serve();
	}

	async function client(): Promise<void> {
		const conn = await Connection.connect("127.0.0.1", port);
		conn.serve().catch(() => {});
		let pokeArrived!: () => void;
		const poked = new Promise<void>((resolve) => (pokeArrived = resolve));
		const inbox = conn.spawn((verb, _args) => {
			if (verb === "poke") pokeArrived();
		});
		const svc = await conn.fetch("svc");
		const reply = await conn.send(svc, "probe", [
			new PSet([1n, inbox] as unknown as Argument[]),
			new Tagged("note", [inbox] as unknown as Argument[]),
		]);
		assert(
			reply instanceof PSet,
			"a PSet reply survives the round-trip as a PSet",
		);
		const items = (reply as PSet).items as AppValue[];
		assert(
			items[0] instanceof Sym && (items[0] as Sym).value === "ok",
			"the set's symbol survived",
		);
		assert(items[1] === 7n, "the set's integer survived");
		await poked;

		// A partner break is the typed VowBroken, catchable by type.
		let broke: VowBroken | null = null;
		try {
			await conn.send(svc, "boom", []);
		} catch (err) {
			if (err instanceof VowBroken) broke = err;
		}
		assert(broke !== null, "a partner break rejects with VowBroken");
		assert(
			broke!.reason.includes("kaboom"),
			`the break carries the reason, got ${broke!.reason}`,
		);
		conn.close();
	}

	try {
		await Promise.all([server(), client()]);
	} finally {
		listener.close();
	}
	ok(
		"a PSet round-trips as a PSet, a nested capability stays sendable, a break is typed",
	);
}

// Sturdyref enliven (ADR-0012): the requester brings a durable (peer, swissnum)
// to life as a live Ref through the dedup cache. A repeat enliven of the same
// swissnum short-circuits with no wire traffic, and the enlivened cap is
// sendable both times.
{
	const listener = await listenTcp("127.0.0.1", 0);
	const port = listener.port;

	async function server(): Promise<void> {
		const tcp = await listener.accept();
		const conn = await Connection.accept(tcp);
		conn.publish("greeter", (verb) => {
			assert(verb === "hello", `enliven server expected hello, got ${verb}`);
			return new Sym("alive");
		});
		await conn.serve();
	}

	async function client(): Promise<void> {
		const conn = await Connection.connect("127.0.0.1", port);
		conn.serve().catch(() => {});
		// The connection is already open to the peer; enliven keys on the
		// sturdyref's swissnum, which the URI carries as `/s/greeter`.
		const sturdyref = "ocapn://greeter-host.tcp/s/greeter";
		const cap = await conn.enliven(sturdyref);
		const greeting = await conn.send(cap, "hello", []);
		assert(
			greeting instanceof Sym && (greeting as Sym).value === "alive",
			"enlivened cap answers hello",
		);
		// A repeat enliven hits the dedup cache: the same live capability, sendable.
		const again = await conn.enliven(sturdyref);
		const greeting2 = await conn.send(again, "hello", []);
		assert(
			greeting2 instanceof Sym && (greeting2 as Sym).value === "alive",
			"cached enliven answers hello",
		);
		conn.close();
	}

	try {
		await Promise.all([server(), client()]);
	} finally {
		listener.close();
	}
	ok(
		"a sturdyref enlivens to a live capability, and a repeat enliven hits the cache",
	);
}

// Distributed GC (ADR-0063), opt-in: a client that enables GC and fetches a
// capability releases its import — one op:gc-exports — when the runtime reclaims
// the last Ref to it. A raw host watches the wire for that release frame; the
// client drops its only handle and forces collection until the host sees it.
{
	const listener = await listenTcp("127.0.0.1", 0);
	const port = listener.port;
	let sawGc = false;

	async function server(): Promise<void> {
		const tcp = await listener.accept();
		const peer = new Peer();
		peer.registerBootstrapCap(new TextEncoder().encode("svc"));
		const ac = AsyncConnection.fromConn(peer, tcp);
		const la = tcp.localAddr();
		peer.startSession({
			transport: "tcp",
			designator: `${la.hostname}:${la.port}`,
			seed: crypto.getRandomValues(new Uint8Array(32)),
			hintsEmptyFalse: true,
		});
		await ac.flush();
		await ac.driveUntilSessionOpen();
		// The engine auto-answers the bootstrap fetch; we wait for the gc-export the
		// client emits once it drops the fetched cap (an "other" event frame).
		for (;;) {
			const ev = await ac.nextEvent();
			if (ev === null) break;
			if (
				ev.kind === "other" &&
				new TextDecoder().decode(ev.frame).includes("op:gc-export")
			) {
				sawGc = true;
				break;
			}
		}
		ac.close();
	}

	async function client(): Promise<void> {
		const conn = (await Connection.connect("127.0.0.1", port)).withGc();
		conn.serve().catch(() => {});
		let cap: Ref | null = await conn.fetch("svc");
		assert(cap.reference.kind === "far", "the fetched cap is a far import");
		// Drop the only handle and force collection until the host sees the release.
		cap = null;
		const force = (): void => {
			const g = (globalThis as { gc?: () => void }).gc;
			if (typeof g === "function") g();
			const bun = (globalThis as { Bun?: { gc?: (sync: boolean) => void } }).Bun;
			if (bun && typeof bun.gc === "function") bun.gc(true);
		};
		for (let i = 0; i < 400 && !sawGc; i++) {
			force();
			await new Promise((r) => setTimeout(r, 5));
		}
		conn.close();
	}

	try {
		await Promise.all([server(), client()]);
	} finally {
		listener.close();
	}
	assert(
		sawGc,
		"host never observed the op:gc-exports for the dropped fetched import " +
			"(needs a runtime GC: deno --v8-flags=--expose-gc, or bun)",
	);
	ok("a dropped fetched import releases its export when GC is opted in");
}

// Promise pipelining (ADR-0007), the questioner's half: `Connection.send`
// returns a handle that is also a `send` target, so a create -> assign ->
// complete -> status chain is issued against the *unresolved* `create` answer
// and the four delivers travel as one batch. The board's `create` spawns a
// fresh task and returns it; the partner's engine queues the pipelined calls on
// that pending answer and drains them onto the task once `create` resolves. A
// `status` of `done` proves the chain crossed the wire without round-tripping
// per link.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const conn of server) {
			conn.publish("root", (verb) => {
				if (verb !== "create") throw new Error(`no such method: ${verb}`);
				let done = false;
				return conn.spawn((taskVerb) => {
					if (taskVerb === "assign") return "assigned";
					if (taskVerb === "complete") {
						done = true;
						return "done";
					}
					if (taskVerb === "status") return done ? "done" : "open";
					throw new Error(`no such method: ${taskVerb}`);
				});
			});
			conn.serve().catch(() => {});
			break; // one client is the proof; ending the loop closes the listener
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const conn = await Connection.connect("127.0.0.1", port);
		conn.serve().catch(() => {});
		const root = await conn.fetch("root");
		// The four verbs leave together: none awaits `create`'s reply, and `assign`
		// / `complete` / `status` target the `create` answer directly.
		const task = conn.send(root, "create", ["benchmark"]);
		conn.send(task, "assign", ["alice"]);
		conn.send(task, "complete", []);
		const status = await conn.send(task, "status", []);
		assert(
			status === "done",
			`pipelined status should be done, got ${String(status)}`,
		);
		conn.close();
	}

	await Promise.race([client(), hosted]);
	await hosted;
	ok("promise pipelining drives create->assign->complete->status as one batch");
}

// Pipelined projections (ADR-0050/ADR-0052): `RemotePromise.index(i)` and
// `.untag(tag)` access an element / unwrap a tag *at the answer*, before it
// resolves, each returning a new pipelinable `RemotePromise`. The board's
// `make` returns `["assigned", label, 7]` tagged "task"; untag unwraps the
// single-value tag to that row, index 1 takes the label — a two-hop projection
// chain that rides the still-pending `make` answer with no extra round trip.
// The source handle is also awaited afterward to prove a far reply
// observed *late* (after a sibling projection already pumped the loop) still
// settles. (`get` projects a Struct, which the Deno value model does not carry,
// so it is proven at the C ABI layer in Zig; here we prove index and untag.)
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const conn of server) {
			conn.publish("root", (verb, args) => {
				if (verb !== "make") throw new Error(`no such method: ${verb}`);
				const label = String(args[0] ?? "anon");
				// A Tagged wrapping a single list value: untag unwraps to that row.
				return tagged("task", [["assigned", label, 7n]]);
			});
			conn.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const conn = await Connection.connect("127.0.0.1", port);
		conn.serve().catch(() => {});
		const root = await conn.fetch("root");
		// None of these await a prior reply: the projections ride the unresolved
		// `make` answer and the whole chain leaves on one flush.
		const made = conn.send(root, "make", ["alice"]);
		const label = await made.untag("task").index(1);
		assert(
			label === "alice",
			`pipelined untag->index should reach the label, got ${String(label)}`,
		);
		// The source answer settled while the projection pumped the loop; observing
		// it now must still resolve (a late far reply settles from the stash).
		const full = await made;
		assert(
			full instanceof Tagged && full.tag === "task",
			`awaited source should be the tagged task, got ${String(full)}`,
		);
		conn.close();
	}

	await client();
	await hosted;
	ok(
		"pipelined projections untag->index reach a field, and a late source await still settles",
	);
}

// Promise pipelining (ADR-0007), the unawaited-anchor contract: a `send` handle
// is a real `Promise`, and an anchor whose far answer *breaks* — even after its
// bytes flush on a sibling's tail — never raises an unhandled rejection, because
// a handle that is never observed registers no reply listener. This is the
// property that lets a pipelining anchor go unawaited safely.
{
	let unhandled = 0;
	const onUnhandled = (e: PromiseRejectionEvent) => {
		unhandled++;
		e.preventDefault();
	};
	globalThis.addEventListener("unhandledrejection", onUnhandled);

	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const conn of server) {
			conn.publish("root", (verb) => {
				if (verb === "ping") return "pong";
				throw new Error(`boom: ${verb}`);
			});
			conn.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const conn = await Connection.connect("127.0.0.1", port);
		conn.serve().catch(() => {});
		const root = await conn.fetch("root");
		const anchor = conn.send(root, "explode", []);
		assert(anchor instanceof Promise, "a send handle must be a real Promise");
		// `anchor` is never observed; awaiting `ping` flushes the queued batch, so
		// `explode`'s deliver crosses the wire and the host breaks its answer. The
		// break resolve arrives with no listener and is dropped — no rejection.
		const pong = await conn.send(root, "ping", []);
		assert(pong === "pong", `expected pong, got ${String(pong)}`);
		await new Promise((r) => setTimeout(r, 50)); // let the break resolve land
		assert(
			unhandled === 0,
			`unawaited break must not surface, saw ${unhandled}`,
		);
		conn.close();
	}

	try {
		await Promise.race([client(), hosted]);
		await hosted;
	} finally {
		globalThis.removeEventListener("unhandledrejection", onUnhandled);
	}
	ok("an unawaited send is a real Promise whose far break never surfaces");
}

// A fetch that fulfills with a plain value (not a capability) rejects with the
// dedicated FetchFailed — the foreign-bootstrap shape a non-pancake partner can
// produce. The server completes a real keyed handshake, then answers the
// bootstrap fetch by hand: the inbound fetch deliver is retargeted from export
// 0 to export 7 so a scratch peer's published actor — not the engine's
// bootstrap interception — fulfills it with a plain integer.
{
	const listener = await listenTcp("127.0.0.1", 0);
	const port = listener.port;

	// Replace the first `desc:export0+` with `desc:export7+` (same length).
	function retarget(frame: Uint8Array): Uint8Array {
		const needle = new TextEncoder().encode("desc:export0+");
		outer: for (let i = 0; i + needle.length <= frame.length; i++) {
			for (let j = 0; j < needle.length; j++) {
				if (frame[i + j] !== needle[j]) continue outer;
			}
			const out = frame.slice();
			out.set(new TextEncoder().encode("desc:export7+"), i);
			return out;
		}
		return frame;
	}

	function append(a: Uint8Array, b: Uint8Array): Uint8Array {
		const grown = new Uint8Array(a.length + b.length);
		grown.set(a, 0);
		grown.set(b, a.length);
		return grown;
	}

	async function server(): Promise<void> {
		const tcp = await listener.accept();
		const peer = new Peer();
		try {
			const la = tcp.localAddr();
			peer.startSession({
				transport: "tcp",
				designator: `${la.hostname}:${la.port}`,
				seed: crypto.getRandomValues(new Uint8Array(32)),
				hintsEmptyFalse: true,
			});
			peer.step();
			let f: Uint8Array | null;
			while ((f = peer.takeOutbound()) !== null) await tcp.write(f);

			// Pump the handshake by hand so the bytes after the client's
			// start-session stay in our inbox instead of an AsyncConnection's.
			let inbox: Uint8Array = new Uint8Array(0);
			while (!peer.sessionIsOpen()) {
				const chunk = await tcp.read();
				assert(chunk !== null, "client closed during the handshake");
				inbox = append(inbox, chunk!);
				while (!peer.sessionIsOpen()) {
					const consumed = peer.recvStream(inbox);
					if (consumed === null) break;
					inbox = inbox.subarray(consumed);
					peer.step();
					while ((f = peer.takeOutbound()) !== null) await tcp.write(f);
				}
			}

			const scratch = Peer.rawOpen();
			try {
				const vat = new Vat(scratch);
				vat.publish(7n, () => 42n);
				for (;;) {
					const consumed = scratch.recvStream(retarget(inbox));
					if (consumed !== null) break;
					const chunk = await tcp.read();
					assert(chunk !== null, "client closed before the fetch arrived");
					inbox = append(inbox, chunk!);
				}
				const ev = scratch.poll();
				assert(
					ev?.kind === "deliver",
					`the doctored fetch surfaced, got ${ev?.kind}`,
				);
				assert(vat.serve(ev!), "the scratch actor served the doctored fetch");
				scratch.step();
				const reply = scratch.takeOutbound();
				assert(reply !== null, "the scratch actor fulfilled the fetch");
				await tcp.write(reply!);
			} finally {
				scratch.release();
			}
			await tcp.read(); // hold the stream open until the client closes
			tcp.close();
		} finally {
			peer.release();
		}
	}

	async function client(): Promise<void> {
		const conn = await Connection.connect("127.0.0.1", port);
		let failed: FetchFailed | null = null;
		try {
			await conn.fetch("not-a-capability");
		} catch (err) {
			if (err instanceof FetchFailed) failed = err;
		}
		assert(failed !== null, "a non-capability fetch rejects with FetchFailed");
		assert(
			failed!.capabilityName === "not-a-capability",
			`FetchFailed names the capability, got ${failed!.capabilityName}`,
		);
		conn.close();
	}

	try {
		await Promise.all([server(), client()]);
	} finally {
		listener.close();
	}
	ok("a non-capability fetch rejects with the typed FetchFailed");
}

// A rude TCP probe — connect, say nothing, hang up — is that connection's
// failure, not the listener's. The Server's iterator must skip the failed
// handshake and keep accepting; without the skip, one port scan takes a
// long-lived server down.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function serveOne(): Promise<void> {
		for await (const conn of server) {
			conn.publish("svc", () => new Sym("alive"));
			conn.serve().catch(() => {});
			break; // one real client is the proof; ending the loop closes the listener
		}
	}
	const served = serveOne();

	const probe = await connectTcp("127.0.0.1", port);
	probe.close();

	async function client(): Promise<void> {
		const conn = await Connection.connect("127.0.0.1", port);
		conn.serve().catch(() => {});
		const svc = await conn.fetch("svc");
		const reply = await conn.send(svc, "ping", []);
		assert(
			reply instanceof Sym && (reply as Sym).value === "alive",
			"the listener survived the rude probe and served the next client",
		);
		conn.close();
	}
	// Race the client against the serve loop: on a regression the loop rejects
	// with the probe's handshake error instead of the client hanging silently.
	await Promise.race([client(), served]);
	await served;
	ok("a rude probe cannot close the listener");
}

// The blocking TCP transport is its own composable module (`./transport/tcp.ts`, riding
// libpancake_net_transport_tcp). Bind a listener, dial it, accept the peer, and
// shuttle one whole frame through the `pancake_tcp_*` endpoints intact.
{
	using net = new TcpNetlayer();
	using listener = net.listen("127.0.0.1", 0);
	const port = listener.port();
	using client = net.connect("127.0.0.1", port);
	using server = listener.accept();
	const frame = new TextEncoder().encode(
		"<10'op:deliver<11'desc:export7+>[5:hello]11+f>",
	);
	client.writeFrame(frame);
	const got = server.readFrame();
	assert(eqBytes(got, frame), "the TCP endpoint shuttled the frame intact");
	ok("the blocking TCP transport shuttled a frame");
}

// The in-process transport is its own composable module (`./transport/inproc.ts`, riding
// libpancake_net_transport_inproc): the socket-free sibling of TCP, two peers
// in one process wired by pipes. Bind a listener on a string designator, dial
// it, accept, and shuttle one whole frame — no kernel transport, no fd.
{
	using net = new InprocNetlayer();
	using listener = net.listen("zig-smoke");
	using client = net.connect("zig-smoke");
	using server = listener.accept();
	const frame = new TextEncoder().encode(
		"<10'op:deliver<11'desc:export7+>[5:hello]11+f>",
	);
	client.writeFrame(frame);
	const got = server.readFrame();
	assert(
		eqBytes(got, frame),
		"the in-process endpoint shuttled the frame intact",
	);
	ok("the in-process transport shuttled a frame socket-free");
}

ok("drove OCapN through the idiomatic pancake API");
