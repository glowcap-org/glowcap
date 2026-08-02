// deno-lint-ignore-file no-inner-declarations -- each smoke scenario lives in
// its own bare block with local `server`/`client` function declarations; the
// block scoping is the point (handles cannot leak across scenarios), so the
// module-root rule is deliberately waived for this file.
// Cross-runtime dogfood of the Zig pancake C ABI archives, through the
// idiomatic composable modules (`mod.ts` core over the byte-fed host archive +
// `tcp.ts`/`inproc.ts` transports): drive OCapN with native values, no FFI in
// sight. It runs identically on Deno and Bun, which is the proof the binding
// is runtime-neutral. This is the consumer `zig build bindings` runs.

import process from "node:process";
import { INVALID_ARGUMENT, TIMEOUT } from "@pancake/abi";
import { connectTcp, listenTcp, type NetConn } from "../stack/internal/seam.ts";
import {
	abiVersion,
	type Argument,
	connect,
	Context,
	type ContextAllocator,
	durableIdentityAuthenticated,
	ensureRuntimeReady,
	FetchFailed,
	Host,
	Kw,
	listen,
	PancakeError,
	PSet,
	Ref,
	type Session,
	Sym,
	Tagged,
	tagged,
	tcpLocator,
	VowBroken,
} from "../stack/mod.ts";
import { Netlayer as TcpNetlayer } from "../stack/transport/tcp.ts";
import { Netlayer as InprocNetlayer } from "../stack/transport/inproc.ts";

const runtime = typeof (globalThis as { Bun?: unknown }).Bun !== "undefined"
	? "bun"
	: typeof (globalThis as { Deno?: unknown }).Deno !== "undefined"
	? "deno"
	: "node";

function assert(cond: boolean, msg: string): asserts cond {
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

// A byte-level TCP relay between a client and a server that are both real
// pancake connections: it shuttles raw bytes both ways, optionally rewriting
// the client->server stream and observing the traffic. This is how the smoke
// watches the wire (a gc release frame) or doctors it (a retargeted fetch)
// without either endpoint dropping out of the application surface.
async function startRelay(
	targetPort: number,
	rewriteToServer: (chunk: Uint8Array) => Uint8Array = (c) => c,
	observe: (chunk: Uint8Array) => void = () => {},
): Promise<{ port: number; close: () => void }> {
	const listener = await listenTcp("127.0.0.1", 0);
	const open: NetConn[] = [];
	void (async () => {
		while (true) {
			let client: NetConn;
			try {
				client = await listener.accept();
			} catch {
				return; // the relay was closed
			}
			const server = await connectTcp("127.0.0.1", targetPort);
			open.push(client, server);
			void (async () => {
				while (true) {
					const chunk = await client.read().catch(() => null);
					if (chunk === null) break;
					observe(chunk);
					await server.write(rewriteToServer(chunk)).catch(() => {});
				}
				server.close();
			})();
			void (async () => {
				while (true) {
					const chunk = await server.read().catch(() => null);
					if (chunk === null) break;
					observe(chunk);
					await client.write(chunk).catch(() => {});
				}
				client.close();
			})();
		}
	})();
	return {
		port: listener.port,
		close: () => {
			listener.close();
			for (const c of open) c.close();
		},
	};
}

// Bun resolves its FFI adapter asynchronously; make it ready before the first
// synchronous FFI call below. A no-op on Deno (resolved at import).
await ensureRuntimeReady();

// The linked library reports a real ABI version.
const [major, minor, patch] = abiVersion();
assert(
	major + minor + patch > 0,
	`abiVersion is nonzero, got ${major}.${minor}.${patch}`,
);

// A counter behavior reused by the round-trip tests: "add" adds args[0] to the
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

// The basic round-trip: publish a counter, fetch it, drive it with sends. The
// server node lives in a caller-supplied allocation context, so every byte the
// host owns routes through the custom allocator — proving `Context` and
// `ContextAllocator` against the byte-fed host, released in the documented order
// (node before context).
{
	let allocs = 0;
	const allocator: ContextAllocator = {
		alloc(size, _alignment) {
			allocs++;
			return new Uint8Array(size);
		},
		free(_block, _size, _alignment) {},
	};
	using ctx = Context.withAllocator(allocator);
	const captpHost = new Host(undefined, { context: ctx });
	const server = listen("127.0.0.1", 0, captpHost);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const session of server) {
			session.publish("counter", counterBehavior(10n));
			session.serve().catch(() => {});
			break; // one client is the proof; ending the loop closes the listener
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		const counter = await session.fetch("counter");
		const grown = await session.send(counter, "add", [5n]);
		assert(grown === 15n, `counter.add(5) returns 15, got ${String(grown)}`);
		const read = await session.send(counter, "get", []);
		assert(read === 15n, `counter.get() returns 15, got ${String(read)}`);
		session.close();
	}

	await Promise.all([client(), hosted]);
	captpHost.release(); // before the context that owns its allocations
	assert(allocs > 0, `custom allocator served the host's allocations, got ${allocs}`);
	ok("drove a published counter round-trip from a context-backed host");
}

