// Native relay provider composition for the generic driver loop.
//
// One configured archive runtime installs one provider package advertising both
// keyed-relay and noise-relay. Multiplexed execution, readiness, Host sealing, and
// lifetime remain in the native archive and generic driver.

import { type Locator, TRANSPORT_KEYED_RELAY } from "../locator.ts";
import { TRANSPORT_PROVIDER_SIZE } from "../internal/constants.ts";
import { relayS } from "../internal/ffi/relay.ts";
import { ffi, type Ptr } from "../internal/ffi/runtime.ts";
import { outPointer, readErrorSlot } from "../internal/seam.ts";
import { type ProviderTarget } from "../driver_loop.ts";
import { PancakeError } from "../errors.ts";
import { INVALID_ARGUMENT } from "@pancake/abi";
import { requireOffThreadFfi } from "./native_handle.ts";

const OK = 0;
const RENDEZVOUS_RELAY_HINT = "rendezvous-relay";
const encoder = new TextEncoder();

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
export function installProvider(loop: ProviderTarget, options: RelayOptions): void {
	if (loop.hasTransport(TRANSPORT_KEYED_RELAY)) return;
	const raw = openRuntime(options);
	try {
		const packageBytes = new Uint8Array(TRANSPORT_PROVIDER_SIZE);
		checkRelay(relayS.pancake_relay_transport_provider(raw, packageBytes));
		loop.installProvider((register) => register(packageBytes));
	} finally {
		// Registration retains the runtime; this drops only the constructor lease.
		relayS.pancake_relay_runtime_release(raw);
	}
}
