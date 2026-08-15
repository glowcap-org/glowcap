// Native relay provider composition for the generic driver loop.
//
// One configured archive runtime installs one provider package advertising both
// keyed-relay and noise-relay. Multiplexed execution, readiness, Host sealing, and
// lifetime remain in the native archive and generic driver.

import {
	abortable,
	Connector,
	ffi,
	NativeDiagnostic,
	openWebSocketChannel,
	outPointer,
	PancakeError,
	readErrorSlot,
	requireOffThreadFfi,
	Session,
	TRANSPORT_PROVIDER_SIZE,
} from "@pancake/runtime/transport";
import type { DriverProvider, Locator, ProviderTarget, Ptr } from "@pancake/runtime/transport";
import { relayS } from "./ffi.ts";
import { INVALID_ARGUMENT, TRANSPORT_KEYED_RELAY, TRANSPORT_NOISE_RELAY } from "@pancake/abi";

const OK = 0;
const RENDEZVOUS_RELAY_HINT = "rendezvous-relay";
const encoder = new TextEncoder();

function profileLocator(transport: string, designator: string, relayUrl: string): Locator {
	return {
		transport,
		designator,
		hints: new Map([[RENDEZVOUS_RELAY_HINT, relayUrl]]),
		hintWireForm: "map",
	};
}

/** The identity-addressed cleartext relay profile. */
export const keyed = {
	locator(designator: string, relayUrl: string): Locator {
		return profileLocator(TRANSPORT_KEYED_RELAY, designator, relayUrl);
	},
};

/** The Noise_XK-sealed relay profile. */
export const noise = {
	locator(designator: string, relayUrl: string): Locator {
		return profileLocator(TRANSPORT_NOISE_RELAY, designator, relayUrl);
	},
};

export function routeFromLocator(locator: Locator): string | null {
	const value = locator.hints.get(RENDEZVOUS_RELAY_HINT);
	if (value == null) return null;
	if (typeof value !== "string" || value.length === 0) {
		throw new PancakeError(
			INVALID_ARGUMENT,
			"rendezvous-relay must be a non-empty string hint",
		);
	}
	return value;
}

export function dialUrl(route: string, designator: string): string {
	const url = new URL(route);
	url.searchParams.append("rendezvous", designator);
	return url.toString();
}

export interface RelayOptions {
	/** WebSocket URL used for outbound relay legs. */
	readonly relayUrl: string;
	/** Registration URL used by listeners; omit for a dial-only provider. */
	readonly registerUrl?: string;
}

function relayLastError(): string | null {
	return readErrorSlot(relayS.pancake_relay_last_error);
}

function checkRelay(code: number): void {
	if (code !== OK) {
		throw new PancakeError(
			code,
			relayLastError() ?? `relay transport call failed (code ${code})`,
		);
	}
}

function encodeConfig(options: RelayOptions): { struct: Uint8Array; keepAlive: Uint8Array[] } {
	const relay = encoder.encode(options.relayUrl);
	const register = encoder.encode(options.registerUrl ?? "");
	const struct = new Uint8Array(32);
	const dv = new DataView(struct.buffer);
	const put = (offset: number, bytes: Uint8Array): void => {
		dv.setBigUint64(offset, bytes.length === 0 ? 0n : ffi.pointerOf(bytes), true);
		dv.setBigUint64(offset + 8, BigInt(bytes.length), true);
	};
	put(0, relay);
	put(16, register);
	return { struct, keepAlive: [relay, register] };
}

function openRuntime(options: RelayOptions): Ptr {
	requireOffThreadFfi("relay", "native provider lifecycle");
	const { struct, keepAlive } = encodeConfig(options);
	const out = new Uint8Array(8);
	checkRelay(relayS.pancake_relay_runtime_new(struct, out));
	void keepAlive;
	return outPointer(out);
}

/** Install one shared keyed-relay/noise-relay package into a native loop. */
export async function installProvider(loop: ProviderTarget, options: RelayOptions): Promise<void> {
	const raw = openRuntime(options);
	try {
		const packageBytes = new Uint8Array(TRANSPORT_PROVIDER_SIZE);
		checkRelay(relayS.pancake_relay_transport_provider(raw, packageBytes));
		loop.installProvider((register) => register(packageBytes));
	} finally {
		// Registration retains the runtime; this drops only the constructor lease.
		await new NativeDiagnostic("relay").check(
			"runtime release",
			(error, cap, errorLen) => relayS.pancake_relay_runtime_release_with_diagnostic(raw, error, cap, errorLen),
		);
	}
}

/** Configure this archive's keyed-relay/noise-relay package for `connect`. */
export function provider(
	options: RelayOptions,
): DriverProvider {
	return {
		install(loop) {
			return installProvider(loop, options);
		},
	};
}

/** Configure the explicit cleartext keyed-relay byte connector. Noise relay
 * requires the native provider because sealing is owned below the Host. */
export function connector(): Connector {
	return new Connector([TRANSPORT_KEYED_RELAY], async (host, locator, request) => {
		const route = routeFromLocator(locator);
		if (route == null) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				`keyed-relay connector requires a rendezvous-relay hint; got transport=${locator.transport} designator=${
					locator.designator.slice(0, 16)
				}… hints=[${[...locator.hints.keys()].join(",")}] wireForm=${locator.hintWireForm}`,
			);
		}
		const channel = await abortable(
			openWebSocketChannel(dialUrl(route, locator.designator)),
			request.signal,
			(late) => late.close(),
		);
		const cancel = (): void => channel.close();
		request.signal?.addEventListener("abort", cancel, { once: true });
		try {
			return await abortable(
				Session.establishDialedLocator(
					host,
					locator,
					channel,
					request.handshakeTimeoutMs,
				),
				request.signal,
				(session) => session.closeTransport(),
			);
		} catch (error) {
			channel.close();
			throw error;
		} finally {
			request.signal?.removeEventListener("abort", cancel);
		}
	});
}