// An async behavior (off-turn settlement): the worker returns a promise, the
// binding defers the turn's answer onto a resolver vow, and the settle
// re-enters from the microtask queue after real awaited work, so the host's
// turn loop never blocks on it. A rejection crosses as the caller's break
// carrying the behavior's own words.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const session of server) {
			session.publish("worker", async (verb) => {
				await new Promise((resolve) => setTimeout(resolve, 5));
				if (verb === "fail") throw new Error("worker gave up");
				return "computed off-turn";
			});
			session.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		const worker = await session.fetch("worker");
		const reply = await session.send(worker, "work", []);
		assert(reply === "computed off-turn", `async behavior reply, got ${String(reply)}`);
		let broke = "";
		try {
			await session.send(worker, "fail", []);
		} catch (err) {
			broke = err instanceof Error ? err.message : String(err);
		}
		assert(
			broke.includes("worker gave up"),
			`async rejection carries the reason, got "${broke}"`,
		);
		session.close();
	}

	await Promise.all([client(), hosted]);
	ok("an async behavior deferred its answer onto a resolver vow and settled off-turn");
}

// The codec selector end-to-end: both nodes minted with the Cap'n Proto wire
// grammar complete the keyed handshake and carry a deliver whose arguments
// round-trip through the capnp codec — a big integer past int64 and a Kw
// (keyword) included, so the two rare marshal arms are witnessed alongside the
// codec.
{
	const server = listen("127.0.0.1", 0, new Host(undefined, { codec: "capnp" }));
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const session of server) {
			session.publish("svc", (verb, args) => {
				assert(verb === "probe", `capnp server expected probe, got ${verb}`);
				assert(args[0] === 2n ** 80n, `big integer survives capnp: ${String(args[0])}`);
				assert(
					args[1] instanceof Kw && args[1].value === "prio",
					"a keyword survives capnp as a Kw",
				);
				assert(
					args[2] instanceof Uint8Array &&
						new TextDecoder().decode(args[2] as Uint8Array) === "hi",
					"bytes survive capnp",
				);
				return new Kw("done");
			});
			session.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(
			tcpLocator("127.0.0.1", port),
			undefined,
			undefined,
			"capnp",
		);
		session.serve().catch(() => {});
		const svc = await session.fetch("svc");
		const reply = await session.send(svc, "probe", [
			2n ** 80n,
			new Kw("prio"),
			new TextEncoder().encode("hi"),
		]);
		assert(
			reply instanceof Kw && reply.value === "done",
			"the capnp reply keyword survived",
		);
		session.close();
	}

	await Promise.all([client(), hosted]);
	ok("a capnp session opens and big-integer + keyword args round-trip");
}

// Session surface: an outstanding `send` rejects when the wire drops
// instead of hanging on a reply that can never arrive. The server serves one
// call and then closes; the client's next awaited `send` must settle broken
// once the disconnect lands, whichever side of the race it hits.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();
	let serverClosed!: () => void;
	const closed = new Promise<void>((r) => (serverClosed = r));

	async function host(): Promise<void> {
		for await (const session of server) {
			session.publish("svc", () => null);
			session.serve().catch(() => {});
			// Serve exactly one call, then hang up without warning.
			await new Promise((r) => setTimeout(r, 50));
			session.close();
			serverClosed();
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {}); // a disconnect ends the serve loop; expected here
		const svc = await session.fetch("svc");
		await session.send(svc, "ping", []);
		await closed;
		let rejected = false;
		try {
			await session.send(svc, "late", []);
		} catch (_err) {
			rejected = true;
		}
		assert(rejected, "an outstanding send rejects when the connection drops");
		session.close();
	}

	await Promise.all([client(), hosted]);
	ok("an outstanding send rejects on disconnect");
}

