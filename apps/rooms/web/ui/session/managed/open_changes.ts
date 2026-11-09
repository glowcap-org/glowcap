// The changes this session has not finished, whoever holds them. The receipt
// inventory the workspace keeps owns which receipts are still open, the
// session adds the results it still has to save and the work without a
// receipt, and a committed receipt nothing here still has to save is done.
// The Session tab offers the list while it has rows, and the recovery card
// draws its rows from it, so both read this one derivation.

import { useEffect, useState, useSyncExternalStore } from "react";
import type { ManagedRoomsSession } from "./session.ts";
import type { EffectView } from "./model.ts";
import { recoveryStatus } from "../../../../lib/text/recovery.ts";
import { refusalText } from "../../../../lib/text/failure.ts";

export type OpenChangeState = keyof typeof recoveryStatus;

export type OpenChange = {
	readonly id: string;
	readonly status: string;
	readonly state: OpenChangeState;
	/** The one act that moves the change on, or null while it is still running. */
	readonly act: "complete" | "acquire" | null;
	/** Whether the reader may let the change go without an outcome. */
	readonly letGo: boolean;
	readonly resumable?: boolean;
};

/** The open changes, from the session's own state and the inventory `rows`,
 * which are null until the first read has landed. */
export function openChanges(session: ManagedRoomsSession, rows: readonly EffectView[] | null): OpenChange[] {
	const holding = new Set(session.pending);
	const acquiring = new Set(
		[...session.pendingOperations].filter((operation) => operation.acquiring).map((operation) => operation.id),
	);
	const recoverable = new Set([...session.recoverable, ...session.actions.recoverable]);
	const receipted = new Set((rows ?? []).map((row) => row.operation));
	const known = (status: string): OpenChangeState =>
		(status in recoveryStatus ? status : "unknown") as OpenChangeState;
	// What each held acquisition's lifecycle knows of its outcome.
	const outcomes = new Map(session.actions.diagnostics.map((row) => [row.operation, row.outcome]));
	return [
		...session.actions.pending.map((id): OpenChange => {
			const committed = outcomes.get(id) === "committed";
			const ready = recoverable.has(id);
			return {
				id,
				status: committed ? "committed" : "unknown",
				state: ready ? (committed ? "saving" : "unknown") : "working",
				act: ready ? "acquire" : null,
				// One that went through still needs its original receiver here.
				// One nothing settled may be let go: the session's own state
				// says what it holds.
				letGo: ready && !committed,
			};
		}),
		...(rows ?? []).filter((row) => row.status !== "committed" || holding.has(row.operation)).map(
			(row): OpenChange => {
				const id = row.operation;
				const ready = holding.has(id) ? recoverable.has(id) : row.resumable;
				// Held work that is not recoverable is still running here.
				const running = holding.has(id) && !ready;
				return {
					id,
					status: row.status,
					resumable: row.resumable,
					state: running ? "working" : known(row.status),
					act: ready ? "complete" : null,
					// Paused executors still own admitted work and its settlement.
					letGo: !running && !row.resumable && !acquiring.has(id) && row.status !== "pending",
				};
			},
		),
		// Held here with no receipt: still being admitted, or its receipt has
		// left the window, which leaves its outcome unknown for good.
		...session.pending.filter((id) => !receipted.has(id)).map((id): OpenChange => ({
			id,
			status: "held",
			state: recoverable.has(id) ? "unknown" : "working",
			act: recoverable.has(id) ? "complete" : null,
			letGo: recoverable.has(id) && !acquiring.has(id),
		})),
	];
}

/** The open changes, re-read from the workspace whenever the session changes
 * while `active`. `rows` is null until the first read since activation lands,
 * and `failure` is the words of a read that did not land, or empty. The
 * caller repaints when the session's own admission and retry state changes,
 * not only when a read lands. */
export function useOpenChanges(
	session: ManagedRoomsSession,
	active: boolean,
): { readonly rows: EffectView[] | null; readonly changes: OpenChange[]; readonly failure: string } {
	const [rows, setRows] = useState<EffectView[] | null>(null);
	const [failure, setFailure] = useState("");
	useSyncExternalStore(session.subscribe, () =>
		JSON.stringify([
			session.pending,
			session.recoverable,
			session.actions.pending,
			session.actions.recoverable,
			session.updatesRetrying,
			session.updatesFailure != null,
		]), () => "");
	useEffect(() => {
		if (!active) {
			setRows(null);
			setFailure("");
			return;
		}
		let current = true;
		let dirty = false;
		let reading = false;
		// One read at a time: a change during a read marks it dirty, and the
		// read runs again once, so the rows shown are never older than the last
		// change.
		const refresh = () => {
			dirty = true;
			if (reading) return;
			reading = true;
			void (async () => {
				try {
					while (current && dirty) {
						dirty = false;
						try {
							const read: EffectView[] = await session.workspace.effects();
							if (current && !dirty) {
								setRows(read);
								setFailure("");
							}
						} catch (error) {
							if (current && !dirty) setFailure(refusalText(error));
						}
					}
				} finally {
					reading = false;
				}
			})();
		};
		const unsubscribe = session.subscribe(refresh);
		refresh();
		return () => {
			current = false;
			unsubscribe();
		};
	}, [active, session]);
	return { rows, changes: openChanges(session, rows), failure };
}
