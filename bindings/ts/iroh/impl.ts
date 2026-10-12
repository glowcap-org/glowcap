// Public and binding-internal composition for @glowcap/iroh. Native archive
// ownership lives in native.ts; channel.ts owns the runtime readiness pump.

import {
	bareLocator,
	type Channel,
	Connector,
	GlowcapError,
	HANDSHAKE_TIMEOUT_MS,
	HINT_DIRECT_ADDRESSES,
	Host,
	parseLocator,
	Reachability,
	Session,
	stringHint,
	TRANSPORT_IROH,
} from "@glowcap/runtime";
import { DriverListener, DriverLoop, DriverServer, retainCleanupFailures } from "@glowcap/runtime/transport";
import { CLOSED, INVALID_ARGUMENT } from "@glowcap/runtime/ffi";
import { dialResolving, IrohChannel, IrohLoop } from "./channel.ts";
import { type IrohConfig, IrohConnection, IrohNetlayer } from "./native.ts";

export { Reachability } from "@glowcap/runtime";
export { type IrohConfig, IrohConnection, IrohNetlayer, locator } from "./native.ts";

export type ListenOptions =
	| {
		/** Reuse this 32-byte identity seed across restarts. */
		readonly seed?: Uint8Array;
		readonly host?: never;
	}
	| {
		/** Share an existing Host and its session directory. */
		readonly host: Host;
		readonly seed?: never;
	};

/** Attach this package's resident through the generic provider seam. The
 * provider decides configuration equivalence; the driver owns occupancy. */
export async function _ensureIrohProvider(
	loop: DriverLoop,
	config: IrohConfig,
): Promise<{ readonly nodeId: string }> {
	const retainedConfig = { ...config };
	const netlayer = await IrohNetlayer.open(
		retainedConfig,
		loop.wrapperHost().seed,
		config.signal,
	);
	try {
		const nodeId = netlayer.nodeId();
		await netlayer.installProvider(loop);
		return { nodeId };
	} catch (error) {
		await netlayer.release();
		throw error;
	}
}

/** Configure an iroh endpoint package for `connect`. Reachability is provider
 * configuration because it controls endpoint services established at open. */
export function provider(config: IrohConfig): import("@glowcap/runtime").DriverProvider {
	return {
		async install(loop) {
			await _ensureIrohProvider(loop, config);
		},
	};
}

/** Configure an explicit byte-fed iroh connector. Native applications should
 * normally prefer `provider`; this form is for embedders that own
 * the channel pump. */
export function connector(config: IrohConfig): Connector {
	return new Connector([TRANSPORT_IROH], async (host, loc, request) => {
		const directAddresses = stringHint(loc, HINT_DIRECT_ADDRESSES) ?? "";
		const reachability = request.redeem && directAddresses.length > 0 ? Reachability.Direct : config.reachability;
		const signals = [config.signal, request.signal].filter(
			(value): value is AbortSignal => value != null,
		);
		const signal = signals.length > 1 ? AbortSignal.any(signals) : signals[0];
		return await _connectIroh(
			loc.designator,
			directAddresses,
			reachability,
			host,
			request.handshakeTimeoutMs,
			signal,
		);
	});
}

/** Binding-internal iroh dial behind the core's `connect(locator)`. Application
 * code dials through `connect(locator, { reachability, host })` only. The local
 * endpoint is ephemeral and released with the connection. `reachability` is
 * required. Needs the iroh ABI library (`zig build iroh-abi`).
 *
 * `handshakeTimeoutMs` bounds the OCapN handshake only. The dial-by-id budget
 * above it (a `Discovery` posture retries while the exporter's pkarr record
 * propagates, ADR-0082) is already spent by the time the channel exists, so a
 * slow discovery never eats the handshake's bound. */
export async function _connectIroh(
	nodeId: string,
	directAddresses: string,
	reachability: Reachability,
	host: Host = new Host(),
	handshakeTimeoutMs: number | null = HANDSHAKE_TIMEOUT_MS,
	signal?: AbortSignal,
): Promise<Session> {
	if (signal?.aborted) throw new GlowcapError(CLOSED, "host released while dialing");
	const netlayer = await IrohNetlayer.open({ reachability }, undefined, signal);
	if (signal?.aborted) {
		await netlayer.release();
		throw new GlowcapError(CLOSED, "host released while dialing");
	}
	const loop = new IrohLoop(netlayer);
	loop.start();
	let cancellation: Promise<void> | null = null;
	const cancelPending = (): void => {
		loop.close();
		cancellation ??= netlayer.release();
	};
	signal?.addEventListener("abort", cancelPending, { once: true });
	let conn: IrohConnection;
	try {
		conn = await dialResolving(loop, nodeId, directAddresses, reachability);
	} catch (e) {
		signal?.removeEventListener("abort", cancelPending);
		loop.close();
		await (cancellation ?? netlayer.release());
		throw e;
	}
	if (signal?.aborted) {
		signal.removeEventListener("abort", cancelPending);
		loop.close();
		await (cancellation ?? netlayer.release());
		throw new GlowcapError(CLOSED, "host released while dialing");
	}
	loop.register(conn);
	signal?.removeEventListener("abort", cancelPending);
	// The transport owns the dialer-minted connection, loop, and ephemeral
	// netlayer (`ownsLoop`); on a handshake failure or an elapsed handshake
	// bound `establishDialedLocator` abandons
	// the half-built connection, and its transport close is what unregisters
	// and releases the sidecar connection, stops the readiness loop (closing
	// the dup'd fd), and releases the netlayer. The connection is minted
	// against `host`, so the session's identity (a give's `recipient_key`) and
	// the host's live-session directory agrees. A three-party handoff requires this
	// (ADR-0009/ADR-0056).
	const transport = new IrohChannel(conn, loop, netlayer, true);
	const cancelTransport = (): void => {
		void transport.close().catch((error) => host.recordCallerlessBindingFailure("iroh.abort.cleanup", error));
	};
	if (signal?.aborted) {
		cancelTransport();
		throw new GlowcapError(CLOSED, "host released while dialing");
	}
	signal?.addEventListener("abort", cancelTransport, { once: true });
	// This module opened the connection, so it is the one place that can say
	// what QUIC proved about the far end. Passing it here is what makes the
	// session report `authenticated-transport` instead of resting on whatever
	// the partner claims about itself.
	try {
		return await Session.establishDialedLocator(
			host,
			bareLocator(TRANSPORT_IROH, nodeId),
			transport,
			handshakeTimeoutMs,
			conn.remoteNodeId(),
		);
	} finally {
		signal?.removeEventListener("abort", cancelTransport);
	}
}

