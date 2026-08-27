// What every operator section does with a press.
//
// Each section is an inventory of one thing the directory holds, and each row
// offers the same shape of act: ask, then commit, then either the row leaves
// or it says why it could not. That shape is here once, so a section file is
// the list it draws and nothing else.

import { type ReactNode, useState } from "react";
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
	const run = (key: string, request: () => Promise<string>) => {
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
				setBusy((prior) => {
					const next = new Set(prior);
					next.delete(key);
					return next;
				});
			}
			setConfirming((current) => current === key ? null : current);
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

/** A section's name over its well, with how many rows are under it. The count
 * is the first thing an operator wants from a page of inventories, and it
 * belongs where the eye already stops.
 *
 * A directory holds as many of these as it has been asked to hold, and the
 * pane reads one page at a time, so the number is what has been read rather
 * than what exists. It says so with a trailing `+` while more remain: a bare
 * "20" over the first page of twenty thousand is the one thing this chip must
 * never say. A count of nothing draws no chip at all: the well under it
 * already says the inventory is empty, and a row of zeros down the page is
 * noise where every one of them is the same word twice. */
export function SectionTitle(
	{ id, count, more = false, children }: { id?: string; count?: number; more?: boolean; children: ReactNode },
) {
	return (
		<h3 className="well-title overline" id={id}>
			{children}
			{count != null && count > 0 && (
				<span className="ops-section-count" title={more ? `${count} read so far; more remain` : undefined}>
					{count}
					{more ? "+" : ""}
				</span>
			)}
		</h3>
	);
}
