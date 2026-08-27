// Generic-driver composition for the raw onion archive owners in native.ts.

import {
	DriverListener,
	DriverLoop,
	DriverServer,
	Host,
	NativeDiagnostic,
	retainCleanupFailures,
	TRANSPORT_PROVIDER_SIZE,
} from "@pancake/runtime/transport";
import type { DriverProvider, ProviderTarget } from "@pancake/runtime/transport";
import { TRANSPORT_ONION } from "@pancake/abi";
import { onionS } from "./ffi.ts";
import { checkOnion, type NetlayerOptions, openNetlayer } from "./native.ts";

/** Install one configured onion package into a native driver.
 *
 * Registration retains the package before this function releases only the
 * constructor's reference. It deliberately does not call netlayer shutdown:
 * the driver lease keeps the callback runtime live until driver teardown. */
export async function installProvider(loop: ProviderTarget, options: NetlayerOptions): Promise<void> {
	const raw = openNetlayer(options);
	try {
		const packageBytes = new Uint8Array(TRANSPORT_PROVIDER_SIZE);
		checkOnion(onionS.pancake_onion_transport_provider(raw, packageBytes));
		loop.installProvider((register) => register(packageBytes));
	} finally {
		await new NativeDiagnostic("onion").check(
			"netlayer release",
			(error, cap, errorLen) => onionS.pancake_onion_netlayer_release(raw, error, cap, errorLen),
		);
	}
}

/** Configure one native onion provider package for generic `connect`. */
export function provider(options: NetlayerOptions): DriverProvider {
	return {
		install(loop) {
			return installProvider(loop, options);
		},
	};
}

/** A driver-owned onion service. The generic listener owns admission and CapTP
 * sessions; only this transport package interprets its restoration bytes as a
 * Tor service key. */
export class OnionServer extends DriverServer {
	readonly #serviceKey: Uint8Array;

	constructor(listener: DriverListener, serviceKey: Uint8Array, ownedLoop?: DriverLoop) {
		super({ listener, ownedLoop });
		this.#serviceKey = serviceKey.slice();
	}

	get serviceKey(): Uint8Array {
		return this.#serviceKey.slice();
	}
}

/** Host CapTP on a Tor onion service through the generic native driver.
 * Tor's control exchange and constructor-release barrier complete before this returns. */
export async function listen(options: NetlayerOptions, host?: Host): Promise<OnionServer> {
	const existingLoop = host?.driverLoop;
	const loop = existingLoop == null
		? host == null ? DriverLoop.open() : DriverLoop.takeHost(host)
		: existingLoop as DriverLoop;
	let listener: DriverListener | null = null;
	try {
		await installProvider(loop, options);
		listener = await DriverListener.open(loop, TRANSPORT_ONION, "", options.signal);
		listener.select();
		const serviceKey = listener.restorationState();
		const server = new OnionServer(listener, serviceKey, host == null ? loop : undefined);
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
