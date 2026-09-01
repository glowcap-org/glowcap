// What every operator section does with a press.
//
// Each section is an inventory of one thing the directory holds, and each row
// offers the same shape of act: ask, then commit, then either the row leaves
// or it says why it could not. That shape is here once, so a section file is
// the list it draws and nothing else.

import { type ReactNode, useRef, useState } from "react";
import { Confirm } from "../Confirm.tsx";
import { useRoomsSession } from "../controller/session.ts";
import type { RoomsSessionController } from "../controller/session.ts";

export interface OperatorActs {
	/** Which row is holding its question open, keyed by the caller's own key. */
	readonly confirming: string | null;
	/** Whether a row's act is in flight. */
	readonly busy: (key: string) => boolean;
	/** The refusal a row's act met, by key. */
	readonly why: Partial<Record<string, string>>;
	/** Open a row's question. */
	ask(key: string): void;
	/** Run a row's act, keeping its refusal on the row that asked. */
	run(key: string, request: () => Promise<string>): void;
	/** The row's question, drawn only while that row is the one asking. */
	confirm(key: string, say: string, label: string, request: () => Promise<string>): ReactNode;
	/** The verbs a section calls, so a section file needs no hook of its own. */
	readonly session: RoomsSessionController;
}

export function useOperatorActs(): OperatorActs {
	const session = useRoomsSession();
	const [busy, setBusy] = useState<ReadonlySet<string>>(() => new Set());
	const [confirming, setConfirming] = useState<string | null>(null);
	const [why, setWhy] = useState<Partial<Record<string, string>>>({});
	const running = useRef(new Set<string>());
	const run = (key: string, request: () => Promise<string>) => {
		if (running.current.has(key)) return;
		// Whether this act is the commitment of a question already open on its
		// row. An act pressed without one — a grant, a reset — must not put away
		// a question the reader opened while it was in flight, and rows reuse one
		// key for both acts, so settling cannot tell them apart by key alone.
		const commitsQuestion = confirming === key;
		running.current.add(key);
		setBusy((prior) => new Set(prior).add(key));
		setWhy((prior) => {
			const next = { ...prior };
			delete next[key];
			return next;
		});
		void (async () => {
			let refused = "";
			try {
				refused = await request();
			} catch (error) {
				refused = error instanceof Error ? error.message : String(error);
			} finally {
				running.current.delete(key);
				setBusy((prior) => {
					const next = new Set(prior);
					next.delete(key);
					return next;
				});
			}
			if (commitsQuestion) setConfirming((current) => current === key ? null : current);
			if (refused !== "") setWhy((prior) => ({ ...prior, [key]: refused }));
		})();
	};
	const acts: OperatorActs = {
		confirming,
		busy: (key) => busy.has(key),
		why,
		ask: setConfirming,
		run,
		session,
		confirm: (key, say, label, request) =>
			confirming === key && (
				<Confirm
					label={label}
					say={say}
					keep="Keep it"
					commit={label}
					busy={busy.has(key)}
					onKeep={() => setConfirming(null)}
					onCommit={() => run(key, request)}
				/>
			),
	};
	return acts;
}