// Application-surface structure: a PSet survives the round-trip as a PSet, a
// capability nested in a PSet or Tagged arrives as a sendable Ref, and a
// partner break rejects with the typed VowBroken.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const session of server) {
			session.publish("svc", (verb, args) => {
				if (verb === "boom") throw new Error("kaboom");
				assert(verb === "probe", `server expected probe, got ${verb}`);
				const probeSet = args[0];
				assert(probeSet instanceof PSet, "a Set argument arrives as a PSet");
				const items = (probeSet as PSet<Argument>).items;
				assert(items[0] === 1n, "the set's plain item survived");
				const nested = items[1];
				assert(
					nested instanceof Ref,
					"a capability inside a PSet lifts to a Ref",
				);
				const note = args[1];
				assert(note instanceof Tagged, "a Tagged argument arrives as a Tagged");
				assert(
					(note as Tagged<Argument>).value[0] instanceof Ref,
					"a capability inside a Tagged lifts to a Ref",
				);
				// The nested capability is sendable: poke back through it.
				session.tell(nested as Ref, "poke", []).catch(() => {});
				return new PSet([new Sym("ok"), 7n]);
			});
			session.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		let pokeArrived!: () => void;
		const poked = new Promise<void>((resolve) => (pokeArrived = resolve));
		const inbox = session.spawn((verb, _args) => {
			if (verb === "poke") pokeArrived();
		});
		const svc = await session.fetch("svc");
		const reply = await session.send(svc, "probe", [
			new PSet<Argument>([1n, inbox]),
			new Tagged<Argument>("note", [inbox]),
		]);
		assert(
			reply instanceof PSet,
			"a PSet reply survives the round-trip as a PSet",
		);
		const items = (reply as PSet<Argument>).items;
		assert(
			items[0] instanceof Sym && (items[0] as Sym).value === "ok",
			"the set's symbol survived",
		);
		assert(items[1] === 7n, "the set's integer survived");
		await poked;

		// A partner break is the typed VowBroken, catchable by type.
		let broke: VowBroken | null = null;
		try {
			await session.send(svc, "boom", []);
		} catch (err) {
			if (err instanceof VowBroken) broke = err;
		}
		assert(broke !== null, "a partner break rejects with VowBroken");
		assert(
			broke!.reason.includes("kaboom"),
			`the break carries the reason, got ${broke!.reason}`,
		);
		session.close();
	}

	await Promise.all([client(), hosted]);
	ok(
		"a PSet round-trips as a PSet, a nested capability stays sendable, a break is typed",
	);
}

// Sturdyref enliven (ADR-0012): the requester brings a durable (peer, swissnum)
// to life as a live Ref through the host's dedup cache. A repeat enliven of the
// same swissnum short-circuits with no wire traffic (its completion is queued
// before the minting call returns), and the enlivened cap is sendable both
// times.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const session of server) {
			session.publish("greeter", (verb) => {
				assert(verb === "hello", `enliven server expected hello, got ${verb}`);
				return new Sym("alive");
			});
			session.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const locator = tcpLocator("127.0.0.1", port);
		const session = await connect(locator);
		session.serve().catch(() => {});
		let mismatchRefused = false;
		try {
			await session.enliven("ocapn://127.0.0.1%3A1.tcp/s/greeter");
		} catch (err) {
			mismatchRefused = err instanceof PancakeError && err.code === INVALID_ARGUMENT;
		}
		assert(mismatchRefused, "enliven accepted a sturdyref for another peer");
		// The complete sturdyref must name this selected session's peer.
		const sturdyref = `${locator}/s/greeter`;
		const cap = await session.enliven(sturdyref);
		const greeting = await session.send(cap, "hello", []);
		assert(
			greeting instanceof Sym && (greeting as Sym).value === "alive",
			"enlivened cap answers hello",
		);
		// A repeat enliven hits the dedup cache: the same live capability, sendable.
		const again = await session.enliven(sturdyref);
		const greeting2 = await session.send(again, "hello", []);
		assert(
			greeting2 instanceof Sym && (greeting2 as Sym).value === "alive",
			"cached enliven answers hello",
		);
		session.close();
	}

	await Promise.all([client(), hosted]);
	ok(
		"a sturdyref enlivens to a live capability, and a repeat enliven hits the cache",
	);
}

// Select-or-dial enliven (ADR-0098 step 4): the *host* enlivens a complete
// sturdyref with no session named. A peer it already dialed is selected, so
// this arm settles over that live session — the dial arm is the same verb
// with an unreached peer, driven by the host's own DIAL action.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const session of server) {
			session.publish("beacon", () => new Sym("lit"));
			session.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const locator = tcpLocator("127.0.0.1", port);
		const shared = new Host();
		const session = await connect(locator, undefined, shared);
		session.serve().catch(() => {});
		const cap = await shared.enliven(`${locator}/s/beacon`);
		const greeting = await session.send(cap, "hello", []);
		assert(
			greeting instanceof Sym && (greeting as Sym).value === "lit",
			"the select-or-dial enlivened cap answers",
		);
		session.close();
	}

	await Promise.all([client(), hosted]);
	ok("a host selects a live session to enliven a sturdyref over");
}

// Listen (CapTP op:listen, ADR-0095): a held capability is listened on, and
// the vow settles with its resolution — any value, not only a capability. A
// listen on an already-settled capability answers at once, proving the round
// trip rather than a pending promise.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const session of server) {
			session.publish("beacon", () => new Sym("lit"));
			session.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		const beacon = await session.fetch("beacon");
		const settled = await session.listen(beacon);
		assert(settled instanceof Ref, "the listen settles naming the capability");
		session.close();
	}

	await Promise.all([client(), hosted]);
	ok("a listen on a held capability settles with its resolution");
}

