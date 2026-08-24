// Native registered accepts for the relay profiles. The driver owns the
// registration socket, admission, handshake, events, and terminal release;
// this module installs the relay provider with its two routes and projects
// the listener into the TypeScript API, the same shape `@pancake/tcp`'s
// listen has.
//
// The provider hosts one registration route per loop (the deployed
// rendezvous protocol queues inbound legs by durable designator without a
// channel-profile discriminator). Native installation is the configuration
// authority: repeated installation accepts only the same complete route and
// trust snapshot.

import {
	DriverListener,
	DriverServer,
	ensureRuntimeReady,
	type Host,
	listenerLoopUnavailable,
	loopTierAvailable,
	PancakeError,
	prepareListenerLoop,
	retainCleanupFailures,
	TRANSPORT_KEYED_RELAY,
	TRANSPORT_NOISE_RELAY,
} from "@pancake/runtime/transport";
import type { Codec, DriverLoop } from "@pancake/runtime/transport";
import { IO } from "@pancake/abi";
import { installProvider, type NativeTrust } from "./transport.ts";
import { relayRoute } from "./route.ts";

export interface RelayListenOptions {
	/** WebSocket URL peers dial through, carried in the announced locator. */
	readonly relayUrl: string;
	/** Registration endpoint this listener holds inbound sockets at. */
	readonly registerUrl: string;
	/** Immutable trust snapshot used by native WSS opens. */
	readonly trust?: NativeTrust;
	/** Cancel listener construction before the driver reports readiness. */
	readonly signal?: AbortSignal;
	/** Reuse this Host's identity, publications, and handoff router. */
	readonly host?: Host;
	/** Reuse this 32-byte identity seed across restarts. */
	readonly seed?: Uint8Array;
	/** Wire codec for a newly minted Host. */
	readonly codec?: Codec;
}

async function ensureRelayProvider(loop: DriverLoop, options: RelayListenOptions): Promise<void> {
	const relayUrl = relayRoute(options.relayUrl);
	await installProvider(loop, {
		relayUrl,
		registerUrl: options.registerUrl,
		trust: options.trust,
	});
}

async function listenProfile(
	transport: string,
	options: RelayListenOptions,
): Promise<DriverServer> {
	await ensureRuntimeReady();
	if (!loopTierAvailable()) throw listenerLoopUnavailable();
	let prepared: { loop: DriverLoop; ownsLoop: boolean } | null = null;
	let listener: DriverListener | null = null;
	try {
		prepared = prepareListenerLoop(options.host, options.seed, options.codec);
		const loop = prepared.loop;
		await ensureRelayProvider(loop, options);
		// The provider registers as the listener opens, so a completed open is
		// the commit point: the relay answered and holds this peer's sockets.
		listener = await DriverListener.open(loop, transport, "", options.signal);
		listener.select();
		const server = new DriverServer({
			listener,
			ownedLoop: prepared.ownsLoop ? loop : undefined,
		});
		listener = null;
		return server;
	} catch (error) {
		const primary = error instanceof PancakeError ? error : new PancakeError(IO, String(error));
		const failedListener = listener;
		const ownedLoop = prepared?.ownsLoop ? prepared.loop : null;
		const cleanups: Array<() => void | Promise<void>> = [];
		if (failedListener != null) cleanups.push(() => failedListener.close());
		if (ownedLoop != null) cleanups.push(() => ownedLoop.close());
		await retainCleanupFailures(primary, cleanups);
		throw primary;
	}
}

/** Register the identity-addressed cleartext relay profile. */
export function listenKeyed(options: RelayListenOptions): Promise<DriverServer> {
	return listenProfile(TRANSPORT_KEYED_RELAY, options);
}

/** Register the Noise_XK-sealed relay profile. */
export function listenNoise(options: RelayListenOptions): Promise<DriverServer> {
	return listenProfile(TRANSPORT_NOISE_RELAY, options);
}
