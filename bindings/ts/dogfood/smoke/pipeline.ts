// deno-lint-ignore-file no-inner-declarations -- scenarios keep local
// `server`/`client` function declarations inside their own bare blocks; the
// block scoping is the point (handles cannot leak across scenarios).
// Pipelining across the wire: the relay observes both directions, chains
// cross without per-link round-trips, children ride sibling replies,
// anchors go safely unawaited, and an ungranted position is refused as the
// probe it is.

import * as tcp from "@glowcap/tcp";
import { INVALID_ARGUMENT } from "@glowcap/abi";

import {
	type Argument,
	enableTrace,
	FEATURE_FULL,
	FEATURE_MULTI_LOCATION,
	GlowcapError,
	Host,
	PStruct,
	Ref,
	Runtime,
	Session,
	Tagged,
	tagged,
} from "../../runtime/mod.ts";

import { assert, ok, startRelay, within } from "./support.ts";
import { runForeignFetch } from "./foreign_fetch.ts";

export async function run(managed: Runtime): Promise<void> {
	// Distributed GC (ADR-0025), opt-in: fetch results, nested send replies, and
	// nested delivered arguments each release their one projected capability
	// occurrence. The relay observes both directions before teardown.
	{
		await using gcHost = new Host();
		const server = await tcp.listen("127.0.0.1", 0, { host: gcHost });
		const targetPort = server.port;
		const needle = new TextEncoder().encode("op:gc-export");
		let toServerTail = new Uint8Array();
		let toClientTail = new Uint8Array();
		let toServerGc = 0;
		let toClientGc = 0;
		let resolveServerOne!: () => void;
		let resolveServerTwo!: () => void;
		let resolveClientOne!: () => void;
		const serverOneSeen = new Promise<void>((resolve) => resolveServerOne = resolve);
		const serverTwoSeen = new Promise<void>((resolve) => resolveServerTwo = resolve);
		const clientOneSeen = new Promise<void>((resolve) => resolveClientOne = resolve);
		const relay = await startRelay(targetPort, (c) => c, (chunk, toServer) => {
			const prior = toServer ? toServerTail : toClientTail;
			const combined = new Uint8Array(prior.length + chunk.length);
			combined.set(prior);
			combined.set(chunk, prior.length);
			for (let i = 0; i + needle.length <= combined.length; i++) {
				if (needle.every((byte, offset) => combined[i + offset] === byte)) {
					if (toServer) {
						toServerGc++;
						if (toServerGc >= 1) resolveServerOne();
						if (toServerGc >= 2) resolveServerTwo();
					} else {
						toClientGc++;
						if (toClientGc >= 1) resolveClientOne();
					}
				}
			}
			const tail = combined.slice(Math.max(0, combined.length - needle.length + 1));
			if (toServer) toServerTail = tail;
			else toClientTail = tail;
		});

		async function host(): Promise<void> {
			for await (const session of server) {
				session.withGc();
				const delegated = session.spawn(() => null);
				let releaseInbound!: (ref: Ref) => void;
				const inbound = new Promise<Ref>((resolve) => releaseInbound = resolve);
				session.publish("factory", (verb, args) => {
					if (verb === "reply") return new PStruct([["nested", [delegated]]]);
					assert(verb === "accept", `unexpected GC test verb ${verb}`);
					const payload = args[0];
					assert(
						args.length === 1 && payload instanceof PStruct &&
							payload.entries[0][0] === "nested" && Array.isArray(payload.entries[0][1]) &&
							payload.entries[0][1][0] instanceof Ref,
						"the server received the nested capability argument",
					);
					releaseInbound(payload.entries[0][1][0]);
					return null;
				});
				const serving = session.serve().catch(() => {});
				session.release(await inbound);
				await serving;
				break;
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const session = (await managed.connect(tcp.locator("127.0.0.1", relay.port))).withGc();
			session.serve().catch(() => {});
			const factory = await session.fetch("factory");
			const reply = await session.send(factory, "reply", []);
			assert(
				reply instanceof PStruct && reply.entries[0][0] === "nested" &&
					Array.isArray(reply.entries[0][1]) && reply.entries[0][1][0] instanceof Ref,
				"the send reply carries a nested capability",
			);
			session.release(reply.entries[0][1][0]);
			await within(serverOneSeen, 2_000, "nested send reply release");
			assert(toServerGc >= 1, "the nested send reply did not release");

			const callback = session.spawn(() => null);
			await session.send(factory, "accept", [new PStruct([["nested", [callback]]])]);
			await within(clientOneSeen, 2_000, "nested delivered argument release");
			assert(toClientGc >= 1, "the nested delivered argument did not release");

			session.release(factory);
			await within(serverTwoSeen, 2_000, "fetched capability release");
			assert(toServerGc >= 2, "the fetched capability did not release");
			await session.close();
		}

		await Promise.all([client(), hosted]);
		relay.close();
		ok("distributed release reaches fetched, replied, and delivered capability homes");
	}

	// Promise pipelining (ADR-0003), the questioner's half: `Session.send`
	// returns a handle that is also a `send` target, so a create -> assign ->
	// complete -> status chain may be issued against the `create` answer after a
	// fast resolution. The board's `create` spawns a
	// fresh task from inside the served turn (the turn-time spawn) and returns it;
	// the partner's engine queues the pipelined calls on that pending answer and
	// drains them onto the task once `create` resolves. A `status` of `done`
	// proves the chain crossed the wire without round-tripping per link.
	{
		const server = await tcp.listen("127.0.0.1", 0);
		const port = server.port;
		let markPublished!: () => void;
		const published = new Promise<void>((resolve) => (markPublished = resolve));

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
				markPublished();
				break; // one client is the proof; ending the loop closes the listener
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const session = await managed.connect(tcp.locator("127.0.0.1", port));
			session.serve().catch(() => {});
			await published;
			const root = await session.fetch("root");
			const task = session.send(root, "create", ["benchmark"]);
			const assigned = session.tell(task, "assign", ["alice"]);
			session.send(task, "complete", []);
			const pendingStatus = session.send(task, "status", []);
			await assigned;
			const status = await pendingStatus;
			assert(
				status === "done",
				`pipelined status should be done, got ${String(status)}`,
			);
			await session.close();
		}

		await Promise.all([client(), hosted]);
		ok("promise pipelining drives create->assign->complete->status as one batch");
	}

	// A promise is a send and tell argument (ADR-0068): the unawaited `make`
	// answer crosses as a capability for the pending answer in a tell the
	// board keeps and in a send it hands back, and the same promise crosses
	// settled as its value nested in a list. Greeting through the returned
	// handles proves all three reached the greeter.
	{
		const server = await tcp.listen("127.0.0.1", 0);
		const port = server.port;
		let markPublished!: () => void;
		const published = new Promise<void>((resolve) => (markPublished = resolve));

		async function host(): Promise<void> {
			for await (const session of server) {
				let kept: Argument = null;
				session.publish("root", (verb, args) => {
					if (verb === "keep") {
						kept = args[0];
						return "kept";
					}
					if (verb === "kept") return kept;
					if (verb === "make") {
						return session.spawn((greeterVerb) => {
							if (greeterVerb === "greet") return "hello from the greeter";
							throw new Error(`no such method: ${greeterVerb}`);
						});
					}
					if (verb === "use") return args[0];
					if (verb === "use-first") {
						const [items] = args;
						if (!Array.isArray(items)) throw new Error("use-first needs a list");
						return items[0];
					}
					throw new Error(`no such method: ${verb}`);
				});
				session.serve().catch(() => {});
				markPublished();
				break;
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const session = await managed.connect(tcp.locator("127.0.0.1", port));
			session.serve().catch(() => {});
			await published;
			const root = await session.fetch("root");
			const greeter = session.send(root, "make", []);
			await session.tell(root, "keep", [greeter]);
			const used = await session.send(root, "use", [greeter]);
			const kept = await session.send(root, "kept", []);
			// Observed settled, the promise passes as its value.
			// `make` answered before `use` on one session, so the promise is
			// settled when it passes again: the Host carries it as its value.
			assert((await greeter) instanceof Ref, "make answered with the greeter");
			const usedFirst = await session.send(root, "use-first", [[greeter]]);
			assert(used instanceof Ref && usedFirst instanceof Ref, "a passed promise returns as a capability");
			assert(kept instanceof Ref, "a promise told to the board returns as a capability");
			assert(
				await session.send(used, "greet", []) === "hello from the greeter",
				"the bare promise reached the greeter",
			);
			assert(
				await session.send(kept, "greet", []) === "hello from the greeter",
				"the told promise reached the greeter",
			);
			assert(
				await session.send(usedFirst, "greet", []) === "hello from the greeter",
				"the nested promise reached the greeter",
			);
			await session.close();
		}

		await Promise.all([client(), hosted]);
		ok("a pending promise passes as a capability, by send and tell, bare and nested in a list");
	}

	// A RemotePromise is namespaced by its owning Host, not merely its FFI vow
	// number. Two Hosts collide their ids; crossing the handles must
	// be refused before FFI while the destination's own promise remains exact.
	{
		const server = await tcp.listen("127.0.0.1", 0);
		const port = server.port;
		let firstReady!: () => void;
		let secondReady!: () => void;
		const ready = [
			new Promise<void>((resolve) => firstReady = resolve),
			new Promise<void>((resolve) => secondReady = resolve),
		];

		async function host(): Promise<void> {
			const serving: Promise<void>[] = [];
			let accepted = 0;
			for await (const session of server) {
				session.publish("root", (verb, args) => {
					assert(verb === "create", `unexpected method ${verb}`);
					const label = String(args[0]);
					return session.spawn((taskVerb) => {
						if (taskVerb === "label") return label;
						throw new Error(`unexpected method ${taskVerb}`);
					});
				});
				serving.push(session.serve().catch(() => {}));
				(accepted++ === 0 ? firstReady : secondReady)();
				if (accepted === 2) break;
			}
			await Promise.all(serving);
		}

		const hosted = host();
		await using firstRuntime = await Runtime.open({ providers: [tcp.provider()] });
		await using secondRuntime = await Runtime.open({ providers: [tcp.provider()] });
		const first = await firstRuntime.connect(tcp.locator("127.0.0.1", port));
		first.serve().catch(() => {});
		await ready[0];
		const firstRoot = await first.fetch("root");
		const firstTask = first.send(firstRoot, "create", ["first"]);
		const second = await secondRuntime.connect(tcp.locator("127.0.0.1", port));
		second.serve().catch(() => {});
		await ready[1];
		const secondRoot = await second.fetch("root");
		const secondTask = second.send(secondRoot, "create", ["second"]);
		assert(firstTask.vow === secondTask.vow, "the scenario needs colliding Host vow ids");
		let refused: GlowcapError | null = null;
		try {
			await second.send(firstTask, "label", []);
		} catch (error) {
			if (error instanceof GlowcapError) refused = error;
		}
		assert(refused?.code === INVALID_ARGUMENT, "a promise from another Host is refused before FFI");
		assert(await second.send(secondTask, "label", []) === "second", "the destination vow remains exact");
		await first.close();
		await second.close();
		await hosted;
		ok("promise targets retain their Host namespace across colliding vow ids");
	}

	// Host ownership, arriving-Port routing: the root is first projected through
	// one accepted Session, that Port closes, and a sibling invokes it. Its
	// callback uses the stale originating Session handle to spawn a
	// child; the active Host turn must select turn-spawn before that dead handle is
	// checked, and the child must ride the sibling's reply.
	{
		const server = await tcp.listen("127.0.0.1", 0);
		const port = server.port;
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
				await origin.close();
				readyResolve();
				await session.serve();
				break;
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			await using originRuntime = await Runtime.open({ providers: [tcp.provider()] });
			await using siblingRuntime = await Runtime.open({ providers: [tcp.provider()] });
			const origin = await originRuntime.connect(tcp.locator("127.0.0.1", port));
			origin.serve().catch(() => {});
			const sibling = await siblingRuntime.connect(tcp.locator("127.0.0.1", port));
			sibling.serve().catch(() => {});
			await ready;
			const introducer = await sibling.fetch("introducer");
			const root = await sibling.send(introducer, "get", []);
			assert(root instanceof Ref, "the sibling introduces the Host-owned root");
			const child = await sibling.send(root, "create", []);
			assert(child instanceof Ref, "create returns the turn-spawned child");
			assert(await sibling.send(child, "ping", []) === "alive", "the child is callable");
			await sibling.close();
			await origin.close();
		}

		await Promise.all([client(), hosted]);
		ok("turn-time spawn uses the Host after the originating Port closes");
	}

	// Pipelined projections (ADR-0004): `RemotePromise.index(i)` and
	// `.untag(tag)` access an element / unwrap a tag *at the answer*, before it
	// resolves, each returning a new pipelinable `RemotePromise`. The board's
	// `make` returns `["assigned", label, 7]` tagged "task"; untag unwraps the
	// single-value tag to that row, index 1 takes the label, a two-hop projection
	// chain that rides the still-pending `make` answer with no extra round trip.
	// The source handle is also awaited afterward to prove a far reply observed
	// *late* (after a sibling projection already pumped the loop) still settles
	// from the recorded outcome.
	{
		// Structural projection operations belong to v1.0; multi-location does not.
		const expectedFeatures = FEATURE_FULL & ~FEATURE_MULTI_LOCATION;
		const projectionHost = () => new Host(undefined, { codec: "capnp", captpVersion: "v1_0", features: "full" });
		await using serverHost = projectionHost();
		await using clientHost = projectionHost();
		let makePending = false;
		let releaseMake: (() => void) | undefined;
		let pipelineSentResolve!: () => void;
		const pipelineSent = new Promise<void>((resolve) => pipelineSentResolve = resolve);
		const uninstallTrace = enableTrace((event) => {
			if (
				event.kind === "ocapn.message-decoded" && event.outbound &&
				event.op === "pipeline-sentinel"
			) pipelineSentResolve();
		});
		serverHost.publish("root", (verb, args) => {
			if (verb === "release") {
				assert(makePending && releaseMake !== undefined, "release arrived before make deferred");
				releaseMake();
				return "released";
			}
			if (verb !== "make") throw new Error(`no such method: ${verb}`);
			const label = String(args[0] ?? "anon");
			makePending = true;
			return new Promise((resolve) => {
				releaseMake = () => resolve(tagged("task", [["assigned", label, 7n]]));
			});
		});
		const server = await tcp.listen("127.0.0.1", 0, { host: serverHost });
		const port = server.port;

		async function host(): Promise<void> {
			for await (const session of server) {
				assert(session.profile.captpVersion === "v1_0", "accepted session reports v1.0");
				assert(session.profile.codec === "capnp", "accepted session reports Cap'n Proto");
				assert(session.profile.features === expectedFeatures, "accepted session reports the v1.0 feature set");
				session.serve().catch(() => {});
				break;
			}
		}
		const hosted = host();
		await using clientRuntime = await Runtime.open({
			providers: [tcp.provider()],
			adoptHost: clientHost,
		});

		async function client(): Promise<void> {
			const session = await clientRuntime.connect(tcp.locator("127.0.0.1", port));
			assert(session.profile.captpVersion === "v1_0", "dialed session reports v1.0");
			assert(session.profile.codec === "capnp", "dialed session reports Cap'n Proto");
			assert(session.profile.features === expectedFeatures, "dialed session reports the v1.0 feature set");
			session.serve().catch(() => {});
			const root = await session.fetch("root");
			// None of these await a prior reply: the projections ride the unresolved
			// `make` answer and the whole chain leaves on one flush.
			const made = session.send(root, "make", ["alice"]);
			const label = made.untag("task").index(1);
			await session.tell(label, "pipeline-sentinel", []);
			await within(pipelineSent, 2_000, "pipelined projection transmission");
			assert(await session.send(root, "release", []) === "released", "release settles make");
			const projected = await label;
			assert(
				projected === "alice",
				`pipelined untag->index should reach the label, got ${String(projected)}`,
			);
			// The source answer settled while the projection pumped the loop;
			// observing it now must still resolve (a late observation settles from
			// the recorded outcome).
			const full = await made;
			assert(
				full instanceof Tagged && full.tag === "task",
				`awaited source should be the tagged task, got ${String(full)}`,
			);
			await session.close();
		}

		await client();
		await hosted;
		uninstallTrace();
		ok(
			"pipelined projections untag->index reach a field, and a late source await still settles",
		);
	}

	// Promise pipelining (ADR-0003), the unawaited-anchor contract: a `send`
	// handle is a real `Promise`, and an anchor whose far answer *breaks* (even
	// after its bytes flush on a sibling's tail) never raises an unhandled
	// rejection, because a handle that is never observed materializes no
	// rejection (the outcome is recorded, not thrown). This is the property that
	// lets a pipelining anchor go unawaited safely.
	{
		let unhandled = 0;
		let markBoomSeen!: () => void;
		const boomSeen = new Promise<void>((resolve) => markBoomSeen = resolve);
		const onUnhandled = (e: PromiseRejectionEvent) => {
			unhandled++;
			e.preventDefault();
		};
		globalThis.addEventListener("unhandledrejection", onUnhandled);

		await using anchorHost = new Host();
		anchorHost.publish("root", (verb) => {
			if (verb === "ping") return "pong";
			markBoomSeen();
			throw new Error(`boom: ${verb}`);
		});
		const server = await tcp.listen("127.0.0.1", 0, { host: anchorHost });
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
			const root = await session.fetch("root");
			const anchor = session.send(root, "explode", []);
			assert(anchor instanceof Promise, "a send handle must be a real Promise");
			// No later operation exists yet: creation itself must schedule progress. status-allow: pending state or quoted runtime label
			await boomSeen;
			// `anchor` is never observed; its break remains only a recorded outcome.
			// The break's FAIL completion is recorded with no waiter, no rejection.
			const pong = await session.send(root, "ping", []);
			assert(pong === "pong", `expected pong, got ${String(pong)}`);
			// The same-session ping reply is ordered after the explode break, so
			// observing it proves the runtime already drained the unobserved FAIL.
			assert(
				unhandled === 0,
				`unawaited break must not surface, saw ${unhandled}`,
			);
			await session.close();
		}

		try {
			await Promise.all([client(), hosted]);
		} finally {
			globalThis.removeEventListener("unhandledrejection", onUnhandled);
		}
		ok("an unawaited send is a real Promise whose far break never surfaces");
	}

	await runForeignFetch(managed);
}
