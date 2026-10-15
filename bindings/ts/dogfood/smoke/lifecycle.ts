// deno-lint-ignore-file no-inner-declarations -- scenarios keep local
// `server`/`client` function declarations inside their own bare blocks; the
// block scoping is the point (handles cannot leak across scenarios).
// Lifetimes at the seam: long-lived servers going down, explicit dialable
// advertisement, terminal finishes that release the endpoint and the event
// loop, the browser-shaped restart, and timeouts that escalate from their
// own waking step.

import * as tcp from "@glowcap/tcp";

import { DESIGNATOR_SCHEME_ADDRESS, INVALID_ARGUMENT, TIMEOUT } from "@glowcap/abi";
import { connectTcp, listenTcp, type NetConn } from "../../runtime/internal/seam.ts";
import { bareLocator, GlowcapError, Host, Runtime, Session, Sym } from "../../runtime/mod.ts";

import { _connectIroh, IrohNetlayer, Reachability } from "../../iroh/impl.ts";
import { NULL } from "../../runtime/internal/ffi/runtime.ts";
import { entryFor } from "../../runtime/trampoline.ts";

import { assert, ok, within } from "./support.ts";
import { runFinishClosePolicy } from "./finish_close.ts";

export async function run(managed: Runtime): Promise<void> {
	// A rude TCP probe (connect, say nothing, hang up) is that connection's
	// failure, not the listener's. The iterator must skip its failed handshake
	// and keep accepting, so one port scan cannot take down a long-lived server.
	{
		await using probeHost = new Host();
		// Host-wide publications hand their JS callback ownership to the FFI
		// Vat. Unpublish retires the actor; the next outermost turn is the borrowed
		// reply boundary that drops its box and invokes the shared free callback.
		probeHost.publish("retired", () => null);
		const publishedCtx = probeHost.publicationCtx("retired");
		assert(
			publishedCtx !== undefined,
			"Host publication exposes its FFI callback context",
		);
		const retiredCtx: bigint = publishedCtx;
		assert(
			entryFor(retiredCtx) !== undefined,
			"Host publication owns its JS behavior",
		);
		assert(probeHost.unpublish("retired"), "the live Host publication should unpublish");
		probeHost.publish("svc", () => new Sym("alive"));
		const server = await tcp.listen("127.0.0.1", 0, { host: probeHost });
		const port = server.port;

		async function serveOne(): Promise<void> {
			for await (const session of server) {
				session.serve().catch(() => {});
				break; // one real client is the proof; ending the loop closes the listener
			}
		}
		const served = serveOne();

		const probe = await connectTcp("127.0.0.1", port);
		probe.close();

		async function client(): Promise<void> {
			const session = await managed.connect(tcp.locator("127.0.0.1", port));
			session.serve().catch(() => {});
			const svc = await session.fetch("svc");
			const reply = await session.send(svc, "ping", []);
			assert(
				reply instanceof Sym && (reply as Sym).value === "alive",
				"the listener survived the rude probe and served the next client",
			);
			assert(
				entryFor(retiredCtx) === undefined,
				"the next FFI turn should release a retired publication's JS behavior",
			);
			await session.close();
		}
		// Join both owners: the serve loop must survive the probe and the real client
		// must complete before this scenario can release their loops.
		await Promise.all([client(), served]);
		ok("unpublish reclaims a TypeScript Host publication behavior at the next turn boundary");
		ok("a rude probe cannot close the listener");
	}

	// Bind policy and reachability are different facts. A wildcard address needs
	// an explicit dialable advertisement; the driver owns admission.
	{
		let wildcardError: GlowcapError | null = null;
		try {
			await tcp.listen("0.0.0.0", 0);
		} catch (error) {
			if (error instanceof GlowcapError) wildcardError = error;
		}
		assert(
			wildcardError?.code === INVALID_ARGUMENT,
			"a wildcard bind without advertisedHost must fail typed",
		);

		const server = await tcp.listen("0.0.0.0", 0, {
			advertisedHost: "127.0.0.1",
		});
		const port = server.port;
		let published!: () => void;
		const ready = new Promise<void>((resolve) => {
			published = resolve;
		});
		const served = (async () => {
			for await (const session of server) {
				session.publish("svc", () => new Sym("alive"));
				session.serve().catch(() => {});
				published();
				break;
			}
		})();
		const silent = await connectTcp("127.0.0.1", port);
		let session: Session | null = null;
		try {
			session = await within(
				managed.connect(tcp.locator("127.0.0.1", port)),
				2_000,
				"listener behind a silent peer",
			);
			await within(ready, 2_000, "listener publication");
			const seen = session.partnerIdentity();
			assert(
				seen.designator === tcp.addressDesignator("127.0.0.1", port),
				`listener advertised ${seen.designator} instead of its explicit reachability`,
			);
			const svc = await session.fetch("svc");
			const reply = await session.send(svc, "ping", []);
			assert(reply instanceof Sym && reply.value === "alive", "the real peer was served");
			await within(served, 2_000, "listener serve loop");
		} finally {
			if (session != null) await session.close();
			silent.close();
			await server.close();
		}
		ok("the driver bypasses a silent peer and wildcard reachability is explicit");
	}

	// Host teardown owns listener admission: an accept already parked for the next
	// partner must finish terminally instead of retaining the Host or event loop.
	{
		const server = await tcp.listen("127.0.0.1", 0);
		const iterator = server[Symbol.asyncIterator]();
		const pending = iterator.next();
		await Promise.resolve();
		const closing = server.host.close();
		const result = await within(pending, 1_000, "Host-close listener admission");
		assert(result.done === true, "a released Host cannot admit another session");
		await closing;
		ok("Host close stops listener admission");
	}

	// Endpoint creation runs in an offloaded FFI call that cannot be interrupted.
	// An abort during that await must release the endpoint before dialing starts.
	{
		let finishOpen: ((netlayer: IrohNetlayer) => void) | undefined;
		let released = false;
		const opened = new Promise<IrohNetlayer>((resolve) => {
			finishOpen = resolve;
		});
		const netlayer = {
			release: () => {
				released = true;
				return Promise.resolve();
			},
		} as unknown as IrohNetlayer;
		const netlayerType = IrohNetlayer as unknown as {
			open: typeof IrohNetlayer.open;
		};
		const originalOpen = netlayerType.open;
		netlayerType.open = () => opened;
		const abort = new AbortController();
		const host = new Host();
		try {
			const dialing = _connectIroh(
				"00".repeat(32),
				"",
				Reachability.Direct,
				host,
				null,
				abort.signal,
			);
			abort.abort();
			finishOpen?.(netlayer);
			try {
				await dialing;
				throw new Error("an aborted iroh endpoint open continued into dialing");
			} catch (error) {
				assert(error instanceof GlowcapError, "iroh open abort lost its typed error");
			}
			assert(released, "iroh open abort did not release the constructed endpoint");
		} finally {
			netlayerType.open = originalOpen;
			await host.close();
		}
		ok("an iroh abort during endpoint creation releases before dialing");
	}

	// A popped FLUSH may await byte-channel I/O. Host close waits for that
	// admitted drain to return instead of freeing the action queue under it. This
	// uses raw runtime sockets plus Session.establish* so the proof
	// stays on the byte-fed Host seam; a DriverLoop owns its own drain.
	{
		const listener = await listenTcp("127.0.0.1", 0);
		const designator = tcp.addressDesignator("127.0.0.1", listener.port);
		await using serverHost = new Host();
		const host = new Host();
		const accepting = (async () =>
			Session.establishAccepted(serverHost, {
				transport: "tcp",
				designatorScheme: DESIGNATOR_SCHEME_ADDRESS,
				serverDesignator: designator,
				channel: await listener.accept(),
			}))();
		const dialing = Session.establishDialedLocator(
			host,
			bareLocator("tcp", designator),
			await connectTcp("127.0.0.1", listener.port),
		);
		const [serverSession, session] = await Promise.all([accepting, dialing]);
		const failedNotice = session.spawn(() => {
			throw new Error("local notice failed");
		});
		await session.tell(failedNotice, "notify");
		const tellFailures = host.takeFailures();
		assert(tellFailures.length === 1, "local tell retained exactly one callerless failure");
		assert(
			tellFailures[0].operation === "tell.behavior" &&
				tellFailures[0].layer === "application-observer" &&
				tellFailures[0].scopeId > 0n &&
				tellFailures[0].primaryName === "Error" &&
				tellFailures[0].primaryMessage === "local notice failed",
			"local tell retained its exact behavior failure",
		);
		serverSession.publish("svc", () => new Sym("alive"));
		const servingServer = serverSession.serve().catch(() => {});
		const servingClient = session.serve().catch(() => {});
		const svc = await session.fetch("svc");
		let enteredFlush!: () => void;
		const flushEntered = new Promise<void>((resolve) => enteredFlush = resolve);
		let finishFlush!: () => void;
		const flushGate = new Promise<void>((resolve) => finishFlush = resolve);
		const flushOutbound = session.flushOutbound.bind(session);
		session.flushOutbound = async () => {
			enteredFlush();
			await flushGate;
			await flushOutbound();
		};
		const reply = Promise.resolve(session.send(svc, "ping", [])).catch(() => null);
		await within(flushEntered, 1_000, "action drain FLUSH");
		let released = false;
		const releasing = host.close().then(() => released = true);
		await Promise.resolve();
		assert(!released, "Host close passed an in-flight action drain");
		finishFlush();
		await releasing;
		await reply;
		listener.close();
		await serverHost.close();
		await Promise.all([servingServer, servingClient]);
		ok("Host close joins admitted action drains");
	}

	// FLUSH runs inside the Host action drain, where failing the drain itself
	// would misattribute one connection's byte-channel fault to every session on
	// that Host. The Session retains the exact first fault and reports it through
	// its user-visible operation and both terminal boundaries instead.
	{
		const listener = await listenTcp("127.0.0.1", 0);
		const designator = tcp.addressDesignator("127.0.0.1", listener.port);
		const serverHost = new Host();
		const host = new Host();
		const firstFailure = new Error("injected exact FLUSH failure");
		let failClientWrites = false;
		let closeBarrierRelease!: () => void;
		const closeBarrier = new Promise<void>((resolve) => closeBarrierRelease = resolve);
		const accepting = (async () =>
			Session.establishAccepted(serverHost, {
				transport: "tcp",
				designatorScheme: DESIGNATOR_SCHEME_ADDRESS,
				serverDesignator: designator,
				channel: await listener.accept(),
			}))();
		const clientChannel = await connectTcp("127.0.0.1", listener.port);
		const dialing = Session.establishDialedLocator(
			host,
			bareLocator("tcp", designator),
			{
				read: () => clientChannel.read(),
				write: (data) => failClientWrites ? Promise.reject(firstFailure) : clientChannel.write(data),
				close: () => {
					clientChannel.close();
					return closeBarrier;
				},
			},
		);
		const [serverSession, session] = await Promise.all([accepting, dialing]);
		serverSession.publish("svc", () => new Sym("alive"));
		const servingServer = serverSession.serve();
		const clientOutcome = session.serve().then(
			() => ({ error: null }),
			(error) => ({ error }),
		);
		const svc = await session.fetch("svc");
		failClientWrites = true;
		const tellOutcome = session.tell(svc, "ping", []).then(
			() => ({ error: null }),
			(error) => ({ error }),
		);
		const served = await within(clientOutcome, 2_000, "failed FLUSH retiring serve");
		assert(served.error === firstFailure, "serve lost the exact FLUSH failure");
		const told = await tellOutcome;
		assert(told.error === firstFailure, "tell lost the exact FLUSH failure");
		let closeSettled = false;
		const closeOutcome = session.close().then(
			() => ({ error: null }),
			(error) => ({ error }),
		).finally(() => closeSettled = true);
		await Promise.resolve();
		assert(!closeSettled, "close reported the FLUSH failure before transport retirement");
		closeBarrierRelease();
		const { error: closeFailure } = await closeOutcome;
		assert(closeFailure === firstFailure, "close lost the exact FLUSH failure");
		await servingServer;
		listener.close();
		await Promise.all([host.close(), serverHost.close()]);
		ok("Session tell, serve, and close retain the exact first FLUSH failure");
	}

	// Host-wide close is also a physical transport barrier. A channel refusal has
	// no later Session owner once the FFI Host is consumed, so the Host close
	// must return it rather than merely marking the rejected promise handled.
	{
		const listener = await listenTcp("127.0.0.1", 0);
		const designator = tcp.addressDesignator("127.0.0.1", listener.port);
		const serverHost = new Host();
		const host = new Host();
		const closeFailure = new Error("injected Host transport-close failure");
		const accepting = (async () =>
			Session.establishAccepted(serverHost, {
				transport: "tcp",
				designatorScheme: DESIGNATOR_SCHEME_ADDRESS,
				serverDesignator: designator,
				channel: await listener.accept(),
			}))();
		const clientChannel = await connectTcp("127.0.0.1", listener.port);
		const dialing = Session.establishDialedLocator(host, bareLocator("tcp", designator), {
			read: () => clientChannel.read(),
			write: (data) => clientChannel.write(data),
			close: () => {
				clientChannel.close();
				return Promise.reject(closeFailure);
			},
		});
		await Promise.all([accepting, dialing]);
		const outcome = await host.close().then(
			() => ({ error: null }),
			(error) => ({ error }),
		);
		assert(outcome.error === closeFailure, "Host close swallowed its session transport-close failure");
		listener.close();
		await serverHost.close();
		ok("Host close joins and preserves session transport-close failure");
	}

	// Natural byte-channel loss retires the core's dial index before the wrapper
	// itself is collected. Reconnect uses the same Host and the same address, the
	// shape a browser keeps across a room-server restart.
	{
		const listener = await listenTcp("127.0.0.1", 0);
		const designator = tcp.addressDesignator("127.0.0.1", listener.port);
		await using serverHost = new Host();
		await using host = new Host();
		const openPair = async (): Promise<[Session, Session]> => {
			const accepting = (async () =>
				Session.establishAccepted(serverHost, {
					transport: "tcp",
					designatorScheme: DESIGNATOR_SCHEME_ADDRESS,
					serverDesignator: designator,
					channel: await listener.accept(),
				}))();
			const dialing = Session.establishDialedLocator(
				host,
				bareLocator("tcp", designator),
				await connectTcp("127.0.0.1", listener.port),
			);
			return await Promise.all([accepting, dialing]);
		};

		const [serverFirst, first] = await openPair();
		const firstEnded = first.serve();
		// Retire the serve loop's admitted initial drain so this is an idle-peer
		// EOF, not a peer close racing bytes already committed for delivery.
		await Promise.all([host.settleActions(), serverHost.settleActions()]);
		serverFirst.closeTransport();
		await within(firstEnded, 2_000, "the lost client session retiring");
		assert(first.raw === NULL, "natural transport loss resolved serve before releasing the Host session");

		const [serverAgain, again] = await openPair();
		const serverServing = serverAgain.serve();
		const clientServing = again.serve();
		await again.close();
		await serverServing;
		await serverAgain.close();
		await clientServing;
		listener.close();
		ok("natural transport loss releases the same-target reconnect index");
	}

	await runFinishClosePolicy();

	// A core-issued CANCEL_DIAL interrupts and joins exactly its ticketed physical
	// operation before acknowledging retirement.
	{
		const host = new Host();
		let aborted = false;
		let markStarted!: () => void;
		const started = new Promise<void>((resolve) => markStarted = resolve);
		host.startDialTask(1n, 0n, (signal) =>
			new Promise<void>((resolve) => {
				markStarted();
				signal.addEventListener("abort", () => {
					aborted = true;
					resolve();
				}, { once: true });
			}));
		await started;
		await host.cancelDialTask(1n, 0n);
		assert(aborted, "CANCEL_DIAL must abort its ticketed operation");
		await host.close();
		ok("CANCEL_DIAL joins its ticketed dial work");
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

		let timedOut: GlowcapError | null = null;
		try {
			await using timeoutRuntime = await Runtime.open({
				providers: [tcp.provider()],
				handshakeTimeoutMs: 250,
			});
			await timeoutRuntime.connect(tcp.locator("127.0.0.1", listener.port));
		} catch (err) {
			if (err instanceof GlowcapError) timedOut = err;
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
}