// Distributed GC (ADR-0063), opt-in: a client that enables GC and fetches a
// capability releases its import — one op:gc-exports — when the runtime
// reclaims the last Ref to it. Both ends are real connections; a byte relay
// between them watches the wire for the release frame. The client drops its
// only handle and forces collection until the relay sees it.
{
	const server = listen("127.0.0.1", 0);
	const targetPort = await server.ready();
	let sawGc = false;
	const relay = await startRelay(targetPort, (c) => c, (chunk) => {
		if (new TextDecoder().decode(chunk).includes("op:gc-export")) sawGc = true;
	});

	async function host(): Promise<void> {
		for await (const session of server) {
			session.publish("svc", () => null);
			session.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = (await connect(tcpLocator("127.0.0.1", relay.port))).withGc();
		session.serve().catch(() => {});
		let cap: Ref | null = await session.fetch("svc");
		assert(cap.id > 0n, "the fetched cap has a Host identity");
		// Drop the only handle and force collection until the relay sees the
		// release ride the wire.
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
		session.close();
	}

	await Promise.all([client(), hosted]);
	relay.close();
	assert(
		sawGc,
		"the wire never carried the op:gc-exports for the dropped fetched import " +
			"(needs a runtime GC: deno --v8-flags=--expose-gc, or bun)",
	);
	ok("a dropped fetched import releases its export when GC is opted in");
}

// Promise pipelining (ADR-0007), the questioner's half: `Session.send`
// returns a handle that is also a `send` target, so a create -> assign ->
// complete -> status chain is issued against the *unresolved* `create` answer
// and the four delivers travel as one batch. The board's `create` spawns a
// fresh task from inside the served turn (the turn-time spawn) and returns it;
// the partner's engine queues the pipelined calls on that pending answer and
// drains them onto the task once `create` resolves. A `status` of `done`
// proves the chain crossed the wire without round-tripping per link.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const session of server) {
			session.publish("root", (verb) => {
				if (verb !== "create") throw new Error(`no such method: ${verb}`);
				let done = false;
				return session.spawn((taskVerb) => {
					if (taskVerb === "assign") return "assigned";
					if (taskVerb === "complete") {
						done = true;
						return "done";
					}
					if (taskVerb === "status") return done ? "done" : "open";
					throw new Error(`no such method: ${taskVerb}`);
				});
			});
			session.serve().catch(() => {});
			break; // one client is the proof; ending the loop closes the listener
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		const root = await session.fetch("root");
		// The four verbs leave together: none awaits `create`'s reply, and
		// `assign` / `complete` / `status` target the `create` answer directly.
		const task = session.send(root, "create", ["benchmark"]);
		session.send(task, "assign", ["alice"]);
		session.send(task, "complete", []);
		const status = await session.send(task, "status", []);
		assert(
			status === "done",
			`pipelined status should be done, got ${String(status)}`,
		);
		session.close();
	}

	await Promise.race([client(), hosted]);
	await hosted;
	ok("promise pipelining drives create->assign->complete->status as one batch");
}

// Host ownership, arriving-Port routing: the root is first projected through
// one accepted Session, that Port closes, and a sibling invokes it. Its
// callback deliberately uses the stale originating Session handle to spawn a
// child; the active Host turn must select turn-spawn before that dead handle is
// checked, and the child must ride the sibling's reply.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();
	let readyResolve!: () => void;
	const ready = new Promise<void>((resolve) => readyResolve = resolve);

	async function host(): Promise<void> {
		let origin: Session | null = null;
		let root: Ref | null = null;
		for await (const session of server) {
			session.serve().catch(() => {});
			if (origin === null) {
				origin = session;
				const captured = session;
				root = session.spawn((verb) => {
					if (verb !== "create") throw new Error(`no such method: ${verb}`);
					return captured.spawn((childVerb) => {
						if (childVerb === "ping") return "alive";
						throw new Error(`no such method: ${childVerb}`);
					});
				});
				continue;
			}
			const introduced = root;
			assert(introduced !== null, "the origin spawned its root");
			session.publish("introducer", (verb) => {
				if (verb === "get") return introduced;
				throw new Error(`no such method: ${verb}`);
			});
			origin.close();
			readyResolve();
			await session.serve();
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const origin = await connect(tcpLocator("127.0.0.1", port));
		origin.serve().catch(() => {});
		const sibling = await connect(tcpLocator("127.0.0.1", port));
		sibling.serve().catch(() => {});
		await ready;
		const introducer = await sibling.fetch("introducer");
		const root = await sibling.send(introducer, "get", []);
		assert(root instanceof Ref, "the sibling introduces the Host-owned root");
		const child = await sibling.send(root, "create", []);
		assert(child instanceof Ref, "create returns the turn-spawned child");
		assert(await sibling.send(child, "ping", []) === "alive", "the child is callable");
		sibling.close();
		origin.close();
	}

	await Promise.all([client(), hosted]);
	ok("turn-time spawn uses the Host after the originating Port closes");
}

