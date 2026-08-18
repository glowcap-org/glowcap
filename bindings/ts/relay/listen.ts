// Native registered accepts for the relay profiles. The driver owns the
// registration socket, admission, handshake, events, and terminal release;
// this module installs the relay provider with its two routes and projects
// the listener into the TypeScript API, the same shape `@pancake/tcp`'s
// listen has.
//
// The provider hosts one registration route per loop (the deployed
// rendezvous protocol queues inbound legs by durable designator without a
// channel-profile discriminator), so a second listen on a loop must ride the
// routes the first one installed and is refused when it names different
// ones.

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
import { INVALID_ARGUMENT, IO } from "@pancake/abi";
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

/** The routes each loop's installed relay provider serves, so a second
 * listen can ride them and one naming different routes refuses instead of
 * routing nondeterministically. */
const installedRoutes = new WeakMap<object, { relayUrl: string; registerUrl: string }>();

async function ensureRelayProvider(loop: DriverLoop, options: RelayListenOptions): Promise<void> {
	const relayUrl = relayRoute(options.relayUrl);
	const registerUrl = options.registerUrl;
	const installed = installedRoutes.get(loop);
	if (installed !== undefined) {
		if (installed.relayUrl !== relayUrl || installed.registerUrl !== registerUrl) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"this loop's relay provider already serves different routes; relay listeners share one relay per loop",
			);
		}
		return;
	}
	await installProvider(loop, { relayUrl, registerUrl, trust: options.trust });
	installedRoutes.set(loop, { relayUrl, registerUrl });
}

async function listenProfile(
	transport: string,
	options: RelayListenOptions,
): Promise<DriverServer> {
	await ensureRuntimeReady();
	if (!loopTierAvailable()) throw listenerLoopUnavailable();
	let prepared: { loop: DriverLoop; ownsLoop: boolean } | null = null;
	try {
		prepared = prepareListenerLoop(options.host, options.seed, options.codec);
		const loop = prepared.loop;
		await ensureRelayProvider(loop, options);
		// The provider registers as the listener opens, so a completed open is
		// the commit point: the relay answered and holds this peer's sockets.
		const listener = await DriverListener.open(loop, transport, "", options.signal);
		listener.select();
		return new DriverServer({
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

/** Register the identity-addressed cleartext relay profile. */
export function listenKeyed(options: RelayListenOptions): Promise<DriverServer> {
	return listenProfile(TRANSPORT_KEYED_RELAY, options);
}

/** Register the Noise_XK-sealed relay profile. */
export function listenNoise(options: RelayListenOptions): Promise<DriverServer> {
	return listenProfile(TRANSPORT_NOISE_RELAY, options);
}
