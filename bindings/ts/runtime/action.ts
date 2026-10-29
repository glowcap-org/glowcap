// Host-action park + execute: the embedder-contract switch the CapTP host
// drain runs. `Host` owns park/kick/vows and the Session registry; decode/types
// come from the generated `internal/host_action.ts`
// (`zig build gen-binding-host-action`); this module owns the canonical
// pop-until-WOULD_BLOCK drain (`glowcap_host_next_action`, the one-loop rule),
// then runs each parked arm (dial, flush, close, gift-id entropy, settle,
// fail) after the pops, so async I/O never runs while a borrowed action view
// is live and no FFI callback is minted per drain. The pop-based drain is
// also the only shape every FFI target has: the wasm32 browser adapter carries
// only the fixed behavior and hosted-retirement callback shapes, so a hooks-
// buffer drain could never run there.

import { hostS } from "./internal/ffi/host.ts";
import type { Ptr } from "./internal/ffi/runtime.ts";
import { ab } from "./internal/seam.ts";
import { L } from "./internal/layout.ts";
import { HOST_ACTION_RESUME, WOULD_BLOCK } from "@glowcap/abi";
import { decodeHostAction, dispatchHostAction, type HostAction } from "./internal/host_action.ts";
import { checkHost, GlowcapError, vowFailure } from "./errors.ts";
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
	settleVow(vow: bigint, outcome: { ok: Argument } | { err: GlowcapError }): void;
}

/** Complete one gift-id effect without letting a rejected FFI completion
 * masquerade as entropy failure. Package-internal and exported for the pure
 * binding-boundary regression. */
export function answerGiftId(
	draw: () => Uint8Array,
	provide: (id: Uint8Array) => void,
	failed: () => void,
): void {
	let id: Uint8Array;
	try {
		id = draw();
	} catch {
		failed();
		return;
	}
	provide(id);
}

/** Pop every pending embedder action (`glowcap_host_next_action` until
 * WOULD_BLOCK); return them decoded, in queue order. A popped action's byte
 * views are host-owned and valid only until the next pop frees them, so
 * `decodeHostAction` copies each out before the loop continues. */
export function parkActions(host: ActionHost): { actions: HostAction[]; yielded: boolean } {
	const parked: HostAction[] = [];
	const out = new Uint8Array(L.HOST_ACTION_SIZE);
	while (true) {
		const rc = hostS.glowcap_host_next_action(host.raw, ab(out));
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
 * generated `dispatchHostAction`: a new kind fails generate/check. */
export async function runAction(host: Host, action: HostAction): Promise<void> {
	await dispatchHostAction(action, {
		dial: (a) => {
			// Started, not awaited. A dial can itself need this host's drains and
			// serve loops: a signaling dial (ADR-0035) round-trips OCapN messages
			// on an existing session before its channel exists, and the serve
			// loop that must read those replies awaits this very drain at its
			// feed's unwind: awaiting the dial here starves the exchange the
			// dial waits on. The ticket contract is already asynchronous:
			// `runDialTicket` reports `glowcap_host_dialed` / `dial_failed`
			// whenever it settles, and the follow-up kick drains what that
			// report queued. (Lazy import: action ↔ dial would cycle through
			// Host if required eagerly.)
			host.startDialTask(a.ticket, a.routeIndex, async (signal) => {
				if (signal.aborted) return;
				const { runDialTicket } = await import("./dial.ts");
				await runDialTicket(host, a.ticket, a.routeIndex, signal);
				if (!host.released) await host.kickActions();
			});
		},
		cancelDial: async (a) => {
			await host.cancelDialTask(a.ticket, a.routeIndex);
		},
		flush: (a) => {
			// The session's writer owns the write, so this drain, and the serve
			// loop running it, keeps reading while the partner is slow to. A
			// write failure retires only that session, never this Host drain.
			host.getSession(a.session)?.requestFlush();
		},
		close: (a) => {
			// The writer drains what the core queued ahead of this CLOSE, then
			// commits retirement and settles an explicit close. The asynchronous
			// Channel.close() barrier stays with Session.close() or the serve pump.
			host.getSession(a.session)?.closeAfterFlush(a.result);
		},
		needGiftId: (a) => {
			answerGiftId(
				() => crypto.getRandomValues(new Uint8Array(32)),
				(id) =>
					checkHost(hostS.glowcap_host_provide_gift_id(
						host.raw,
						a.ticket,
						ab(id),
						32n,
					)),
				() => checkHost(hostS.glowcap_host_gift_id_failed(host.raw, a.ticket)),
			);
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
