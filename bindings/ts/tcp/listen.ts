// Generic native-driver listener surfaces. The driver owns the socket,
// admission, handshake, events, and terminal release; this module only
// projects listener metadata and accepted handles into the TypeScript API.

import {
	designatorHostPort,
	DriverListener,
	DriverLoop,
	DriverServer,
	ensureRuntimeReady,
	formatPeerUri,
	GlowcapError,
	HINT_DIRECT_ADDRESSES,
	Host,
	listenerLoopUnavailable,
	loopTierAvailable,
	prepareListenerLoop,
	retainCleanupFailures,
	stringHint,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_TCP,
	TRANSPORT_TCP,
} from "@glowcap/runtime/transport";
import type { Codec } from "@glowcap/runtime/transport";
import { addressDesignator } from "./address.ts";
import { type Config, installProvider as installTcpProvider } from "./transport.ts";
import { INVALID_ARGUMENT, IO } from "@glowcap/abi";

export interface ListenOptions {
	/** Defaults inherited by every TCP stream admitted through this provider. */
	readonly config?: Config;
	/** Dialable address to sign when the socket binds a wildcard interface. */
	readonly advertisedHost?: string;
	/** Cancel listener construction before the driver reports readiness. */
	readonly signal?: AbortSignal;
	/** Reuse this Host's identity, publications, and handoff router. */
	readonly host?: Host;
	/** Wire codec for a newly minted Host. */
	readonly codec?: Codec;
}

export type KeyedListenOptions =
	| (Omit<ListenOptions, "host"> & {
		/** Reuse this 32-byte identity seed across restarts. */
		readonly seed?: Uint8Array;
		readonly host?: never;
	})
	| (Omit<ListenOptions, "host"> & {
		/** Share an existing Host instead of supplying a separate seed. */
		readonly host: Host;
		readonly seed?: never;
	});

/** A native-driver listener. Its Host is the driver's Host wrapper, which is
 * either minted by the loop or the exact supplied wrapper transferred through
 * `glowcap_driver_take_host`. */
export class Server extends DriverServer {
	get port(): number {
		const locator = this.locator;
		const address = stringHint(locator, HINT_DIRECT_ADDRESSES) ?? locator.designator;
		return designatorHostPort(address).port;
	}
}

function configureTcpProfileListener(
	listener: DriverListener,
	transport: string,
	options: ListenOptions,
): void {
	const locator = listener.locator();
	const boundDirect = stringHint(locator, HINT_DIRECT_ADDRESSES) ??
		(transport === TRANSPORT_TCP ? locator.designator : null);
	if (boundDirect == null) {
		throw new GlowcapError(
			INVALID_ARGUMENT,
			`${transport} listener locator has no ${HINT_DIRECT_ADDRESSES} hint`,
		);
	}
	const direct = dialableSocketAddress(boundDirect, options.advertisedHost);
	if (direct !== boundDirect) {
		listener.advertise(
			transport === TRANSPORT_TCP ? formatPeerUri(transport, direct) : formatPeerUri(
				transport,
				locator.designator,
				new Map([[HINT_DIRECT_ADDRESSES, direct]]),
			),
		);
	}
	listener.select();
}

function wildcardHost(hostname: string): boolean {
	const bare = hostname.startsWith("[") && hostname.endsWith("]") ? hostname.slice(1, -1) : hostname;
	const ipv6Unspecified = bare.includes(":") &&
		bare.split(":").every((part) => part === "" || /^0+$/.test(part));
	return bare === "0.0.0.0" || ipv6Unspecified;
}

function dialableSocketAddress(boundAddress: string, advertisedHost?: string): string {
	const { hostname, port } = designatorHostPort(boundAddress);
	if (wildcardHost(hostname) && advertisedHost == null) {
		throw new GlowcapError(
			INVALID_ARGUMENT,
			"a wildcard bind has no dialable address; provide advertisedHost",
		);
	}
	if (advertisedHost != null && wildcardHost(advertisedHost)) {
		throw new GlowcapError(INVALID_ARGUMENT, "an advertised host must be dialable");
	}
	return advertisedHost == null ? boundAddress : addressDesignator(advertisedHost, port);
}

/** Bind plain TCP through the generic driver. A supplied Host is transferred
 * before binding, preserving that wrapper as the server's Host authority. */
async function listenProfile(
	transport: string,
	bindHost: string,
	port: number,
	options: ListenOptions,
	seed?: Uint8Array,
): Promise<Server> {
	if (seed != null && seed.length !== 32) {
		throw new GlowcapError(INVALID_ARGUMENT, `${transport} listen: seed must be 32 bytes`);
	}
	await ensureRuntimeReady();
	if (!loopTierAvailable()) throw listenerLoopUnavailable();
	let prepared: { loop: DriverLoop; ownsLoop: boolean } | null = null;
	let listener: DriverListener | null = null;
	try {
		prepared = prepareListenerLoop(options.host, seed, options.codec);
		const loop = prepared.loop;
		installTcpProvider(loop, options.config);
		listener = await DriverListener.open(
			loop,
			transport,
			addressDesignator(bindHost, port),
			options.signal,
		);
		configureTcpProfileListener(listener, transport, options);
		const server = new Server({
			listener,
			ownedLoop: prepared.ownsLoop ? loop : undefined,
		});
		listener = null;
		return server;
	} catch (error) {
		const primary = error instanceof GlowcapError ? error : new GlowcapError(IO, String(error));
		const failedListener = listener;
		const ownedLoop = prepared?.ownsLoop ? prepared.loop : null;
		const cleanups: Array<() => void | Promise<void>> = [];
		if (failedListener != null) cleanups.push(() => failedListener.close());
		if (ownedLoop != null) cleanups.push(() => ownedLoop.close());
		await retainCleanupFailures(primary, cleanups);
		throw primary;
	}
}

export function listen(
	bindHost: string,
	port: number,
	options: ListenOptions = {},
): Promise<Server> {
	return listenProfile(TRANSPORT_TCP, bindHost, port, options);
}

/** Bind a native-loop `noise-tcp` server. Reuse the optional 32-byte `seed`
 * across restarts to keep the same durable key designator; a fresh per-process
 * session-key root is still drawn. */
export function listenNoise(
	bindHost: string,
	port: number,
	options: KeyedListenOptions = {},
): Promise<Server> {
	return listenProfile(TRANSPORT_NOISE_TCP, bindHost, port, options, options.seed);
}

export function listenKeyed(
	bindHost: string,
	port: number,
	options: KeyedListenOptions = {},
): Promise<Server> {
	return listenProfile(TRANSPORT_KEYED_TCP, bindHost, port, options, options.seed);
}
