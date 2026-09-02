import { ffi } from "../internal/ffi/runtime.ts";
import { L } from "../internal/layout.ts";
import { GlowcapError } from "../errors.ts";
import {
	DRIVER_DEFAULT_HANDSHAKE_MS,
	DRIVER_DEFAULT_LISTENER_SETUP_MS,
	DRIVER_DEFAULT_MAX_PENDING_OPENS,
	DRIVER_DEFAULT_SETTLE_MS,
	DRIVER_DEFAULT_WIRE_BUFFER_BYTES,
	DRIVER_OPTIONS_ABI_VERSION,
	INVALID_ARGUMENT,
} from "@glowcap/abi";

export interface DriverLoopOptions {
	wireBufferBytes?: number;
	maxPendingOpens?: number;
	handshakeMs?: number;
	listenerSetupMs?: number;
	settleMs?: number;
}

export function encodeDriverOptions(opts: DriverLoopOptions): Uint8Array {
	const wireBufferBytes = opts.wireBufferBytes ?? DRIVER_DEFAULT_WIRE_BUFFER_BYTES;
	const maxPendingOpens = opts.maxPendingOpens ?? DRIVER_DEFAULT_MAX_PENDING_OPENS;
	const handshakeMs = opts.handshakeMs ?? DRIVER_DEFAULT_HANDSHAKE_MS;
	const listenerSetupMs = opts.listenerSetupMs ?? DRIVER_DEFAULT_LISTENER_SETUP_MS;
	const settleMs = opts.settleMs ?? DRIVER_DEFAULT_SETTLE_MS;
	const maxUsize = L.ptrSize === 4 ? 0xffff_ffff : Number.MAX_SAFE_INTEGER;
	const maxU32 = 0xffff_ffff;
	for (
		const [name, value, maximum] of [
			["wireBufferBytes", wireBufferBytes, maxUsize],
			["maxPendingOpens", maxPendingOpens, maxUsize],
			["handshakeMs", handshakeMs, maxU32],
			["listenerSetupMs", listenerSetupMs, maxU32],
			["settleMs", settleMs, maxU32],
		] as const
	) {
		if (!Number.isSafeInteger(value) || value < 0 || value > maximum) {
			throw new GlowcapError(
				INVALID_ARGUMENT,
				`${name} must be an unsigned integer representable by the C field`,
			);
		}
	}
	const bytes = new Uint8Array(L.DRIVER_OPTIONS_SIZE);
	const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
	view.setUint32(L.DRIVER_OPTIONS_ABI_VERSION_OFF, DRIVER_OPTIONS_ABI_VERSION, true);
	L.setUsize(view, L.DRIVER_OPTIONS_STRUCT_SIZE_OFF, L.DRIVER_OPTIONS_SIZE);
	L.setUsize(view, L.DRIVER_OPTIONS_WIRE_BUFFER_BYTES_OFF, wireBufferBytes);
	L.setUsize(view, L.DRIVER_OPTIONS_MAX_PENDING_OPENS_OFF, maxPendingOpens);
	view.setUint32(L.DRIVER_OPTIONS_HANDSHAKE_MS_OFF, handshakeMs, true);
	view.setUint32(L.DRIVER_OPTIONS_LISTENER_SETUP_MS_OFF, listenerSetupMs, true);
	view.setUint32(L.DRIVER_OPTIONS_SETTLE_MS_OFF, settleMs, true);
	return bytes;
}

export function encodeTransportOperationOptions(data?: Uint8Array): Uint8Array | null {
	if (data == null) return null;
	const raw = new Uint8Array(L.TRANSPORT_OPERATION_OPTIONS_SIZE);
	const view = new DataView(raw.buffer);
	L.setPtr(view, L.TRANSPORT_OPERATION_OPTIONS_DATA_OFF, ffi.pointerOf(data));
	L.setUsize(view, L.TRANSPORT_OPERATION_OPTIONS_SIZE_OFF, data.length);
	return raw;
}