// Pipelined projections (ADR-0050/ADR-0052): `RemotePromise.index(i)` and
// `.untag(tag)` access an element / unwrap a tag *at the answer*, before it
// resolves, each returning a new pipelinable `RemotePromise`. The board's
// `make` returns `["assigned", label, 7]` tagged "task"; untag unwraps the
// single-value tag to that row, index 1 takes the label, a two-hop projection
// chain that rides the still-pending `make` answer with no extra round trip.
// The source handle is also awaited afterward to prove a far reply observed
// *late* (after a sibling projection already pumped the loop) still settles
// from the recorded outcome.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const session of server) {
			session.publish("root", (verb, args) => {
				if (verb !== "make") throw new Error(`no such method: ${verb}`);
				const label = String(args[0] ?? "anon");
				// A Tagged wrapping a single list value: untag unwraps to that row.
				return tagged("task", [["assigned", label, 7n]]);
			});
			session.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		const root = await session.fetch("root");
		// None of these await a prior reply: the projections ride the unresolved
		// `make` answer and the whole chain leaves on one flush.
		const made = session.send(root, "make", ["alice"]);
		const label = await made.untag("task").index(1);
		assert(
			label === "alice",
			`pipelined untag->index should reach the label, got ${String(label)}`,
		);
		// The source answer settled while the projection pumped the loop;
		// observing it now must still resolve (a late observation settles from
		// the recorded outcome).
		const full = await made;
		assert(
			full instanceof Tagged && full.tag === "task",
			`awaited source should be the tagged task, got ${String(full)}`,
		);
		session.close();
	}

	await client();
	await hosted;
	ok(
		"pipelined projections untag->index reach a field, and a late source await still settles",
	);
}

// Promise pipelining (ADR-0007), the unawaited-anchor contract: a `send`
// handle is a real `Promise`, and an anchor whose far answer *breaks* — even
// after its bytes flush on a sibling's tail — never raises an unhandled
// rejection, because a handle that is never observed materializes no
// rejection (the outcome is recorded, not thrown). This is the property that
// lets a pipelining anchor go unawaited safely.
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
		for await (const session of server) {
			session.publish("root", (verb) => {
				if (verb === "ping") return "pong";
				throw new Error(`boom: ${verb}`);
			});
			session.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		const root = await session.fetch("root");
		const anchor = session.send(root, "explode", []);
		assert(anchor instanceof Promise, "a send handle must be a real Promise");
		// `anchor` is never observed; awaiting `ping` flushes the queued batch,
		// so `explode`'s deliver crosses the wire and the host breaks its answer.
		// The break's FAIL completion is recorded with no waiter, no rejection.
		const pong = await session.send(root, "ping", []);
		assert(pong === "pong", `expected pong, got ${String(pong)}`);
		await new Promise((r) => setTimeout(r, 50)); // let the break land
		assert(
			unhandled === 0,
			`unawaited break must not surface, saw ${unhandled}`,
		);
		session.close();
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
// dedicated FetchFailed — the foreign-bootstrap shape a non-pancake partner
// can produce. A pancake host always answers a fetch with a capability, so the
// relay doctors the wire: the client's bootstrap-fetch deliver is retargeted
// from export 0 to the export of a published object that answers with a plain
// integer, and the client's fetch answer fulfills with 42. The client fetches
// "plain" legitimately first: that reply's marshal is what grants the export
// (ADR-0074), so the doctored deliver that follows is admitted rather than
// refused as a probe of an ungranted position.
{
	const server = listen("127.0.0.1", 0);
	const targetPort = await server.ready();
	let plainExport = -1n;
	let exportReady!: () => void;
	const exportKnown = new Promise<void>((r) => (exportReady = r));

	// Replace the first `desc:export0+` with `desc:export<P>+`. The spliced
	// integer is whatever position the host allocated, which is not the same
	// width as the one it replaces, so the frame is rebuilt at its new length
	// rather than overwritten in place — a Syrup record is delimiter-terminated,
	// so a wider integer is still a whole frame. Armed only after the legitimate
	// fetch of "plain" has granted the export, so only the second fetch is
	// doctored.
	let armed = false;
	let retargeted = false;
	let capturing = false;
	let observedWire = "";
	const decoder = new TextDecoder();
	function observe(chunk: Uint8Array): void {
		if (!capturing || plainExport >= 0n) return;
		observedWire += decoder.decode(chunk, { stream: true });
		const match = /desc:import-object(\d+)\+/.exec(observedWire);
		if (match !== null) plainExport = BigInt(match[1]);
	}
	function retarget(chunk: Uint8Array): Uint8Array {
		if (!armed || retargeted || plainExport < 0n) return chunk;
		const needle = new TextEncoder().encode("desc:export0+");
		outer: for (let i = 0; i + needle.length <= chunk.length; i++) {
			for (let j = 0; j < needle.length; j++) {
				if (chunk[i + j] !== needle[j]) continue outer;
			}
			const spliced = new TextEncoder().encode(`desc:export${plainExport}+`);
			const out = new Uint8Array(chunk.length - needle.length + spliced.length);
			out.set(chunk.subarray(0, i), 0);
			out.set(spliced, i);
			out.set(chunk.subarray(i + needle.length), i + spliced.length);
			retargeted = true;
			return out;
		}
		return chunk;
	}
	const relay = await startRelay(targetPort, retarget, observe);

	async function host(): Promise<void> {
		for await (const session of server) {
			// The doctored fetch deliver lands here with verb "fetch"; answer with
			// a plain integer, which is exactly what a fetch must not resolve to.
			session.publish("plain", () => 42n);
			exportReady();
			session.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", relay.port));
		session.serve().catch(() => {});
		await exportKnown;
		// The granting fetch: its resolve marshals the "plain" reference, which
		// is what makes the position addressable for the doctored deliver.
		capturing = true;
		await session.fetch("plain");
		for (let i = 0; i < 100 && plainExport < 0n; i++) await Promise.resolve();
		assert(plainExport >= 0n, "the granting fetch exposed no import-object descriptor");
		capturing = false;
		armed = true;
		let failed: FetchFailed | null = null;
		try {
			await session.fetch("not-a-capability");
		} catch (err) {
			if (err instanceof FetchFailed) failed = err;
		}
		assert(failed !== null, "a non-capability fetch rejects with FetchFailed");
		assert(
			failed!.capabilityName === "not-a-capability",
			`FetchFailed names the capability, got ${failed!.capabilityName}`,
		);
		session.close();
	}

	await Promise.all([client(), hosted]);
	relay.close();
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
		for await (const session of server) {
			session.publish("svc", () => new Sym("alive"));
			session.serve().catch(() => {});
			break; // one real client is the proof; ending the loop closes the listener
		}
	}
	const served = serveOne();

	const probe = await connectTcp("127.0.0.1", port);
	probe.close();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		const svc = await session.fetch("svc");
		const reply = await session.send(svc, "ping", []);
		assert(
			reply instanceof Sym && (reply as Sym).value === "alive",
			"the listener survived the rude probe and served the next client",
		);
		session.close();
	}
	// Race the client against the serve loop: on a regression the loop rejects
	// with the probe's handshake error instead of the client hanging silently.
	await Promise.race([client(), served]);
	await served;
	ok("a rude probe cannot close the listener");
}

