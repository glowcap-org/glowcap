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

import { hostS } from "./internal/ffi/host.ts";
import type { Ptr } from "./internal/ffi/runtime.ts";
import { ab } from "./internal/seam.ts";
import { L } from "./internal/layout.ts";
import { HOST_ACTION_RESUME, WOULD_BLOCK } from "@pancake/abi";
import { decodeHostAction, dispatchHostAction, type HostAction } from "./internal/host_action.ts";
import { checkHost, PancakeError, vowFailure } from "./errors.ts";
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
}

/** Pop every pending embedder action (`pancake_host_next_action` until
 * WOULD_BLOCK); return them decoded, in queue order. A popped action's byte
 * views are host-owned and valid only until the next pop frees them, so
 * `decodeHostAction` copies each out before the loop continues. */
export function parkActions(host: ActionHost): { actions: HostAction[]; yielded: boolean } {
	const parked: HostAction[] = [];
	const out = new Uint8Array(L.HOST_ACTION_SIZE);
	while (true) {
		const rc = hostS.pancake_host_next_action(host.raw, ab(out));
		if (rc === WOULD_BLOCK) return { actions: parked, yielded: false };
		checkHost(rc);
		const action = decodeHostAction(new DataView(out.buffer));
		if (action.kind === HOST_ACTION_RESUME) {
			return { actions: parked, yielded: true };
		}
		parked.push(action);
	}
}

/** The executor is deliberately dumb: every decision was already made in the
 * core; each arm is pure I/O or marshalling. The kind inventory lives in the
 * generated `dispatchHostAction` — a new kind fails generate/check. */
export async function runAction(host: Host, action: HostAction): Promise<void> {
	await dispatchHostAction(action, {
		dial: (a) => {
			// Started, not awaited. A dial can itself need this host's drains and
			// serve loops: a signaling dial (ADR-0089) round-trips OCapN messages
			// on an existing session before its channel exists, and the serve
			// loop that must read those replies awaits this very drain at its
			// feed's unwind — awaiting the dial here starves the exchange the
			// dial waits on. The ticket contract is already asynchronous:
			// `runDialTicket` reports `pancake_host_dialed` / `dial_failed`
			// whenever it settles, and the follow-up kick drains what that
			// report queued. (Lazy import: action ↔ dial would cycle through
			// Host if required eagerly.)
			host.startDialTask(a.ticket, async (signal) => {
				if (signal.aborted) return;
				const { runDialTicket } = await import("./dial.ts");
				await runDialTicket(host, a.ticket, signal);
				if (!host.released) await host.kickActions();
			});
		},
		cancelDial: async (a) => {
			await host.cancelDialTask(a.ticket);
		},
		flush: async (a) => {
			const session = host.getSession(a.session);
			if (session == null) return;
			try {
				await session.flushOutbound();
			} catch {
				// Session.flushOutbound owns exact failure retention and retirement;
				// this session-scoped fault must not fail an unrelated Host drain.
			}
		},
		close: async (a) => {
			const session = host.getSession(a.session);
			if (session == null) return;
			try {
				await session.flushOutbound();
			} catch {
				// Session.flushOutbound already retained the exact first cause.
			}
			// Commit native/wrapper retirement now, but leave the asynchronous
			// Channel.close() barrier to Session.close() (or the serve pump),
			// which already joins it. Awaiting that barrier inside this drain can
			// deadlock with a pump that is itself waiting for CLOSE to drain.
			const transportClose = session.closeTransport();
			void transportClose.catch(() => {});
			session.finishClose(a.result);
		},
		needGiftId: (a) => {
			try {
				const id = crypto.getRandomValues(new Uint8Array(32));
				checkHost(hostS.pancake_host_provide_gift_id(
					host.raw,
					a.ticket,
					ab(id),
					32n,
				));
			} catch {
				checkHost(hostS.pancake_host_gift_id_failed(host.raw, a.ticket));
			}
		},
		settle: (a) => {
			host.settleVow(a.ticket, { ok: a.value });
		},
		fail: (a) => {
			host.settleVow(a.ticket, { err: vowFailure(a.result, a.message) });
		},
		resume: (_a) => {
			// parkActions normally consumes this as its `yielded` result; retain
			// the exhaustive generated handler for direct runAction callers.
		},
	});
}
