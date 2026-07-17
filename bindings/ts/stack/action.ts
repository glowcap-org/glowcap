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
	HOST_ACTION_SIZE,
	HOST_PUMP_HOOKS_CLOSE_OFF,
	HOST_PUMP_HOOKS_COMPLETE_OFF,
	HOST_PUMP_HOOKS_DIAL_OFF,
	HOST_PUMP_HOOKS_FLUSH_OFF,
	HOST_PUMP_HOOKS_NEED_GIFT_ID_OFF,
	HOST_PUMP_HOOKS_SIZE,
	OK,
} from "./internal/abi.ts";
import { decodeHostAction, dispatchHostAction, type HostAction } from "./internal/host_action.ts";
import { checkHost, PancakeError, VowBroken } from "./errors.ts";
import type { Host } from "./host.ts";
import type { Session } from "./session.ts";
import type { Argument } from "./value.ts";

export type { HostAction };

/** Live host state the action drain needs. `Host` satisfies this structurally
 * via its binding-internal methods so `parkActions` / `runAction` never reach
 * into private class fields. */
export interface ActionHost {
	readonly raw: Ptr;
	getSession(ptr: Ptr): Session | undefined;
	settleVow(vow: bigint, outcome: { ok: Argument } | { err: PancakeError }): void;
	vowSessionClosing(vow: bigint): boolean;
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
 * core; each arm is pure I/O or marshalling. The kind inventory lives in the
 * generated `dispatchHostAction` — a seventh kind fails generate/check. */
export async function runAction(host: Host, action: HostAction): Promise<void> {
	await dispatchHostAction(action, {
		dial: async (a) => {
			// Lazy: action ↔ dial would cycle through Host if required eagerly.
			const { runDialTicket } = await import("./dial.ts");
			await runDialTicket(host, a.ticket);
		},
		flush: async (a) => {
			await host.getSession(a.conn)?.flushOutbound();
		},
		close: async (a) => {
			const conn = host.getSession(a.conn);
			if (conn === undefined) return;
			try {
				await conn.flushOutbound();
			} catch {
				// best-effort: the session is ending either way
			}
			conn.closeTransport();
		},
		needGiftId: (a) => {
			const id = crypto.getRandomValues(new Uint8Array(32));
			checkHost(driverS.pancake_host_provide_gift_id(
				host.raw,
				a.ticket,
				ab(id),
				32n,
			));
		},
		settle: (a) => {
			host.settleVow(a.ticket, { ok: a.value });
		},
		fail: (a) => {
			const closing = host.vowSessionClosing(a.ticket);
			host.settleVow(a.ticket, {
				err: closing ? new PancakeError(CLOSED, a.message) : new VowBroken(a.message),
			});
		},
	});
}