// The dial-side twin of the rude probe: a partner that accepts the connection
// and then says nothing is the case no failure check catches, because nothing
// fails. Unbounded, the dialer parks forever; the bound makes it a typed
// TIMEOUT, and the abandoned handshake closes the socket on the way out.
{
	const listener = await listenTcp("127.0.0.1", 0);
	const accepted: NetConn[] = [];
	// Accept the socket and say nothing on it, ever.
	const accepting = listener.accept().then(
		(conn) => void accepted.push(conn),
		() => {},
	);

	let timedOut: PancakeError | null = null;
	try {
		await connect(tcpLocator("127.0.0.1", listener.port), undefined, undefined, undefined, 250);
	} catch (err) {
		if (err instanceof PancakeError) timedOut = err;
	}
	assert(
		timedOut !== null && timedOut.code === TIMEOUT,
		`a silent partner must time the dial out, got code ${timedOut?.code ?? "a session"}`,
	);

	await accepting;
	for (const conn of accepted) conn.close();
	listener.close();
	ok("a silent partner times the dial out rather than parking it");
}

// The blocking TCP transport is its own composable module
// (`./transport/tcp.ts`, riding libpancake_net_transport_tcp). Bind a
// listener, dial it, accept the peer, and shuttle one whole frame through the
// `pancake_tcp_*` endpoints intact.
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

// The in-process transport is its own composable module
// (`./transport/inproc.ts`, riding libpancake_net_transport_inproc): the
// socket-free sibling of TCP, two peers in one process wired by pipes. Bind a
// listener on a string designator, dial it, accept, and shuttle one whole
// frame, no kernel transport, no fd.
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