/** Dial an iroh locator and return a byte channel for relay/bridge use.
 * Unlike `_connectIroh`, this returns just the channel, not a Session.
 * One call makes one transport attempt. A relay request is already one attempt
 * in its embedding application's reconnect policy, so retrying discovery here
 * would nest a second retry owner inside it.
 * The channel owns the loop and netlayer; calling `close()` cleans up
 * both and terminates the connection. For transparent relay endpoints
 * (e.g., browser peer → relay → native iroh). */
export async function dialLocatorForRelay(
	locator: string,
	reachability: Reachability,
): Promise<Channel> {
	const parsed = parseLocator(locator);
	if (parsed.transport !== TRANSPORT_IROH) {
		throw new GlowcapError(
			INVALID_ARGUMENT,
			`expected iroh locator, got transport: ${parsed.transport}`,
		);
	}

	const nodeId = parsed.designator;
	const directAddresses = stringHint(parsed, HINT_DIRECT_ADDRESSES) ?? "";

	const netlayer = await IrohNetlayer.open({ reachability, workerThreads: 1 });
	const loop = new IrohLoop(netlayer);
	loop.start();
	let conn: IrohConnection;
	try {
		conn = await loop.dial(nodeId, directAddresses);
	} catch (e) {
		loop.close();
		await netlayer.release();
		throw e;
	}
	loop.register(conn);

	// Return a channel that owns the connection, loop, and netlayer.
	// Calling close() terminates the connection and cleans up the loop/netlayer.
	const irohChannel = new IrohChannel(conn, loop, netlayer, true);
	return {
		read: () => irohChannel.read(),
		write: (data: Uint8Array) => irohChannel.write(data),
		close: () => irohChannel.close(),
	};
}

/** The iroh view over the binding's generic driver listener owner. The
 * resident owns endpoint I/O and this class projects only iroh metadata. */
export class IrohServer extends DriverServer {
	readonly #nodeId: string;

	constructor(listener: DriverListener, nodeId: string, ownedLoop?: DriverLoop) {
		super({ listener, ownedLoop });
		this.#nodeId = nodeId;
	}

	get nodeId(): string {
		return this.#nodeId;
	}

	get directAddresses(): string {
		return stringHint(this.locator, HINT_DIRECT_ADDRESSES) ?? "";
	}
}

/** Bind an iroh endpoint and return an `IrohServer` you iterate for each
 * accepted `Session`. `config` carries the endpoint's settings and is mandatory
 * because `reachability` is (see `IrohConfig`). `secretSeed` is a 32-byte
 * Ed25519 secret key for a stable endpoint id, or omitted for a fresh random
 * one shared with the `Host`. Pass `host` only when it was built from the same
 * seed, so netlayer and session share one identity (ADR-0075). The no-Host path
 * registers the endpoint with the generic native loop. A supplied Host is
 * transferred to that loop transactionally. Needs the iroh ABI library
 * (`zig build iroh-abi`).
 *
 * A server that treats a live session as presence should set
 * `config.idleTimeoutMs`, because that is what ends a connection whose peer was
 * killed rather than closed and so lets `serve()` settle. */
export async function listen(
	config: IrohConfig,
	options: ListenOptions = {},
): Promise<IrohServer> {
	const { seed: suppliedSeed, host } = options;
	const seed = suppliedSeed ?? host?.seed ?? crypto.getRandomValues(new Uint8Array(32));
	if (suppliedSeed != null && suppliedSeed.length !== 32) {
		throw new GlowcapError(INVALID_ARGUMENT, "listen: seed must be 32 bytes");
	}
	if (suppliedSeed != null && host != null) {
		throw new GlowcapError(
			INVALID_ARGUMENT,
			"listen: seed and host are alternative identity sources",
		);
	}
	const existingLoop = host?.driverLoop;
	const loop = existingLoop == null
		? host == null ? DriverLoop.open({ seed }) : DriverLoop.takeHost(host)
		: existingLoop as DriverLoop;
	let listener: DriverListener | null = null;
	try {
		const endpoint = await _ensureIrohProvider(loop, config);
		const endpointNodeId = endpoint.nodeId;
		listener = await DriverListener.open(
			loop,
			TRANSPORT_IROH,
			endpointNodeId,
			config.signal,
		);
		listener.select();
		const server = new IrohServer(
			listener,
			endpointNodeId,
			host == null ? loop : undefined,
		);
		listener = null;
		return server;
	} catch (error) {
		const cleanups: Array<() => void | Promise<void>> = [];
		const failedListener = listener;
		if (failedListener != null) cleanups.push(() => failedListener.close());
		if (host == null) cleanups.push(() => loop.close());
		await retainCleanupFailures(error, cleanups);
		throw error;
	}
}
