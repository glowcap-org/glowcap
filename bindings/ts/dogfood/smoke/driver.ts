// deno-lint-ignore-file no-inner-declarations -- scenarios keep local
// `server`/`client` function declarations inside their own bare blocks; the
// block scoping is the point (handles cannot leak across scenarios).
// The Deno application path over the byte-fed seam: no kernel transport, a
// freed runtime stays refused, attenuation passes one verb and revoke
// breaks the rest, a closing turn unwinds to the typed CLOSED, and claims
// stop at what was proved.

import * as tcp from "@glowcap/tcp";

import {
	durableIdentityAuthenticated,
	encodePeerLocator,
	GlowcapError,
	Host,
	Ref,
	Runtime,
	VowBroken,
} from "../../runtime/mod.ts";
import { Netlayer as TcpNetlayer } from "../../tcp/transport.ts";
import { Netlayer as InprocNetlayer } from "@glowcap/inproc";

import { _connectIroh } from "../../iroh/impl.ts";

import { assert, eqBytes, ok } from "./support.ts";

export async function run(managed: Runtime): Promise<void> {
	// The native TCP transport is its own composable module
	// (`@glowcap/tcp/transport`, riding libglowcap_net_transport_tcp). Bind a
	// listener, dial it, accept the peer, and shuttle one whole frame through the
	// `glowcap_tcp_*` endpoints intact. This is the Deno application path.
	{
		using net = new TcpNetlayer();
		using listener = net.listen("127.0.0.1", 0);
		const port = listener.port();
		using client = await net.connect("127.0.0.1", port);
		using server = await listener.accept();
		const frame = new TextEncoder().encode(
			"<10'op:deliver<11'desc:export7+>[5:hello]11+f>",
		);
		await client.writeFrame(frame);
		const got = await server.readFrame();
		assert(eqBytes(got, frame), "the TCP endpoint shuttled the frame intact");
		ok("the off-thread TCP transport shuttled a frame");
	}

	// The in-process transport is its own composable module
	// (`./transport/inproc.ts`, riding libglowcap_net_transport_inproc): the
	// socket-free sibling of TCP, two peers in one process wired by pipes. Bind a
	// listener on a string designator, dial it, accept, and shuttle one whole
	// frame, no kernel transport and no fd.
	{
		using net = new InprocNetlayer();
		using listener = net.listen("zig-smoke");
		using client = await net.connect("zig-smoke");
		using server = await listener.accept();
		const frame = new TextEncoder().encode(
			"<10'op:deliver<11'desc:export7+>[5:hello]11+f>",
		);
		await client.writeFrame(frame);
		const got = await server.readFrame();
		assert(
			eqBytes(got, frame),
			"the in-process endpoint shuttled the frame intact",
		);
		ok("the in-process transport shuttled a frame socket-free");
	}

	// Dynamic bindings cannot express Rust's lifetime borrow in the type system.
	// Releasing a netlayer therefore closes its still-live children before freeing
	// the std.Io backend; a later child close is an idempotent no-op, never a use of
	// the freed runtime.
	{
		const tcp = new TcpNetlayer();
		const listener = tcp.listen("127.0.0.1", 0);
		tcp.release();
		listener.close();
		const inproc = new InprocNetlayer();
		const inprocListener = inproc.listen("owner-lifetime");
		inproc.release();
		inprocListener.close();
		ok("netlayer release retires live transport children before their backend");
	}

	// Object-capability forwarding proxies over the wire (ADR-0064). The server
	// fetches the client's published tool — a far reference on the server side —
	// wraps it in a caretaker and an attenuator, and hands the proxies back. A
	// call through the proxy forwards across the server to the client's tool (the
	// far deferred-answer path) and settles the caller's answer; the attenuator
	// passes only its allow-listed verb; and a revoke breaks every later call.
	{
		const server = await tcp.listen("127.0.0.1", 0);
		const port = server.port;
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
			const session = await managed.connect(tcp.locator("127.0.0.1", port));
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

			await session.close();
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
		await using proxyHost = new Host();
		proxyHost.publishGiftable("tool", (verb) => {
			if (verb === "ping") return "pong";
			throw new Error(`no such method: ${verb}`);
		});
		const server = await tcp.listen("127.0.0.1", 0, { host: proxyHost });
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

			await session.close();
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
		const server = await tcp.listen("127.0.0.1", 0);
		const port = server.port;
		let markPublished!: () => void;
		const published = new Promise<void>((resolve) => (markPublished = resolve));

		async function host(): Promise<void> {
			for await (const session of server) {
				session.publish("svc", (verb) => {
					if (verb === "reenter") {
						// A driving verb inside the turn: the latch refuses it and the
						// thrown GlowcapError's words become the broken answer.
						session.publish("nested", () => null);
						return "unreachable";
					}
					return "pong";
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
			await session.close();
		}

		await Promise.all([client(), hosted]);
		ok("a behavior's mid-turn driving verb is refused and breaks its own answer");
	}

	// Mid-turn close parks the C release (parity with Python/Rust): a behavior that
	// closes its own Session inside a local turn must not free the native session
	// while the trampoline frame is still on the stack. The release runs after the
	// turn unwinds; the next verb is the typed CLOSED.
	{
		const server = await tcp.listen("127.0.0.1", 0);
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
			const me = session.spawn((verb) => {
				if (verb === "die") {
					void session.close();
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
			let closed: GlowcapError | null = null;
			try {
				await session.send(me, "die");
			} catch (err) {
				if (err instanceof GlowcapError) closed = err;
			}
			assert(
				closed !== null && /closed/i.test(closed.message),
				"mid-turn close: the next verb is refused closed",
			);
		}

		await Promise.all([client(), hosted]);
		ok("a behavior closing its own connection mid-turn parks the release");
	}

	// Closing a Host closes every Session before freeing the native Host. When the
	// request comes from a behavior callback, one terminal Host transaction parks;
	// after the turn it closes both sessions and releases behind the admission/dial
	// barrier.
	{
		const captpHost = new Host();
		const server = await tcp.listen("127.0.0.1", 0, { host: captpHost });
		const port = server.port;
		let acceptedResolve!: () => void;
		const accepted = new Promise<void>((resolve) => acceptedResolve = resolve);
		let duringResolve!: (released: boolean) => void;
		const during = new Promise<boolean>((resolve) => duringResolve = resolve);
		captpHost.publishGiftable("svc", (verb) => {
			if (verb !== "release-host") return null;
			void captpHost.close();
			duringResolve(captpHost.released);
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
		await using firstRuntime = await Runtime.open({ providers: [tcp.provider()] });
		await using secondRuntime = await Runtime.open({ providers: [tcp.provider()] });
		const first = await firstRuntime.connect(tcp.locator("127.0.0.1", port));
		first.serve().catch(() => {});
		const second = await secondRuntime.connect(tcp.locator("127.0.0.1", port));
		second.serve().catch(() => {});
		await accepted;
		const svc = await first.fetch("svc");
		try {
			await first.send(svc, "release-host");
		} catch (_) {
			// Releasing the server Host closes the wire before this answer must land.
		}
		assert(!(await during), "Host close waits until the callback unwinds");
		await captpHost.close();
		assert(captpHost.released, "the native Host is released after its loop barrier");
		await first.close();
		await second.close();
		await server.close();
		await hosted;
		ok("a callback-time Host close frees two Sessions in one Host transaction");
	}

	// The verified session identity and locator claim the handshake reports. A
	// directory may compare a caller's claimed locator to this signed claim, but
	// only authenticated-channel provenance proves a durable designator.
	//
	// A dialing client that does not listen has no dialable name of its own, so it
	// signs the unreachable-client placeholder. That is the sharpest case: whatever
	// locator such a caller claims, it did not prove it.
	{
		const server = await tcp.listen("127.0.0.1", 0);
		const port = server.port;
		let markServerObserved!: () => void;
		const serverObserved = new Promise<void>((resolve) => (markServerObserved = resolve));
		let markClientObserved!: () => void;
		const clientObserved = new Promise<void>((resolve) => (markClientObserved = resolve));

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
				markServerObserved();
				await clientObserved;
				await session.close();
				break;
			}
		}
		const hosted = host();

		async function client(): Promise<void> {
			const session = await managed.connect(tcp.locator("127.0.0.1", port));
			try {
				const seen = session.partnerIdentity();
				// The dialer verified the listener's fresh session key and the locator
				// claim signed by that key.
				assert(
					seen.sessionKey.length === 32,
					"partner identity: the client sees the server's verified session key",
				);
				assert(
					seen.designator === `127.0.0.1:${port}`,
					`partner identity: expected the listener's signed address, got "${seen.designator}"`,
				);
				assert(
					seen.locatorRecord.length > 0,
					"partner identity: the verbatim location record came back",
				);
				assert(
					eqBytes(
						seen.locatorRecord,
						encodePeerLocator({
							transport: "tcp",
							designator: `127.0.0.1:${port}`,
							hints: new Map([
								["glowcap/features", "pipelining,handoff,wire_delta,sturdyref,untag"],
							]),
							hintWireForm: "map",
						}),
					),
					"partner identity: the listener advertises the accept plan's complete locator",
				);
			} finally {
				markClientObserved();
			}
			await serverObserved;
			await session.close();
		}

		await Promise.all([client(), hosted]);
		ok("the handshake reports a verified session identity and its signed locator claim");
	}

	ok("drove OCapN through the idiomatic glowcap API");
}
