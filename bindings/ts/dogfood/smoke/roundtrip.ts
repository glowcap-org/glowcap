// deno-lint-ignore-file no-inner-declarations -- scenarios keep local
// `server`/`client` function declarations inside their own bare blocks; the
// block scoping is the point (handles cannot leak across scenarios).
// The byte-fed round-trips under a caller-supplied allocator: publish,
// fetch, sends and vows, both codecs, disconnects on either side of the
// race, and a dial driven by the host's own DIAL action.

import * as tcp from "@glowcap/tcp";

import { INVALID_ARGUMENT } from "@glowcap/abi";

import {
	type Argument,
	Context,
	type ContextAllocator,
	GlowcapError,
	Host,
	Kw,
	PSet,
	PStruct,
	Ref,
	Runtime,
	Sym,
	Tagged,
	VowBroken,
} from "../../runtime/mod.ts";

import { assert, counterBehavior, ok } from "./support.ts";
import { runTraceRoundtrip } from "./trace_roundtrip.ts";

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
		// Release is a close request, not permission to invalidate a live FFI
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
		captpHost.publish("counter", counterBehavior(10n));
		const server = await tcp.listen("127.0.0.1", 0, { host: captpHost });
		const port = server.port;
		let heldCounter: Ref | null = null;

		async function host(): Promise<void> {
			for await (const session of server) {
				heldCounter = session.publishedRef("counter");
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
			assert(heldCounter !== null, "accepted session holds the published actor");
			const name = captpHost.publishReference(heldCounter);
			const exact = await session.fetch(name);
			assert(await session.send(exact, "add", [2n]) === 17n, "published reference mutates the original actor");
			assert(await session.send(counter, "get", []) === 17n, "original authority sees the same state");
			assert(captpHost.unpublishDurable(name), "remove independent publication root");
			assert(await session.send(exact, "get", []) === 17n, "issued reference survives removal");
			await session.close();
		}

		await Promise.all([client(), hosted]);
		await captpHost.close();
		assert(allocs > 0, `custom allocator served the host's allocations, got ${allocs}`);
		assert(frees === allocs, `Context released every custom allocation: ${frees}/${allocs}`);
		ok("drove a published counter round-trip from a context-backed host");
	}

	await runTraceRoundtrip(managed);

	// An async behavior (off-turn settlement): the worker returns a promise, the
	// binding defers the turn's answer onto a resolver vow, and the settle
	// re-enters from the microtask queue after real awaited work, so the host's
	// turn loop never blocks on it. A rejection crosses as the caller's break
	// carrying the behavior's own words.
	{
		await using workerHost = new Host();
		const makeGate = () => {
			let markEntered!: () => void;
			let resume!: () => void;
			return {
				entered: new Promise<void>((resolve) => markEntered = resolve),
				blocked: new Promise<void>((resolve) => resume = resolve),
				markEntered: () => markEntered(),
				resume: () => resume(),
			};
		};
		const gates = {
			work: makeGate(),
			fail: makeGate(),
			unsupported: makeGate(),
			lateWork: makeGate(),
			lateFail: makeGate(),
		};
		const completions: Promise<Argument>[] = [];
		workerHost.publish("worker", (verb) => {
			const completion = (async () => {
				const gate = gates[verb as keyof typeof gates];
				if (gate === undefined) throw new Error(`unexpected worker verb ${verb}`);
				gate.markEntered();
				await gate.blocked;
				if (verb === "fail" || verb === "lateFail") throw new Error("worker gave up");
				if (verb === "unsupported") return { unsupported: true } as unknown as Argument;
				return "computed off-turn";
			})();
			completions.push(completion);
			return completion;
		});
		const server = await tcp.listen("127.0.0.1", 0, { host: workerHost });
		const port = server.port;

		async function host(): Promise<void> {
			for await (const session of server) {
				await session.serve().catch(() => {});
				break;
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const session = await managed.connect(tcp.locator("127.0.0.1", port));
			session.serve().catch(() => {});
			const worker = await session.fetch("worker");
			const invoke = async (verb: keyof typeof gates): Promise<Argument> => {
				const pending = session.send(worker, verb, []);
				await gates[verb].entered;
				gates[verb].resume();
				return await pending;
			};
			const reply = await invoke("work");
			assert(reply === "computed off-turn", `async behavior reply, got ${String(reply)}`);
			let broke = "";
			try {
				await invoke("fail");
			} catch (err) {
				broke = err instanceof Error ? err.message : String(err);
			}
			assert(
				broke.includes("worker gave up"),
				`async rejection carries the reason, got "${broke}"`,
			);
			broke = "";
			try {
				await invoke("unsupported");
			} catch (err) {
				broke = err instanceof Error ? err.message : String(err);
			}
			assert(
				broke.toLowerCase().includes("unsupported"),
				`async marshal failure carries the reason, got "${broke}"`,
			);
			const late = Promise.allSettled([
				session.send(worker, "lateWork", []),
				session.send(worker, "lateFail", []),
			]);
			await Promise.all([gates.lateWork.entered, gates.lateFail.entered]);
			await session.close();
			await hosted;
			gates.lateWork.resume();
			gates.lateFail.resume();
			await Promise.allSettled(completions);
			assert((await late).every((reply) => reply.status === "rejected"), "disconnected callers were broken");
			assert(workerHost.takeFailures().length === 0, "late completions poisoned the Host");
		}

		await Promise.all([client(), hosted]);
		ok("an async behavior deferred its answer onto a resolver vow and settled off-turn");
	}

	// The codec selector end-to-end: both nodes minted with the Cap'n Proto wire
	// grammar complete the keyed handshake and carry a deliver whose arguments
	// round-trip through the capnp codec (a big integer past int64 and a Kw
	// (keyword) included), so the two rare marshal arms are witnessed alongside the
	// codec.
	{
		await using capnpHost = new Host(undefined, { codec: "capnp" });
		capnpHost.publish("svc", (verb, args) => {
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

	// A BigInt64Array argument crosses as one ARG_INTEGERS run and arrives as a list.
	{
		await using runHost = new Host();
		runHost.publish("run", (verb, args) => {
			assert(verb === "sum", `integer-run server expected sum, got ${verb}`);
			const list = args[0];
			assert(
				Array.isArray(list) && list.length === 3 && list[0] === 7n && list[1] === -8n && list[2] === 9n,
				"a BigInt64Array arrives as a list of 7, -8, 9",
			);
			return new BigInt64Array([4n, -5n]);
		});
		const server = await tcp.listen("127.0.0.1", 0, { host: runHost });
		const port = server.port;
		const hosted = (async () => {
			for await (const session of server) {
				session.serve().catch(() => {});
				break;
			}
		})();
		const session = await managed.connect(tcp.locator("127.0.0.1", port));
		session.serve().catch(() => {});
		const run = await session.fetch("run");
		const reply = await session.send(run, "sum", [new BigInt64Array([7n, -8n, 9n])]);
		assert(
			Array.isArray(reply) && reply.length === 2 && reply[0] === 4n && reply[1] === -5n,
			"a BigInt64Array reply arrives as a list",
		);
		await session.close();
		await hosted;
		ok("a BigInt64Array argument crosses as one integer run and arrives as a list");
	}

	// Session surface: an outstanding `send` rejects when the wire drops
	// instead of hanging on a reply that can never arrive. The server serves one
	// call and then closes; the client's next awaited `send` must settle broken
	// once the disconnect lands, whichever side of the race it hits.
	{
		await using closeHost = new Host();
		closeHost.publish("svc", () => null);
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

	// Listen (CapTP op:listen, ADR-0095): a held capability is listened on, and
	// the vow settles with its resolution: any value, not only a capability. A
	// listen on an already-settled capability answers at once, proving the round
	// trip rather than a pending promise.
	{
		await using listenHost = new Host();
		listenHost.publish("beacon", () => new Sym("lit"));
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
			const observation = session.listen(beacon);
			let refused = false;
			try {
				await session.send(observation, "ping", []);
			} catch (error) {
				refused = error instanceof GlowcapError && error.code === INVALID_ARGUMENT;
			}
			assert(refused, "an op:listen observer became a remote pipeline target");
			const settled = await observation;
			assert(settled instanceof Ref, "the listen settles naming the capability");
			await session.close();
		}

		await Promise.all([client(), hosted]);
		ok("a listen on a held capability settles with its resolution");
	}
}
