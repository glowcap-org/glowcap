import {
	DRIVER_EVENT_ACCEPTED,
	DRIVER_EVENT_COMPLETION,
	DRIVER_EVENT_LISTENER_FAILED,
	DRIVER_EVENT_LISTENER_READY,
	DRIVER_EVENT_OPEN_FAILED,
	DRIVER_EVENT_OPENED,
	DRIVER_EVENT_SESSION_CLOSED,
	INTERNAL,
} from "@pancake/abi";
import { decodeCarrierFailure } from "../carrier_failure.ts";
import { PancakeError } from "../errors.ts";
import { decodeHostAction, type HostAction } from "./host_action.ts";
import type { DriverFailure } from "./driver_failure.ts";
import type { Ptr } from "./ffi/runtime.ts";
import { L } from "./layout.ts";
import { readBytes } from "./seam.ts";

const utf8 = new TextDecoder("utf-8", { fatal: true });

export type LoopEvent =
	| { kind: "opened"; operationId: bigint; session: Ptr }
	| ({ kind: "openFailed"; operationId: bigint } & DriverFailure)
	| { kind: "listenerReady"; listener: bigint }
	| ({ kind: "listenerFailed"; listener: bigint } & DriverFailure)
	| { kind: "accepted"; listener: bigint; session: Ptr }
	| ({ kind: "sessionClosed"; session: Ptr } & DriverFailure)
	| { kind: "completion"; action: HostAction };

export function decodeDriverEvent(buf: Uint8Array<ArrayBuffer>): LoopEvent {
	const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
	const kind = dv.getUint32(L.DRIVER_EVENT_KIND_OFF, true);
	const failure: DriverFailure = {
		primaryResult: dv.getInt32(L.DRIVER_EVENT_PRIMARY_RESULT_OFF, true),
		primaryName: text(dv, L.DRIVER_EVENT_PRIMARY_NAME_OFF, L.DRIVER_EVENT_PRIMARY_NAME_LEN_OFF),
		secondaryResult: dv.getInt32(L.DRIVER_EVENT_SECONDARY_RESULT_OFF, true),
		secondaryCount: dv.getUint32(L.DRIVER_EVENT_SECONDARY_COUNT_OFF, true),
		secondaryName: text(dv, L.DRIVER_EVENT_SECONDARY_NAME_OFF, L.DRIVER_EVENT_SECONDARY_NAME_LEN_OFF),
		carrierFailure: decodeCarrierFailure(
			dv.getUint32(L.DRIVER_EVENT_CARRIER_PHASE_OFF, true),
			dv.getUint32(L.DRIVER_EVENT_CARRIER_DETAIL_FLAGS_OFF, true),
			dv.getUint32(L.DRIVER_EVENT_CARRIER_VERIFICATION_FLAGS_OFF, true),
			dv.getUint32(L.DRIVER_EVENT_CARRIER_PEER_ALERT_OFF, true),
			dv.getInt32(L.DRIVER_EVENT_CARRIER_ENGINE_CODE_OFF, true),
		),
	};
	const operationId = dv.getBigUint64(L.DRIVER_EVENT_OPERATION_ID_OFF, true);
	const listenerId = dv.getBigUint64(L.DRIVER_EVENT_LISTENER_ID_OFF, true);
	const session = L.getPtr(dv, L.DRIVER_EVENT_SESSION_OFF);
	switch (kind) {
		case DRIVER_EVENT_OPENED:
			return { kind: "opened", operationId, session };
		case DRIVER_EVENT_OPEN_FAILED:
			return { kind: "openFailed", operationId, ...failure };
		case DRIVER_EVENT_LISTENER_READY:
			return { kind: "listenerReady", listener: listenerId };
		case DRIVER_EVENT_LISTENER_FAILED:
			return { kind: "listenerFailed", listener: listenerId, ...failure };
		case DRIVER_EVENT_ACCEPTED:
			return { kind: "accepted", listener: listenerId, session };
		case DRIVER_EVENT_SESSION_CLOSED:
			return { kind: "sessionClosed", session, ...failure };
		case DRIVER_EVENT_COMPLETION:
			try {
				return {
					kind: "completion",
					action: decodeHostAction(new DataView(buf.buffer, L.DRIVER_EVENT_ACTION_OFF)),
				};
			} catch (error) {
				throw new PancakeError(INTERNAL, `pancake ABI returned an invalid completion action: ${String(error)}`);
			}
		default:
			throw new PancakeError(INTERNAL, `pancake ABI returned unknown loop event kind ${kind}`);
	}
}

function text(dv: DataView, pointerOffset: number, lengthOffset: number): string {
	const len = L.getUsize(dv, lengthOffset);
	const pointer = L.getPtr(dv, pointerOffset);
	if (len === 0n) return "";
	if (pointer === 0n) throw new PancakeError(INTERNAL, "driver returned null failure name with nonzero length");
	try {
		return utf8.decode(readBytes(pointer, len));
	} catch {
		throw new PancakeError(INTERNAL, "driver returned non-UTF-8 failure name");
	}
}
