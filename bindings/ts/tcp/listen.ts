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
	HINT_DIRECT_ADDRESSES,
	Host,
	loopTierAvailable,
	PancakeError,
	retainCleanupFailures,
	stringHint,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_TCP,
	TRANSPORT_TCP,
} from "@pancake/runtime/transport";
import type { Codec } from "@pancake/runtime/transport";
import { addressDesignator } from "./address.ts";
import { type Config, installProvider as installTcpProvider } from "./transport.ts";
import { INVALID_ARGUMENT, IO } from "@pancake/abi";

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

function loopUnavailable(): PancakeError {
	return new PancakeError(
		INVALID_ARGUMENT,
		"native driver listeners require a runtime that can park the loop",
	);
}

function prepareLoop(
	host: Host | undefined,
	seed: Uint8Array | undefined,
	codec: Codec | undefined,
): { loop: DriverLoop; ownsLoop: boolean } {
	if (host != null) {
		if (codec != null && codec !== host.codec) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				`codec "${codec}" conflicts with the host's "${host.codec}"; mint the host with it instead`,
			);
		}
		if (seed != null) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"seed and host are alternative identity sources",
			);
		}
		return {
			loop: host.driverLoop != null ? host.driverLoop as DriverLoop : DriverLoop.takeHost(host),
			ownsLoop: false,
		};
	}
	return { loop: DriverLoop.open({ seed, codec }), ownsLoop: true };
}

/** A native-driver listener. Its Host is the driver's Host wrapper, which is
 * either minted by the loop or the exact supplied wrapper transferred through
 * `pancake_driver_take_host`. */
export class Server extends DriverServer {
	get port(): number {
		const locator = this.locator;
		const address = stringHint(locator, HINT_DIRECT_ADDRESSES) ?? locator.designator;
		return designatorHostPort(address).port;
	}
}

async function bindTcpProfileListener(
	loop: DriverLoop,
	transport: string,
	bindHost: string,
	port: number,
	options: ListenOptions,
): Promise<DriverListener> {
	installTcpProvider(loop, options.config);
	let listener: DriverListener | null = null;
	try {
		listener = await DriverListener.open(
			loop,
			transport,
			addressDesignator(bindHost, port),
			options.signal,
		);
		const locator = listener.locator();
		const boundDirect = stringHint(locator, HINT_DIRECT_ADDRESSES) ??
			(transport === TRANSPORT_TCP ? locator.designator : null);
		if (boundDirect == null) {
			throw new PancakeError(
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
		return listener;
	} catch (error) {
		listener?.close();
		throw error;
	}
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
		throw new PancakeError(
			INVALID_ARGUMENT,
			"a wildcard bind has no dialable address; provide advertisedHost",
		);
	}
	if (advertisedHost != null && wildcardHost(advertisedHost)) {
		throw new PancakeError(INVALID_ARGUMENT, "an advertised host must be dialable");
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
		throw new PancakeError(INVALID_ARGUMENT, `${transport} listen: seed must be 32 bytes`);
	}
	await ensureRuntimeReady();
	if (!loopTierAvailable()) throw loopUnavailable();
	let prepared: { loop: DriverLoop; ownsLoop: boolean } | null = null;
	try {
		prepared = prepareLoop(options.host, seed, options.codec);
		const loop = prepared.loop;
		const listener = await bindTcpProfileListener(loop, transport, bindHost, port, options);
		return new Server({
			listener,
			ownedLoop: prepared.ownsLoop ? loop : undefined,
		});
	} catch (error) {
		const primary = error instanceof PancakeError ? error : new PancakeError(IO, String(error));
		const ownedLoop = prepared?.ownsLoop ? prepared.loop : null;
		await retainCleanupFailures(
			primary,
			ownedLoop == null ? [] : [() => ownedLoop.close()],
		);
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
