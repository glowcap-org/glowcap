// deno-lint-ignore-file no-inner-declarations -- scenarios keep local
// `server`/`client` function declarations inside their own bare blocks; the
// block scoping is the point (handles cannot leak across scenarios).
// Pipelining across the wire: the relay observes both directions, chains
// cross without per-link round-trips, children ride sibling replies,
// anchors go safely unawaited, and an ungranted position is refused as the
// probe it is.

import * as tcp from "@pancake/tcp";

import { type Argument, FetchFailed, Host, PStruct, Ref, Runtime, Session, Tagged, tagged } from "../../runtime/mod.ts";

import { _connectIroh } from "../../iroh/impl.ts";

import { assert, ok, startRelay } from "./support.ts";

export async function run(managed: Runtime): Promise<void> {
	{
		await using gcHost = new Host();
		const server = await tcp.listen("127.0.0.1", 0, { host: gcHost });
		const targetPort = server.port;
		const needle = new TextEncoder().encode("op:gc-export");
		let toServerTail = new Uint8Array();
		let toClientTail = new Uint8Array();
		let toServerGc = 0;
		let toClientGc = 0;
		const relay = await startRelay(targetPort, (c) => c, (chunk, toServer) => {
			const prior = toServer ? toServerTail : toClientTail;
			const combined = new Uint8Array(prior.length + chunk.length);
			combined.set(prior);
			combined.set(chunk, prior.length);
			for (let i = 0; i + needle.length <= combined.length; i++) {
				if (needle.every((byte, offset) => combined[i + offset] === byte)) {
					if (toServer) toServerGc++;
					else toClientGc++;
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
				session.publish("factory", (verb, args) => {
					if (verb === "reply") return new PStruct([["nested", [delegated]]]);
					assert(verb === "accept", `unexpected GC test verb ${verb}`);
					assert(
						args.length === 1 && args[0] instanceof PStruct &&
							args[0].entries[0][0] === "nested" && Array.isArray(args[0].entries[0][1]) &&
							args[0].entries[0][1][0] instanceof Ref,
						"the server received the nested capability argument",
					);
					return null;
				});
				session.serve().catch(() => {});
				break;
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const session = (await managed.connect(tcp.locator("127.0.0.1", relay.port))).withGc();
			session.serve().catch(() => {});
			const force = (): void => {
				const g = (globalThis as { gc?: () => void }).gc;
				if (typeof g === "function") g();
				const bun = (globalThis as { Bun?: { gc?: (sync: boolean) => void } }).Bun;
				if (bun && typeof bun.gc === "function") bun.gc(true);
			};
			let factory: Ref | null = await session.fetch("factory");
			let reply: Argument | null = await session.send(factory, "reply", []);
			assert(
				reply instanceof PStruct && reply.entries[0][0] === "nested" &&
					Array.isArray(reply.entries[0][1]) && reply.entries[0][1][0] instanceof Ref,
				"the send reply carries a nested capability",
			);
			reply = null;
			for (let i = 0; i < 400 && toServerGc < 1; i++) {
				force();
				await new Promise((r) => setTimeout(r, 5));
			}
			assert(toServerGc >= 1, "the nested send reply did not release");

			const callback = session.spawn(() => null);
			await session.send(factory, "accept", [new PStruct([["nested", [callback]]])]);
			for (let i = 0; i < 400 && toClientGc < 1; i++) {
				force();
				await new Promise((r) => setTimeout(r, 5));
			}
			assert(toClientGc >= 1, "the nested delivered argument did not release");

			factory = null;
			for (let i = 0; i < 400 && toServerGc < 2; i++) {
				force();
				await new Promise((r) => setTimeout(r, 5));
			}
			assert(toServerGc >= 2, "the fetched capability did not release");
			await session.close();
		}

		await Promise.all([client(), hosted]);
		relay.close();
		ok("GC releases fetched, replied, and delivered capability occurrences");
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
			await session.close();
		}

		await Promise.all([client(), hosted]);
		ok("promise pipelining drives create->assign->complete->status as one batch");
	}

	// Host ownership, arriving-Port routing: the root is first projected through
	// one accepted Session, that Port closes, and a sibling invokes it. Its
	// callback deliberately uses the stale originating Session handle to spawn a
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
		const nextHost = () => new Host(undefined, { captpVersion: "next" });
		await using serverHost = nextHost();
		await using clientHost = nextHost();
		serverHost.publishGiftable("root", (verb, args) => {
			if (verb !== "make") throw new Error(`no such method: ${verb}`);
			const label = String(args[0] ?? "anon");
			// A Tagged wrapping a single list value: untag unwraps to that row.
			return tagged("task", [["assigned", label, 7n]]);
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
		await using clientRuntime = await Runtime.open({
			providers: [tcp.provider()],
			adoptHost: clientHost,
		});

		async function client(): Promise<void> {
			const session = await clientRuntime.connect(tcp.locator("127.0.0.1", port));
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
			await session.close();
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

		await using anchorHost = new Host();
		anchorHost.publishGiftable("root", (verb) => {
			if (verb === "ping") return "pong";
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
			await session.close();
		}

		try {
			await Promise.all([client(), hosted]);
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
		const server = await tcp.listen("127.0.0.1", 0);
		const targetPort = server.port;
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
		let pending = new Uint8Array();
		const decoder = new TextDecoder();
		const encoder = new TextEncoder();
		function observe(chunk: Uint8Array, toServer: boolean): void {
			if (toServer || !capturing || plainExport >= 0n) return;
			observedWire += decoder.decode(chunk, { stream: true });
			const match = /desc:import-object(\d+)\+/.exec(observedWire);
			if (match !== null) plainExport = BigInt(match[1]);
		}
		function retarget(chunk: Uint8Array): Uint8Array {
			if (!armed || plainExport < 0n) return chunk;
			if (retargeted && pending.length === 0) return chunk;
			const joined = new Uint8Array(pending.length + chunk.length);
			joined.set(pending);
			joined.set(chunk, pending.length);
			pending = joined;

			const frames: Uint8Array[] = [];
			while (pending.length > 0) {
				let colon = -1;
				let bodyLength = 0;
				for (let i = 0; i < pending.length; i++) {
					const byte = pending[i];
					if (byte === 58) {
						colon = i;
						break;
					}
					if (byte < 48 || byte > 57) {
						const malformed = pending;
						pending = new Uint8Array();
						return malformed;
					}
					bodyLength = bodyLength * 10 + byte - 48;
				}
				if (colon < 0 || pending.length < colon + 1 + bodyLength) break;

				const frameEnd = colon + 1 + bodyLength;
				let body = pending.slice(colon + 1, frameEnd);
				pending = pending.slice(frameEnd);
				if (!retargeted) {
					const needle = encoder.encode("desc:export0+");
					outer: for (let i = 0; i + needle.length <= body.length; i++) {
						for (let j = 0; j < needle.length; j++) {
							if (body[i + j] !== needle[j]) continue outer;
						}
						const replacement = encoder.encode(`desc:export${plainExport}+`);
						const spliced = new Uint8Array(
							body.length - needle.length + replacement.length,
						);
						spliced.set(body.subarray(0, i));
						spliced.set(replacement, i);
						spliced.set(body.subarray(i + needle.length), i + replacement.length);
						body = spliced;
						retargeted = true;
						break;
					}
				}
				const prefix = encoder.encode(`${body.length}:`);
				const frame = new Uint8Array(prefix.length + body.length);
				frame.set(prefix);
				frame.set(body, prefix.length);
				frames.push(frame);
			}

			const size = frames.reduce((total, frame) => total + frame.length, 0);
			const output = new Uint8Array(size);
			let offset = 0;
			for (const frame of frames) {
				output.set(frame, offset);
				offset += frame.length;
			}
			return output;
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
			const session = await managed.connect(tcp.locator("127.0.0.1", relay.port));
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
			await session.close();
		}

		await Promise.all([client(), hosted]);
		relay.close();
		ok("a non-capability fetch rejects with the typed FetchFailed");
	}

	// A rude TCP probe — connect, say nothing, hang up — is that connection's
	// failure, not the listener's. The Server's iterator must skip the failed
	// handshake and keep accepting; without the skip, one port scan takes a
	// long-lived server down.
}
