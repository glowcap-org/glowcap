// Host-action park + execute — the embedder-contract switch the CapTP host
// drain runs. `Host` owns park/kick/vows and the Session registry; decode/types
// come from the generated `internal/host_action.ts`
// (`zig build gen-binding-host-action`); this module owns the shared C drain
// (`pancake_host_pump_drain`) with sync park-only hooks, then runs each parked
// arm (dial, flush, close, gift-id entropy, settle, fail) after the C loop
// returns — so async I/O never runs inside the C callback.

import { driverS } from "./internal/ffi/driver.ts";
import { ffi, NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { ab } from "./internal/seam.ts";
import {
	CLOSED,
	HOST_ACTION_CLOSE,
	HOST_ACTION_DIAL,
	HOST_ACTION_FAIL,
	HOST_ACTION_FLUSH,
	HOST_ACTION_NEED_GIFT_ID,
	HOST_ACTION_SETTLE,
	HOST_ACTION_SIZE,
	OK,
} from "./internal/abi.ts";
import { decodeHostAction, type HostAction } from "./internal/host_action.ts";
import { checkHost, PancakeError, VowBroken } from "./errors.ts";
import { type Argument } from "./value.ts";
import type { Session } from "./session.ts";

export type { HostAction };

const utf8Encoder = new TextEncoder();

// PancakeHostPumpHooks (pancake_driver.h) — hand-mirrored LP64 layout, pinned
// against the header's documented 48-byte size the way Python's ctypes mirror
// is. gen-ts-abi does not emit this layout today.
const HOST_PUMP_HOOKS_SIZE = 48;
const HOST_PUMP_HOOKS_FLUSH_OFF = 8;
const HOST_PUMP_HOOKS_CLOSE_OFF = 16;
const HOST_PUMP_HOOKS_NEED_GIFT_ID_OFF = 24;
const HOST_PUMP_HOOKS_COMPLETE_OFF = 32;
const HOST_PUMP_HOOKS_DIAL_OFF = 40;

/** Live host state the action drain needs. `Host` satisfies this structurally
 * via its binding-internal methods so `parkActions` / `runAction` never reach
 * into private class fields. */
export interface ActionHost {
	readonly raw: Ptr;
	getSession(ptr: Ptr): Session | undefined;
	settleVow(vow: bigint, outcome: { ok: Argument } | { err: PancakeError }): void;
	vowSessionClosing(vow: bigint): boolean;
	dialExporter(
		transport: string,
		designator: string,
		directAddressesHint: string,
	): Promise<Session>;
}

/** Run `pancake_host_pump_drain` with park-only arms; return decoded actions
 * in queue order. Views are copied inside `decodeHostAction` before the next
 * pop frees them. The arm callback and hooks buffer stay alive for the C call. */
export function parkActions(host: ActionHost): HostAction[] {
	const parked: HostAction[] = [];
	const parkCb = ffi.makeCallback(
		{
			parameters: ["pointer", "pointer", "pointer", "pointer"],
			result: "i32",
		},
		(_ctx: Ptr, _hostPtr: Ptr, actionPtr: Ptr, outProgressed: Ptr): number => {
			const bytes = ffi.readMemory(actionPtr, HOST_ACTION_SIZE);
			parked.push(decodeHostAction(new DataView(bytes)));
			if (outProgressed !== NULL) {
				const flag = new Uint8Array(4);
				new DataView(flag.buffer).setUint32(0, 1, true);
				ffi.writeMemory(outProgressed, flag);
			}
			return OK;
		},
	);
	try {
		const hooks = new Uint8Array(HOST_PUMP_HOOKS_SIZE);
		const dv = new DataView(hooks.buffer);
		const arm = parkCb.pointer;
		dv.setBigUint64(HOST_PUMP_HOOKS_FLUSH_OFF, arm, true);
		dv.setBigUint64(HOST_PUMP_HOOKS_CLOSE_OFF, arm, true);
		dv.setBigUint64(HOST_PUMP_HOOKS_NEED_GIFT_ID_OFF, arm, true);
		dv.setBigUint64(HOST_PUMP_HOOKS_COMPLETE_OFF, arm, true);
		dv.setBigUint64(HOST_PUMP_HOOKS_DIAL_OFF, arm, true);
		const acted = new Uint8Array(4);
		checkHost(driverS.pancake_host_pump_drain(host.raw, ab(hooks), ab(acted)));
		return parked;
	} finally {
		parkCb.close();
	}
}

/** The executor is deliberately dumb: every decision was already made in the
 * core; each arm is pure I/O or marshalling. Exhaustive on the generated
 * `HostAction` discriminant — a seventh kind fails compile. */
export async function runAction(host: ActionHost, action: HostAction): Promise<void> {
	switch (action.kind) {
		case HOST_ACTION_DIAL: {
			let conn: Session;
			try {
				conn = await host.dialExporter(
					action.transport,
					action.designator,
					action.directAddressesHint,
				);
			} catch (err) {
				// The host turns a failed dial into broken redeems.
				const reason = utf8Encoder.encode(
					err instanceof Error ? err.message : String(err),
				);
				checkHost(driverS.pancake_host_dial_failed(
					host.raw,
					action.ticket,
					ab(reason),
					BigInt(reason.length),
				));
				return;
			}
			conn.hostDialed = true;
			// Keep the exporter connection pumped: the withdraw's resolution —
			// and any later routed traffic — rides it immediately.
			conn.serve().catch(() => {});
			checkHost(driverS.pancake_host_dialed(host.raw, action.ticket, conn.raw));
			return;
		}
		case HOST_ACTION_FLUSH:
			await host.getSession(action.conn)?.flushOutbound();
			return;
		case HOST_ACTION_CLOSE: {
			// The host condemned the connection mid-pump (local turn budget
			// exceeded): write its queued resource_exhausted abort, then close
			// the transport and release the conn shell.
			const conn = host.getSession(action.conn);
			if (conn === undefined) return;
			try {
				await conn.flushOutbound();
			} catch {
				// best-effort: the session is ending either way
			}
			conn.closeTransport();
			return;
		}
		case HOST_ACTION_NEED_GIFT_ID: {
			// Entropy is a host effect, drawn only when a reply actually becomes
			// a gift.
			const id = crypto.getRandomValues(new Uint8Array(32));
			checkHost(driverS.pancake_host_provide_gift_id(
				host.raw,
				action.ticket,
				ab(id),
				32n,
			));
			return;
		}
		case HOST_ACTION_SETTLE:
			host.settleVow(action.ticket, { ok: action.value });
			return;
		case HOST_ACTION_FAIL: {
			// A FAIL fired by the disconnect's own break (the connection is
			// closing) classifies as the typed CLOSED, not a partner break.
			const closing = host.vowSessionClosing(action.ticket);
			host.settleVow(action.ticket, {
				err: closing
					? new PancakeError(CLOSED, action.message)
					: new VowBroken(action.message),
			});
			return;
		}
		default: {
			const _exhaustive: never = action;
			void _exhaustive;
		}
	}
}
