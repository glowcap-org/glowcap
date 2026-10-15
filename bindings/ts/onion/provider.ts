// Generic-driver composition for the raw onion archive owners in ffi_archive.ts.

import {
	DriverListener,
	DriverLoop,
	DriverServer,
	FfiDiagnostic,
	Host,
	retainCleanupFailures,
	TRANSPORT_PROVIDER_SIZE,
} from "@glowcap/runtime/transport";
import type { DriverProvider, ProviderTarget } from "@glowcap/runtime/transport";
import { TRANSPORT_ONION } from "@glowcap/abi";
import { onionS } from "./ffi.ts";
import { checkOnion, type NetlayerOptions, openNetlayer } from "./ffi_archive.ts";

/** Install one configured onion package into a driver.
 *
 * Registration retains the package before this function releases only the
 * constructor's reference. It does not call netlayer shutdown:
 * the driver lease keeps the callback runtime live until driver teardown. */
export async function installProvider(loop: ProviderTarget, options: NetlayerOptions): Promise<void> {
	const raw = openNetlayer(options);
	try {
		const packageBytes = new Uint8Array(TRANSPORT_PROVIDER_SIZE);
		checkOnion(onionS.glowcap_onion_transport_provider(raw, packageBytes));
		loop.installProvider((register) => register(packageBytes));
	} finally {
		await new FfiDiagnostic("onion").check(
			"netlayer release",
			(error, cap, errorLen) => onionS.glowcap_onion_netlayer_release(raw, error, cap, errorLen),
		);
	}
}

/** Configure one FFI onion provider package for generic `connect`. */
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

/** Host CapTP on a Tor onion service through the generic driver.
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
