// Native relay provider composition for the generic driver loop.
//
// One configured archive runtime installs one provider package advertising both
// keyed-relay and noise-relay. Multiplexed execution, readiness, Host sealing, and
// lifetime remain in the native archive and generic driver.

import {
	abiLayout,
	abortable,
	Connector,
	ffi,
	GlowcapError,
	NativeDiagnostic,
	openWebSocketChannel,
	outPointer,
	readErrorSlot,
	RELAY_CONFIG_ABI_VERSION,
	RELAY_CONFIG_ABI_VERSION_OFF,
	RELAY_CONFIG_REGISTER_URL_LEN_OFF,
	RELAY_CONFIG_REGISTER_URL_OFF,
	RELAY_CONFIG_RELAY_URL_LEN_OFF,
	RELAY_CONFIG_RELAY_URL_OFF,
	RELAY_CONFIG_SIZE,
	RELAY_CONFIG_STRUCT_SIZE_OFF,
	RELAY_CONFIG_TRUST_OFF,
	RELAY_CONFIG_TRUST_PEM_LEN_OFF,
	RELAY_CONFIG_TRUST_PEM_OFF,
	RELAY_TRUST_COPIED_PEM,
	RELAY_TRUST_SYSTEM,
	requireOffThreadFfi,
	retainCleanupFailures,
	Session,
	TRANSPORT_PROVIDER_SIZE,
} from "@glowcap/runtime/transport";
import type { DriverProvider, ProviderTarget, Ptr } from "@glowcap/runtime/transport";
import { relayS } from "./ffi.ts";
import { INVALID_ARGUMENT, TRANSPORT_KEYED_RELAY, TRANSPORT_NOISE_RELAY } from "@glowcap/abi";
import { dialUrl, routeFromLocator } from "./route.ts";

const OK = 0;
const encoder = new TextEncoder();

export interface RelayOptions {
	/** WebSocket URL used for outbound relay legs. */
	readonly relayUrl: string;
	/** Registration URL used by listeners; omit for a dial-only provider. */
	readonly registerUrl?: string;
	/** Immutable trust snapshot used by native WSS opens. */
	readonly trust?: NativeTrust;
}

export type NativeTrust =
	| { readonly kind: "system" }
	| { readonly kind: "copied-pem"; readonly pem: Uint8Array };

function relayLastError(): string | null {
	return readErrorSlot(relayS.glowcap_relay_last_error);
}

function checkRelay(code: number): void {
	if (code !== OK) {
		throw new GlowcapError(
			code,
			relayLastError() ?? `relay transport call failed (code ${code})`,
		);
	}
}

function encodeConfig(options: RelayOptions): { struct: Uint8Array; keepAlive: Uint8Array[] } {
	const relay = encoder.encode(options.relayUrl);
	const register = encoder.encode(options.registerUrl ?? "");
	const trust = options.trust ?? { kind: "system" };
	const pem = trust.kind === "copied-pem" ? trust.pem : new Uint8Array(0);
	const struct = new Uint8Array(RELAY_CONFIG_SIZE);
	const dv = new DataView(struct.buffer);
	const put = (pointerOffset: number, lengthOffset: number, bytes: Uint8Array): void => {
		abiLayout.setPtr(dv, pointerOffset, bytes.length === 0 ? 0n : ffi.pointerOf(bytes));
		abiLayout.setUsize(dv, lengthOffset, bytes.length);
	};
	dv.setUint32(RELAY_CONFIG_ABI_VERSION_OFF, RELAY_CONFIG_ABI_VERSION, true);
	abiLayout.setUsize(dv, RELAY_CONFIG_STRUCT_SIZE_OFF, struct.byteLength);
	put(RELAY_CONFIG_RELAY_URL_OFF, RELAY_CONFIG_RELAY_URL_LEN_OFF, relay);
	put(RELAY_CONFIG_REGISTER_URL_OFF, RELAY_CONFIG_REGISTER_URL_LEN_OFF, register);
	dv.setUint32(
		RELAY_CONFIG_TRUST_OFF,
		trust.kind === "system" ? RELAY_TRUST_SYSTEM : RELAY_TRUST_COPIED_PEM,
		true,
	);
	put(RELAY_CONFIG_TRUST_PEM_OFF, RELAY_CONFIG_TRUST_PEM_LEN_OFF, pem);
	return { struct, keepAlive: [relay, register, pem] };
}

function openRuntime(options: RelayOptions): Ptr {
	requireOffThreadFfi("relay", "native provider lifecycle");
	const { struct, keepAlive } = encodeConfig(options);
	const out = new Uint8Array(abiLayout.ptrSize);
	checkRelay(relayS.glowcap_relay_runtime_new(struct, out));
	void keepAlive;
	return outPointer(out);
}

/** Install one shared keyed-relay/noise-relay package into a native loop. */
export async function installProvider(
	loop: ProviderTarget,
	options: RelayOptions,
): Promise<void> {
	const raw = openRuntime(options);
	try {
		const packageBytes = new Uint8Array(TRANSPORT_PROVIDER_SIZE);
		checkRelay(relayS.glowcap_relay_transport_provider(raw, packageBytes));
		loop.installProvider((register) => register(packageBytes));
	} catch (primary) {
		throw await retainCleanupFailures(primary, [
			() =>
				new NativeDiagnostic("relay").check(
					"runtime release after refused installation",
					(error, cap, errorLen) => relayS.glowcap_relay_runtime_release(raw, error, cap, errorLen),
				),
		]);
	}
	// Registration retained the runtime; this drops only the constructor lease.
	await new NativeDiagnostic("relay").check(
		"runtime release",
		(error, cap, errorLen) => relayS.glowcap_relay_runtime_release(raw, error, cap, errorLen),
	);
}

/** Configure this archive's keyed-relay/noise-relay package for `connect`. */
export function provider(
	options: RelayOptions,
): DriverProvider {
	return {
		async install(loop) {
			await installProvider(loop, options);
		},
	};
}

/** Configure the managed WebSocket connector. The byte-fed Host applies the
 * Noise channel for `noise-relay`; the connector remains byte plumbing. */
export function connector(): Connector {
	return new Connector([TRANSPORT_KEYED_RELAY, TRANSPORT_NOISE_RELAY], async (host, locator, request) => {
		const route = routeFromLocator(locator);
		if (route == null) {
			throw new GlowcapError(
				INVALID_ARGUMENT,
				`${locator.transport} connector requires a rendezvous-relay hint; got designator=${
					locator.designator.slice(0, 16)
				}… hints=[${[...locator.hints.keys()].join(",")}] wireForm=${locator.hintWireForm}`,
			);
		}
		const channel = await openWebSocketChannel(
			dialUrl(route, locator.designator),
			undefined,
			request.signal,
		);
		const cancel = (): void => {
			// The enclosing refused connect awaits this exact idempotent barrier and
			// attaches its failure to that primary. This guard only prevents the DOM
			// event callback from creating an unhandled rejection first.
			void channel.close().catch(() => {});
		};
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
				(error) => host.recordCallerlessBindingFailure("relay.session.cancel.cleanup", error),
				(session) => session.closeTransport(),
			);
		} catch (error) {
			throw await retainCleanupFailures(error, [() => channel.close()]);
		} finally {
			request.signal?.removeEventListener("abort", cancel);
		}
	});
}
