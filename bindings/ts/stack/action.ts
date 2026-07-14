// Host-action pop + execute — the embedder-contract switch the CapTP host
// drain runs. `Host` owns park/kick/vows and the Session registry; decode/types
// come from the generated `internal/host_action.ts`
// (`zig build gen-binding-host-action`); this module owns popping via
// `pancake_host_next_action` and honoring each arm (dial, flush, close,
// gift-id entropy, settle, fail).

import { driverS } from "./internal/ffi/driver.ts";
import { type Ptr } from "./internal/ffi/runtime.ts";
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
	WOULD_BLOCK,
} from "./internal/abi.ts";
import { decodeHostAction, type HostAction } from "./internal/host_action.ts";
import { checkHost, PancakeError, VowBroken } from "./errors.ts";
import { type Argument } from "./value.ts";
import type { Session } from "./session.ts";

export type { HostAction };

const utf8Encoder = new TextEncoder();

/** Live host state the action drain needs. `Host` satisfies this structurally
 * via its binding-internal methods so `popAction` / `runAction` never reach
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

/** Pop the next embedder action, decoded per kind so each arm copies out only
 * the borrowed views the C struct fills for it — a SETTLE's PancakeArgument
 * lifted whole — before anything else can call `pancake_host_next_action`
 * (which frees them). Null when the queue is dry. */
export function popAction(host: ActionHost): HostAction | null {
	const buf = new Uint8Array(HOST_ACTION_SIZE);
	const rc = driverS.pancake_host_next_action(host.raw, ab(buf));
	if (rc === WOULD_BLOCK) return null;
	checkHost(rc);
	return decodeHostAction(new DataView(buf.buffer));
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
