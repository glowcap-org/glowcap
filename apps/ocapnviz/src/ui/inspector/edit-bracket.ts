/**
 * One edit transaction's brackets, and one typed-but-not-yet-handed-up
 * draft. Fields open on focus and close on blur. Unmount without blur
 * still has to close, or the engine swallows every later undo step.
 */

import { useCallback, useEffect, useRef } from "react";
import type { EditorBindings } from "./bindings.ts";

/** The edit-transaction pair a row needs from `EditorBindings` so a
 * scrub gesture lands as ONE undo step. */
export type EditBracket = Pick<EditorBindings, "beginEdit" | "endEdit">;

/**
 * One edit transaction's brackets, tracking whether it is open.
 *
 * Opening one is easy and closing one is the whole problem. A field
 * opens on focus and closes on blur, but a panel whose entity stops
 * being selected unmounts its field WITHOUT a blur, and the
 * transaction it left open swallows every dispatch after it: the
 * engine records history only at depth zero, so from that moment
 * nothing in the app is undoable. Two of the five panels had each
 * written their own unmount guard for this and three had not, which
 * is what a rule enforced by remembering looks like after a while.
 *
 * So the bracket knows if it is open, and closing twice is not a
 * second close. `useEditBracket` below hands its `end` to React's
 * unmount, which is the only thing a field can be sure of.
 *
 * Which editor it opened on is the other half, and it is the half a
 * flag cannot hold. The editor under a field is not a constant: it is
 * undefined outside Build and a different object once the buffer is a
 * different engine, and both changes are reachable while a caret sits
 * in a field. So `sessionNow` is asked once, at `begin`, and the
 * answer is what `end` closes. The transaction belongs to the editor
 * that opened it, and closing it against whatever the field is holding
 * a moment later either closes nothing (the leak this exists to stop)
 * or ends a transaction on an engine that never began one. Asked and
 * answered undefined, there is no bracket at all: a read-only host
 * opens nothing and so has nothing to close.
 *
 * This is a plain factory rather than a hook so a test can drive open,
 * close and the editor changing underneath in the orders a user
 * reaches them in.
 */
export function editBracket(sessionNow: () => EditBracket | undefined): {
	begin: (label: string) => void;
	end: () => void;
	readonly isOpen: boolean;
} {
	let open: EditBracket | null = null;
	const end = () => {
		const opened = open;
		if (opened === null) return;
		open = null;
		opened.endEdit();
	};
	return {
		begin(label: string) {
			if (open !== null) return;
			const session = sessionNow();
			if (session === undefined) return;
			open = session;
			session.beginEdit(label);
		},
		end,
		get isOpen() {
			return open !== null;
		},
	};
}

/**
 * One typed-but-not-yet-handed-up edit, tracking whether it is still
 * waiting.
 *
 * `editBracket` above is the same story about an undo step. This is
 * the story about the edit itself. A field holds a draft while it is
 * being typed and hands it up when the reader is done, and "done" is
 * spelled as blur. Selecting another entity unmounts the field
 * WITHOUT a blur, so the draft went with it and the rename the reader
 * typed simply never happened. Nothing said so, which is what makes it
 * worse than a lost undo step: the reader watched themselves type it.
 *
 * So the edit knows whether it is still waiting, and handing it up
 * twice is not a second edit. `usePendingEdit` below hands its
 * `dispose` to React's unmount, which is the only thing a field can be
 * sure of. That second half is load-bearing on its own: a rename that
 * lands moves the anchor, which unmounts the field that made it, and
 * an unmount that handed the same draft up again would ask to rename
 * an id the document no longer has.
 *
 * `touch` says the draft has moved since it was last handed up, and
 * whether the draft differs from the committed value at all stays the
 * commit function's own question. `discard` is how a reader says no:
 * putting the draft back and then blurring cannot do it, because the
 * put-back is a state update that has not landed by the time the blur
 * runs, so the commit would read the draft the reader just abandoned.
 * This is a plain factory rather than a hook so a test can drive
 * typing, committing, abandoning and unmounting in the orders a reader
 * reaches them in.
 */
export function pendingEdit(commit: () => void): {
	touch: () => void;
	settle: () => void;
	discard: () => void;
	dispose: () => void;
	readonly isPending: boolean;
} {
	let waiting = false;
	const settle = () => {
		if (!waiting) return;
		waiting = false;
		commit();
	};
	return {
		touch() {
			waiting = true;
		},
		settle,
		discard() {
			waiting = false;
		},
		dispose: settle,
		get isPending() {
			return waiting;
		},
	};
}

/** A `pendingEdit` that lives as long as the field holding it, and
 *  hands its draft up when that field goes away. */
export function usePendingEdit(commit: () => void) {
	// `commit` closes over this render's draft, so the pending edit
	// reads it through a ref rather than being rebuilt around it, a
	// rebuilt one would forget that an edit was waiting, and hand up a
	// stale draft when it did fire.
	const commitRef = useRef(commit);
	commitRef.current = commit;
	const held = useRef<ReturnType<typeof pendingEdit> | null>(null);
	if (held.current === null) {
		held.current = pendingEdit(() => commitRef.current());
	}
	const edit = held.current;
	useEffect(() => () => edit.dispose(), [edit]);
	return edit;
}

/** An `editBracket` that lives as long as the component holding it,
 *  and closes itself when that component goes away or when the editor
 *  under it changes. */
export function useEditBracket(session: EditBracket | undefined) {
	// One bracket for the field's whole life, reading the editor through
	// a ref rather than being rebuilt around it. A rebuilt bracket would
	// forget that it was open. The ref is read at `begin` and the answer
	// held, so a later render pointing it somewhere else cannot move an
	// open transaction.
	const sessionRef = useRef(session);
	sessionRef.current = session;
	const bracket = useRef<ReturnType<typeof editBracket> | null>(null);
	if (bracket.current === null) {
		bracket.current = editBracket(() => sessionRef.current);
	}
	const held = bracket.current;
	// Two ends a field never hears about, and one effect for both. The
	// field going away is the first: React has already detached its
	// handlers, so no blur is coming. The editor changing under a field
	// that stays is the second, and it is why `session` is a dependency:
	// leaving Build takes the editor away, and a new buffer replaces it,
	// and either way the transaction the old one opened has to be closed
	// on the old one while something still holds it.
	useEffect(() => () => held.end(), [held, session]);
	return held;
}

/** Drag brackets for a row's scrub input: open a labeled edit
 * transaction when the drag starts, close it when the drag ends, and
 * close it too if the row goes away mid-drag. Undefined session means
 * no brackets, for read-only hosts. */
export function useScrubBracket(
	session: EditBracket | undefined,
	label: string,
): { onScrubStart?: () => void; onScrubEnd?: () => void } {
	const bracket = useEditBracket(session);
	const onScrubStart = useCallback(() => bracket.begin(label), [
		bracket,
		label,
	]);
	const onScrubEnd = useCallback(() => bracket.end(), [bracket]);
	if (!session) return {};
	return { onScrubStart, onScrubEnd };
}
