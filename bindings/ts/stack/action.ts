// Host-action park + execute — the embedder-contract switch the CapTP host
// drain runs. `Host` owns park/kick/vows and the Session registry; decode/types
// come from the generated `internal/host_action.ts`
// (`zig build gen-binding-host-action`); this module owns the canonical
// pop-until-WOULD_BLOCK drain (`pancake_host_next_action`, the one-loop rule),
// then runs each parked arm (dial, flush, close, gift-id entropy, settle,
// fail) after the pops, so async I/O never runs while a borrowed action view
// is live and no native callback is minted per drain. The pop-based drain is
// also the only shape every FFI target has: the wasm32 browser adapter carries
// exactly one callback seam (the behavior trampoline), so a hooks-buffer drain
// could never run there.

import { driverS } from "./internal/ffi/host.ts";
import { type Ptr } from "./internal/ffi/runtime.ts";
import { ab } from "./internal/seam.ts";
import { L } from "./internal/layout.ts";
import { CLOSED, WOULD_BLOCK } from "@pancake/abi";
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

/** Pop every pending embedder action (`pancake_host_next_action` until
 * WOULD_BLOCK); return them decoded, in queue order. A popped action's byte
 * views are host-owned and valid only until the next pop frees them, so
 * `decodeHostAction` copies each out before the loop continues. */
export function parkActions(host: ActionHost): HostAction[] {
	const parked: HostAction[] = [];
	const out = new Uint8Array(L.HOST_ACTION_SIZE);
	while (true) {
		const rc = driverS.pancake_host_next_action(host.raw, ab(out));
		if (rc === WOULD_BLOCK) return parked;
		checkHost(rc);
		parked.push(decodeHostAction(new DataView(out.buffer)));
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