// Object-capability forwarding proxies over the wire (ADR-0064). The server
// fetches the client's published tool — a far reference on the server side —
// wraps it in a caretaker and an attenuator, and hands the proxies back. A
// call through the proxy forwards across the server to the client's tool (the
// far deferred-answer path) and settles the caller's answer; the attenuator
// passes only its allow-listed verb; and a revoke breaks every later call.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();
	let toolReady!: () => void;
	const toolPublished = new Promise<void>((r) => (toolReady = r));
	let proxyReady!: () => void;
	const proxyPublished = new Promise<void>((r) => (proxyReady = r));

	async function host(): Promise<void> {
		for await (const session of server) {
			session.serve().catch(() => {});
			await toolPublished;
			const tool = await session.fetch("tool");
			const care = session.caretaker(tool);
			const readonly = session.attenuate(tool, ["get"]);
			session.publish("root", (verb) => {
				if (verb === "proxy") return care.proxy;
				if (verb === "readonly") return readonly;
				if (verb === "revoke") {
					care.revoke();
					return;
				}
				throw new Error(`no such method: ${verb}`);
			});
			proxyReady();
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {}); // serve so the server's forwarded call arrives
		session.publish("tool", (verb, args) => {
			if (verb === "add") {
				const n = typeof args[0] === "bigint" ? args[0] : 0n;
				return n + 1n;
			}
			if (verb === "get") return 7n;
			throw new Error(`no such method: ${verb}`);
		});
		toolReady();
		await proxyPublished;
		const root = await session.fetch("root");

		// Live caretaker: a call forwards across the server to the far tool.
		const proxy = await session.send(root, "proxy");
		assert(proxy instanceof Ref, "the caretaker proxy lifts to a Ref");
		const sum = await session.send(proxy as Ref, "add", [41n]);
		assert(sum === 42n, `caretaker forwards to the far tool, got ${sum}`);

		// Attenuator: the allow-listed verb forwards; any other breaks.
		const readonly = await session.send(root, "readonly");
		assert(readonly instanceof Ref, "the attenuator proxy lifts to a Ref");
		const got = await session.send(readonly as Ref, "get");
		assert(got === 7n, `the attenuator forwards an allowed verb, got ${got}`);
		let denied: VowBroken | null = null;
		try {
			await session.send(readonly as Ref, "add", [1n]);
		} catch (err) {
			if (err instanceof VowBroken) denied = err;
		}
		assert(
			denied !== null && denied.reason.includes("Attenuated"),
			"an out-of-list verb breaks Attenuated",
		);

		// Revoke: every later call through the proxy breaks.
		await session.send(root, "revoke");
		let severed: VowBroken | null = null;
		try {
			await session.send(proxy as Ref, "add", [1n]);
		} catch (err) {
			if (err instanceof VowBroken) severed = err;
		}
		assert(
			severed !== null && severed.reason.includes("Revoked"),
			"a revoked proxy breaks Revoked",
		);

		session.close();
	}

	await Promise.all([client(), hosted]);
	ok("forwarding proxies forward, attenuate, and revoke over the wire");
}

// The wart ADR-0064 closes: a forwarding proxy is an ordinary spawned actor,
// so its own host calls it locally exactly as a partner calls it over the
// wire. A caretaker over a *local* tool answers a local send; a caretaker over
// a *far* tool forwards across the wire and the local send still settles; and
// a revoke breaks the local call too, no second-class behavior on the hosting
// side.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const session of server) {
			session.publish("tool", (verb) => {
				if (verb === "ping") return "pong";
				throw new Error(`no such method: ${verb}`);
			});
			session.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});

		// A caretaker over a local tool, called locally by its own host.
		const local = session.spawn((verb, args) => {
			if (verb === "double") {
				const n = typeof args[0] === "bigint" ? args[0] : 0n;
				return n * 2n;
			}
			throw new Error(`no such method: ${verb}`);
		});
		const careLocal = session.caretaker(local);
		const doubled = await session.send(careLocal.proxy, "double", [21n]);
		assert(doubled === 42n, `a local proxy answers a local call, got ${doubled}`);

		// A caretaker over a far tool, called locally: the proxy forwards across
		// the wire and the local send still settles on the partner's reply.
		const far = await session.fetch("tool");
		const careFar = session.caretaker(far);
		const pong = await session.send(careFar.proxy, "ping");
		assert(pong === "pong", `a local call over a far tool settles, got ${pong}`);

		// Revoke severs the local call exactly as it severs a partner's.
		careLocal.revoke();
		let severed: VowBroken | null = null;
		try {
			await session.send(careLocal.proxy, "double", [1n]);
		} catch (err) {
			if (err instanceof VowBroken) severed = err;
		}
		assert(
			severed !== null && severed.reason.includes("Revoked"),
			"revoke breaks a local call too",
		);

		session.close();
	}

	await Promise.all([client(), hosted]);
	ok("a forwarding proxy answers its host's own local call (local and far target)");
}

// The callback latch crosses the binding: a behavior that reaches for a
// host-driving verb mid-turn (publish, here) is refused by the C tier, the
// refusal surfaces as the behavior's own throw, and the answer breaks with it
// — the turn neither deadlocks nor corrupts the host. The connection stays
// fully usable afterwards.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const session of server) {
			session.publish("svc", (verb) => {
				if (verb === "reenter") {
					// A driving verb inside the turn: the latch refuses it and the
					// thrown PancakeError's words become the broken answer.
					session.publish("nested", () => null);
					return "unreachable";
				}
				return "pong";
			});
			session.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		const svc = await session.fetch("svc");
		let broke: VowBroken | null = null;
		try {
			await session.send(svc, "reenter");
		} catch (err) {
			if (err instanceof VowBroken) broke = err;
		}
		assert(broke !== null, "a mid-turn driving verb breaks the answer");
		// The turn unwound cleanly: the same session still answers.
		const pong = await session.send(svc, "ping");
		assert(pong === "pong", `the connection survives the refused turn, got ${pong}`);
		session.close();
	}

	await Promise.all([client(), hosted]);
	ok("a behavior's mid-turn driving verb is refused and breaks its own answer");
}

