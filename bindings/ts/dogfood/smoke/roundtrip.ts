// deno-lint-ignore-file no-inner-declarations -- scenarios keep local
// `server`/`client` function declarations inside their own bare blocks; the
// block scoping is the point (handles cannot leak across scenarios).
// The byte-fed round-trips under a caller-supplied allocator: publish,
// fetch, sends and vows, both codecs, disconnects on either side of the
// race, and a dial driven by the host's own DIAL action.

import * as tcp from "@pancake/tcp";

import { INVALID_ARGUMENT } from "@pancake/abi";

import {
	type Argument,
	Context,
	type ContextAllocator,
	formatLocatorUri,
	Host,
	Kw,
	PancakeError,
	PSet,
	PStruct,
	Ref,
	Runtime,
	Sym,
	Tagged,
	VowBroken,
} from "../../runtime/mod.ts";

import { _connectIroh } from "../../iroh/impl.ts";

import { assert, counterBehavior, ok } from "./support.ts";

export async function run(managed: Runtime): Promise<void> {
	{
		let allocs = 0;
		let frees = 0;
		const allocator: ContextAllocator = {
			alloc(size, _alignment) {
				allocs++;
				return new Uint8Array(size);
			},
			free(_block, _size, _alignment) {
				frees++;
			},
		};
		using ctx = Context.withAllocator(allocator);
		const captpHost = new Host(undefined, { context: ctx });
		// Release is a close request, not permission to invalidate a live native
		// handle. It refuses new families immediately and retires the allocator only
		// after the Host gives back its lease.
		ctx.release();
		captpHost.recordCallerlessFailure("context.release-requested", new Error("still observable"));
		const retainedFailures = captpHost.takeFailures();
		assert(
			retainedFailures.length === 1 && retainedFailures[0].operation === "context.release-requested" &&
				retainedFailures[0].scopeId !== 0n,
			"a release-requested Context remains the live Host's diagnostic owner",
		);
		let acceptedAfterRelease = false;
		try {
			const refused = new Host(undefined, { context: ctx });
			acceptedAfterRelease = true;
			await refused.close();
		} catch {
			// Expected: a closing Context cannot mint another handle family.
		}
		assert(!acceptedAfterRelease, "a released Context refuses a new Host");
		captpHost.publishGiftable("counter", counterBehavior(10n));
		const server = await tcp.listen("127.0.0.1", 0, { host: captpHost });
		const port = server.port;

		async function host(): Promise<void> {
			for await (const session of server) {
				session.serve().catch(() => {});
				break; // one client is the proof; ending the loop closes the listener
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const session = await managed.connect(tcp.locator("127.0.0.1", port));
			session.serve().catch(() => {});
			const counter = await session.fetch("counter");
			const grown = await session.send(counter, "add", [5n]);
			assert(grown === 15n, `counter.add(5) returns 15, got ${String(grown)}`);
			const read = await session.send(counter, "get", []);
			assert(read === 15n, `counter.get() returns 15, got ${String(read)}`);
			await session.close();
		}

		await Promise.all([client(), hosted]);
		await captpHost.close();
		assert(allocs > 0, `custom allocator served the host's allocations, got ${allocs}`);
		assert(frees === allocs, `Context released every custom allocation: ${frees}/${allocs}`);
		ok("drove a published counter round-trip from a context-backed host");
	}

	// The live timeline producer: the veneer stamps and forwards the native
	// tap's facts, one flat record per fact — session-opened with the codec the
	// handshake actually negotiated, the same verb outbound at the client and
	// inbound at the server, and session-closed. Endpoint labeling belongs to
	// the consumer (ocapnviz resolves src/dst from the opens), so the records
	// carry only the session and direction.
	{
		const { annotateSession, enableTrace } = await import("@pancake/runtime");
		const events: import("@pancake/runtime").TraceEvent[] = [];
		const traceFailure = new Error("trace sink failure must stay observer-only");
		const uninstall = enableTrace((ev) => {
			events.push(ev);
			throw traceFailure;
		}, {
			selfLabel: "smoke",
		});

		await using traceHost = new Host();
		traceHost.publishGiftable("greeter", (verb) => `hello ${verb}`);
		const server = await tcp.listen("127.0.0.1", 0, { host: traceHost });
		const port = server.port;
		const hosted = (async () => {
			for await (const session of server) {
				session.serve().catch(() => {});
				break;
			}
		})();
		const session = await managed.connect(tcp.locator("127.0.0.1", port));
		session.serve().catch(() => {});
		const greeter = await session.fetch("greeter");
		const reply = await session.send(greeter, "trace-me", []);
		assert(reply === "hello trace-me", `traced call still answers, got ${String(reply)}`);
		// The annotation channel: the application states which partner a
		// session carries, named for the same session row the tap names.
		annotateSession(session, { label: "greeter-server" });
		const clientHost = session.host;
		await session.close();
		await hosted;
		uninstall();
		const traceFailures = [...traceHost.takeFailures(), ...clientHost.takeFailures()];
		assert(traceFailures.length > 0, "trace sink failures remain observable");
		assert(
			traceFailures.every((failure) =>
				failure.operation === "trace.sink" && failure.primaryName === "Error" &&
				failure.primaryMessage === traceFailure.message && failure.scopeId > 0n
			),
			"trace sink failures use the central Context schema",
		);

		const opened = events.filter((ev) => ev.kind === "ocapn.session-opened");
		assert(opened.length >= 2, "both hosts' opens reached the one sink");
		assert(
			opened.every((ev) => ev.codec === "syrup" && ev.a_label === "smoke"),
			"opens carry the negotiated codec and the application's display label",
		);
		// And what this producer RUNS, because this schema is not pancake's alone:
		// a consumer must not read an implementation off the fact that a record
		// arrived, so a pancake host says so in words.
		assert(
			opened.every((ev) => ev.a_profile === "pancake"),
			"an open states the implementation this producer runs",
		);
		// Identity and label are two facts. `a` is the host's own key designator —
		// the name a partner knows it by, and so the only name two producers can
		// agree on — and the label never stands in for it.
		assert(
			opened.every((ev) => /^[0-9a-f]{64}$/.test(ev.a ?? "")),
			"an open's `a` endpoint is the reporting host's key designator",
		);
		// The OCapN Session ID is what lets a consumer merging two producers'
		// feeds tell one session watched twice from two unrelated ones: both
		// peers of this session derive it, so the two opens agree on it.
		assert(
			opened.every((ev) =>
				ev.session_id === opened[0].session_id &&
				/^[0-9a-f]{64}$/.test(ev.session_id ?? "")
			),
			"both peers of one session report the same OCapN Session ID",
		);
		const outbound = events.find(
			(ev) =>
				ev.kind === "ocapn.message-decoded" && ev.op === "trace-me" &&
				ev.outbound === true,
		);
		assert(outbound !== undefined, "the client's send traced outbound");
		const inbound = events.find(
			(ev) =>
				ev.kind === "ocapn.message-decoded" && ev.op === "trace-me" &&
				ev.outbound === false,
		);
		assert(inbound !== undefined, "the server's deliver traced inbound");
		assert(
			inbound!.session !== outbound!.session,
			"each host names its own session row",
		);
		// Payload: both fact sites sit at the wire boundary (inbound
		// dispatch, the outbound drain), so both records carry the whole
		// (sub-cap) frame with its true length and the verb inside it.
		for (const rec of [inbound!, outbound!]) {
			assert(
				rec.bytes_b64 !== undefined && rec.len === atob(rec.bytes_b64).length,
				"the record carries its whole frame with its true length",
			);
			assert(
				atob(rec.bytes_b64!).includes("trace-me"),
				"the frame bytes contain the delivered verb",
			);
		}
		assert(
			events.some((ev) => ev.kind === "ocapn.session-closed"),
			"the close reached the sink",
		);
		const meta = events.find((ev) => ev.kind === "ocapn.session-meta");
		assert(
			meta !== undefined && meta.meta?.label === "greeter-server",
			"the annotation reached the sink with its label",
		);
		assert(
			meta!.session === outbound!.session,
			"the annotation names the same session row the tap names",
		);
		let last = -1;
		for (const ev of events) {
			assert(ev.sim_t_ns >= last, "sim_t_ns is monotone");
			last = ev.sim_t_ns;
		}
		ok("the live trace produced the timeline schema for a whole conversation");
	}

	// An async behavior (off-turn settlement): the worker returns a promise, the
	// binding defers the turn's answer onto a resolver vow, and the settle
	// re-enters from the microtask queue after real awaited work, so the host's
	// turn loop never blocks on it. A rejection crosses as the caller's break
	// carrying the behavior's own words.
	{
		await using workerHost = new Host();
		workerHost.publishGiftable("worker", async (verb) => {
			await new Promise((resolve) => setTimeout(resolve, 5));
			if (verb === "fail") throw new Error("worker gave up");
			if (verb === "unsupported") return { unsupported: true } as unknown as Argument;
			return "computed off-turn";
		});
		const server = await tcp.listen("127.0.0.1", 0, { host: workerHost });
		const port = server.port;

		async function host(): Promise<void> {
			for await (const session of server) {
				session.serve().catch(() => {});
				break;
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const session = await managed.connect(tcp.locator("127.0.0.1", port));
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
			broke = "";
			try {
				await session.send(worker, "unsupported", []);
			} catch (err) {
				broke = err instanceof Error ? err.message : String(err);
			}
			assert(
				broke.toLowerCase().includes("unsupported"),
				`async marshal failure carries the reason, got "${broke}"`,
			);
			await session.close();
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
		await using capnpHost = new Host(undefined, { codec: "capnp" });
		capnpHost.publishGiftable("svc", (verb, args) => {
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
		const server = await tcp.listen("127.0.0.1", 0, { host: capnpHost });
		const port = server.port;

		async function host(): Promise<void> {
			for await (const session of server) {
				session.serve().catch(() => {});
				break;
			}
		}
		const hosted = host();
		await using capnpRuntime = await Runtime.open({
			providers: [tcp.provider()],
			codec: "capnp",
		});

		async function client(): Promise<void> {
			const session = await capnpRuntime.connect(tcp.locator("127.0.0.1", port));
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
			await session.close();
		}

		await Promise.all([client(), hosted]);
		ok("a capnp session opens and big-integer + keyword args round-trip");
	}

	// Session surface: an outstanding `send` rejects when the wire drops
	// instead of hanging on a reply that can never arrive. The server serves one
	// call and then closes; the client's next awaited `send` must settle broken
	// once the disconnect lands, whichever side of the race it hits.
	{
		await using closeHost = new Host();
		closeHost.publishGiftable("svc", () => null);
		const server = await tcp.listen("127.0.0.1", 0, { host: closeHost });
		const port = server.port;
		let serverClosed!: () => void;
		const closed = new Promise<void>((r) => (serverClosed = r));
		let firstReplyObserved!: () => void;
		const firstReply = new Promise<void>((r) => (firstReplyObserved = r));

		async function host(): Promise<void> {
			for await (const session of server) {
				session.serve().catch(() => {});
				// Close only after the client observed the first reply. A timer makes
				// this a scheduler race, not a disconnect contract test.
				await firstReply;
				await session.close();
				serverClosed();
				break;
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const session = await managed.connect(tcp.locator("127.0.0.1", port));
			session.serve().catch(() => {}); // a disconnect ends the serve loop; expected here
			const svc = await session.fetch("svc");
			try {
				await session.send(svc, "ping", []);
			} finally {
				firstReplyObserved();
			}
			await closed;
			let rejected = false;
			try {
				await session.send(svc, "late", []);
			} catch (_err) {
				rejected = true;
			}
			assert(rejected, "an outstanding send rejects when the connection drops");
			await session.close();
		}

		await Promise.all([client(), hosted]);
		ok("an outstanding send rejects on disconnect");
	}

	// Application-surface structure: PSet and PStruct survive the typed waist, a
	// capability nested in a PSet or Tagged arrives as a sendable Ref, and a
	// partner break rejects with the typed VowBroken.
	{
		const server = await tcp.listen("127.0.0.1", 0);
		const port = server.port;
		let markPublished!: () => void;
		const published = new Promise<void>((resolve) => (markPublished = resolve));

		async function host(): Promise<void> {
			for await (const session of server) {
				session.publish("svc", (verb, args) => {
					if (verb === "boom") throw new Error("kaboom");
					assert(verb === "probe", `server expected probe, got ${verb}`);
					const probeSet = args[0];
					assert(probeSet instanceof PSet, "a Set argument arrives as a PSet");
					const items = (probeSet as PSet<Argument>).items;
					assert(items.some((item) => item === 1n), "the set's plain item survived");
					const nested = items.find((item) => item instanceof Ref);
					assert(
						nested instanceof Ref,
						"a capability inside a PSet lifts to a Ref",
					);
					const record = args[2];
					assert(record instanceof PStruct, "a Struct argument arrives as a PStruct");
					assert(
						(record as PStruct<Argument>).entries.some(([name, value]) => name === "count" && value === 7n),
						"the Struct's named field survived",
					);
					const note = args[1];
					assert(note instanceof Tagged, "a Tagged argument arrives as a Tagged");
					assert(
						(note as Tagged<Argument>).value[0] instanceof Ref,
						"a capability inside a Tagged lifts to a Ref",
					);
					const errorValue = args[3];
					assert(
						errorValue instanceof Error && errorValue.message === "failure is a value",
						"an OCapN Error arrives as fulfilled Error data",
					);
					// The nested capability is sendable: poke back through it.
					session.tell(nested as Ref, "poke", []).catch(() => {});
					return [new PSet([new Sym("ok"), 7n]), record, errorValue];
				});
				markPublished();
				session.serve().catch(() => {});
				break;
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const session = await managed.connect(tcp.locator("127.0.0.1", port));
			session.serve().catch(() => {});
			await published;
			let pokeArrived!: () => void;
			const poked = new Promise<void>((resolve) => (pokeArrived = resolve));
			const inbox = session.spawn((verb, _args) => {
				if (verb === "poke") pokeArrived();
			});
			const svc = await session.fetch("svc");
			const reply = await session.send(svc, "probe", [
				new PSet<Argument>([1n, inbox]),
				new Tagged<Argument>("note", [inbox]),
				new PStruct<Argument>([["count", 7n], ["name", "widget"]]),
				new Error("failure is a value"),
			]);
			assert(
				Array.isArray(reply),
				"the structured reply survives as a List",
			);
			const returned = reply as Argument[];
			assert(returned[0] instanceof PSet, "a PSet reply survives the round-trip as a PSet");
			assert(returned[1] instanceof PStruct, "a PStruct reply survives the round-trip as a PStruct");
			assert(
				returned[2] instanceof Error && returned[2].message === "failure is a value",
				"an Error value fulfills rather than breaking the reply",
			);
			const items = (returned[0] as PSet<Argument>).items;
			assert(
				items.some((item) => item instanceof Sym && item.value === "ok"),
				"the set's symbol survived",
			);
			assert(items.some((item) => item === 7n), "the set's integer survived");
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
			await session.close();
		}

		await Promise.all([client(), hosted]);
		ok(
			"PSet, PStruct, and Error values round-trip, a nested capability stays sendable, a break is typed",
		);
	}

	// Sturdyref enliven (ADR-0012): the requester brings a durable (peer, swissnum)
	// to life as a live Ref through the host's dedup cache. A repeat enliven of the
	// same swissnum short-circuits with no wire traffic (its completion is queued
	// before the minting call returns), and the enlivened cap is sendable both
	// times.
	{
		await using serverHost = new Host();
		serverHost.publishGiftable("greeter", (verb) => {
			assert(verb === "hello", `enliven server expected hello, got ${verb}`);
			return new Sym("alive");
		});
		const server = await tcp.listen("127.0.0.1", 0, { host: serverHost });
		const port = server.port;

		async function host(): Promise<void> {
			for await (const session of server) {
				session.serve().catch(() => {});
				break;
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const locator = tcp.locator("127.0.0.1", port);
			const session = await managed.connect(locator);
			session.serve().catch(() => {});
			let mismatchRefused = false;
			try {
				await session.enliven("ocapn://127.0.0.1%3A1.tcp/s/Z3JlZXRlcg");
			} catch (err) {
				mismatchRefused = err instanceof PancakeError && err.code === INVALID_ARGUMENT;
			}
			assert(mismatchRefused, "enliven accepted a sturdyref for another peer");
			// The complete sturdyref must name this selected session's peer.
			const sturdyref = `${formatLocatorUri(locator)}/s/Z3JlZXRlcg`;
			const cap = await session.enliven(sturdyref);
			const greeting = await session.send(cap, "hello", []);
			assert(
				greeting instanceof Sym && (greeting as Sym).value === "alive",
				"enlivened cap answers hello",
			);
			// A repeat enliven hits the dedup cache: the same live capability, sendable.
			const again = await session.enliven(sturdyref);
			assert(cap.equals(again), "cached enliven preserves Target equality");
			const greeting2 = await session.send(again, "hello", []);
			assert(
				greeting2 instanceof Sym && (greeting2 as Sym).value === "alive",
				"cached enliven answers hello",
			);
			await session.close();
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
		await using serverHost = new Host();
		serverHost.publishGiftable("beacon", () => new Sym("lit"));
		const server = await tcp.listen("127.0.0.1", 0, { host: serverHost });
		const port = server.port;

		async function host(): Promise<void> {
			for await (const session of server) {
				session.serve().catch(() => {});
				break;
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const locator = tcp.locator("127.0.0.1", port);
			const shared = new Host();
			await using sharedRuntime = await Runtime.open({
				providers: [tcp.provider()],
				adoptHost: shared,
			});
			const session = await sharedRuntime.connect(locator);
			session.serve().catch(() => {});
			const cap = await shared.enliven(`${formatLocatorUri(locator)}/s/YmVhY29u`);
			const greeting = await session.send(cap, "hello", []);
			assert(
				greeting instanceof Sym && (greeting as Sym).value === "lit",
				"the select-or-dial enlivened cap answers",
			);
			await session.close();
		}

		await Promise.all([client(), hosted]);
		ok("a host selects a live session to enliven a sturdyref over");
	}

	// Listen (CapTP op:listen, ADR-0095): a held capability is listened on, and
	// the vow settles with its resolution — any value, not only a capability. A
	// listen on an already-settled capability answers at once, proving the round
	// trip rather than a pending promise.
	{
		await using listenHost = new Host();
		listenHost.publishGiftable("beacon", () => new Sym("lit"));
		const server = await tcp.listen("127.0.0.1", 0, { host: listenHost });
		const port = server.port;

		async function host(): Promise<void> {
			for await (const session of server) {
				session.serve().catch(() => {});
				break;
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const session = await managed.connect(tcp.locator("127.0.0.1", port));
			session.serve().catch(() => {});
			const beacon = await session.fetch("beacon");
			const settled = await session.listen(beacon);
			assert(settled instanceof Ref, "the listen settles naming the capability");
			await session.close();
		}

		await Promise.all([client(), hosted]);
		ok("a listen on a held capability settles with its resolution");
	}

	// Distributed GC (ADR-0063), opt-in: fetch results, nested send replies, and
	// nested delivered arguments each release their one projected capability
	// occurrence. The relay observes both directions before teardown.
}