// Mid-turn close parks the C release (parity with Python/Rust): a behavior that
// closes its own Session inside a local turn must not free the native conn
// while the trampoline frame is still on the stack. The release runs after the
// turn unwinds; the next verb is the typed CLOSED.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const session of server) {
			session.serve().catch(() => {});
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", port));
		session.serve().catch(() => {});
		const me = session.spawn((verb) => {
			if (verb === "die") {
				session.close();
				return "closing";
			}
			return null;
		});
		const reply = await session.send(me, "die");
		assert(reply === "closing", `mid-turn close: reply settled, got ${reply}`);
		assert(
			session.host.pendingReleaseCount() === 0,
			"mid-turn close: parked release drained after the turn",
		);
		let closed: PancakeError | null = null;
		try {
			await session.send(me, "die");
		} catch (err) {
			if (err instanceof PancakeError) closed = err;
		}
		assert(
			closed !== null && /closed/i.test(closed.message),
			"mid-turn close: the next verb is refused closed",
		);
	}

	await Promise.all([client(), hosted]);
	ok("a behavior closing its own connection mid-turn parks the release");
}

// Host release closes every Session before freeing the native Host. When the
// request comes from a behavior callback, all three releases park; FIFO order
// is the lifetime proof for two live Session handles followed by their Host.
{
	const captpHost = new Host();
	const server = listen("127.0.0.1", 0, captpHost);
	const port = await server.ready();
	let acceptedResolve!: () => void;
	const accepted = new Promise<void>((resolve) => acceptedResolve = resolve);
	let duringResolve!: (count: number) => void;
	const during = new Promise<number>((resolve) => duringResolve = resolve);
	captpHost.publishGiftable("svc", (verb) => {
		if (verb !== "release-host") return null;
		captpHost.release();
		duringResolve(captpHost.pendingReleaseCount());
		return "closing";
	});

	async function host(): Promise<void> {
		let count = 0;
		for await (const session of server) {
			session.serve().catch(() => {});
			count++;
			if (count === 2) {
				acceptedResolve();
				break;
			}
		}
	}
	const hosted = host();
	const first = await connect(tcpLocator("127.0.0.1", port));
	first.serve().catch(() => {});
	const second = await connect(tcpLocator("127.0.0.1", port));
	second.serve().catch(() => {});
	await accepted;
	const svc = await first.fetch("svc");
	try {
		await first.send(svc, "release-host");
	} catch (_) {
		// Releasing the server Host closes the wire before this answer must land.
	}
	assert(await during === 3, "two Session releases and their Host park in order");
	assert(
		captpHost.pendingReleaseCount() === 0,
		"the callback unwind drains every parked release",
	);
	first.close();
	second.close();
	server.close();
	await hosted;
	ok("a callback-time Host release frees two Sessions before their Host");
}

// The partner identity the handshake proved, and the refusal an application
// builds on it. A directory that takes a locator from the wire and believes it
// will point introductions wherever a caller says; the fix is to compare the
// name a caller claims against the one it actually signed.
//
// A dialing client that does not listen has no dialable name of its own, so it
// signs the unreachable-client placeholder. That is the sharpest case: whatever
// locator such a caller claims, it did not prove it.
{
	const server = listen("127.0.0.1", 0);
	const port = await server.ready();

	async function host(): Promise<void> {
		for await (const session of server) {
			const seen = session.partnerIdentity();
			assert(
				seen.sessionKey.length === 32,
				`partner identity: expected a 32-byte key, got ${seen.sessionKey.length}`,
			);
			// `tcp` designates a socket address, so no durable identity was
			// proved: the three facts stay distinct (ADR-0097), and the
			// provenance says so rather than the designator being compared to
			// the session key.
			assert(
				seen.provenance === "unauthenticated",
				`partner identity: a tcp session proves no durable identity, got ${seen.provenance}`,
			);
			assert(
				!durableIdentityAuthenticated(seen),
				"partner identity: a tcp session has no authenticated durable peer",
			);
			// The rooms-shaped check, both ways. The claim a caller could make
			// about itself is only worth acting on when it matches what the
			// caller signed.
			const honest = seen.designator;
			const dishonest = "198.51.100.7:9999";
			assert(
				honest === seen.designator,
				"partner identity: a matching claim is accepted",
			);
			assert(
				dishonest !== seen.designator,
				"partner identity: a claim the caller never signed is refused",
			);
			session.close();
			break;
		}
	}
	const hosted = host();

	async function client(): Promise<void> {
		const session = await connect(tcpLocator("127.0.0.1", port));
		const seen = session.partnerIdentity();
		// The dialer verified the listener's signature, so it holds the
		// listener's key and the address that key signed.
		assert(
			seen.sessionKey.length === 32,
			"partner identity: the client sees the server's proved key",
		);
		assert(
			seen.designator === `127.0.0.1:${port}`,
			`partner identity: expected the listener's signed address, got "${seen.designator}"`,
		);
		assert(
			seen.locatorRecord.length > 0,
			"partner identity: the verbatim location record came back",
		);
		session.close();
	}

	await Promise.all([client(), hosted]);
	ok("the handshake's proved partner identity refuses a locator the caller never signed");
}

ok("drove OCapN through the idiomatic pancake API");
