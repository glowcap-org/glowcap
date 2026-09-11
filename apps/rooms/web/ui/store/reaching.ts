// Filing what the reader meant, and answering the card from it.
//
// A value reaches the join card three ways, and they are deliberately not
// interchangeable. `reach` is somebody arriving at the card and how they got
// there; `editJoin` is them changing an answer while they are in front of it;
// `remember` is a join having actually worked. Nothing else may write these
// fields, which is what stops a surface from leaving a value behind for the
// next one to find. The model itself is `intent.ts`, and what the card does
// with it is `joining.ts`.

import { current, type Reach } from "../intent.ts";
import type { RoomPreset } from "../room_policy.ts";
import { type DirectoryDestinationContext, type JoinAnswers, joinAnswers } from "../joining.ts";
import { clearConv, showJoinCard } from "./chrome.ts";
import type { PageProjection, State } from "./core.ts";

/** Somebody has arrived at the join card, and this is how.
 *
 * Every act supersedes the one before it, including anything the reader had
 * typed under it: reaching for a different room is a different question, and
 * an answer to the last one is not an answer to this one.
 *
 * The application moving the reader here by itself files nothing. A directory
 * going away, or landing on the card after leaving the last room, is not
 * somebody asking for anything, so the last real act keeps standing and
 * whatever the reader had typed stays where they left it. */
export function reach(projection: PageProjection, act: Reach): void {
	projection.set({ reaching: { ...act, seq: projection.get().reaching.seq + 1 } });
}

/** File an act and put the card up as its answer.
 *
 * What "put it up" means depends on how the reader got here, and the source is
 * the whole of the difference. A press was made through whatever the phone had
 * open and means to leave it, so the list screen and the roster sheet go. A
 * link decides where the reader is standing and nothing else, so the furniture
 * stays exactly as they left it. */
export function showJoinFor(projection: PageProjection, act: Reach): void {
	reach(projection, act);
	if (act.source === "press") showJoinCard(projection);
	else clearConv(projection);
}

/** The reader changing an answer, which counts against the act they are
 * answering. */
export function editJoin(projection: PageProjection, patch: {
	room?: string;
	locator?: string;
	nick?: string;
	roomPreset?: RoomPreset;
}): void {
	// Over what the reader has already said *about this act*, not over whatever
	// the last one left behind. Filing an act does not clear overrides — the act
	// they belong to is what makes them apply, and reading through `current` is
	// the one place that is decided. Spreading `projection.get().edits` raw here would have
	// been a second answer to the same question, and the wrong one: an override
	// the reader made two rooms ago would ride back in the moment they touched
	// any other field.
	const state = projection.get();
	projection.set({ edits: { ...current(state.edits, state.reaching), ...patch } });
}

/** What this browser should offer next time, written when a join has actually
 * worked.
 *
 * On success rather than on every keystroke, because a locator typed halfway
 * and abandoned is not something the reader did, and offering it back would
 * present it as though it were. */
export function remember(projection: PageProjection, patch: { room?: string; locator?: string; nick?: string }): void {
	const was = projection.get().remembered;
	const next = { ...was, ...patch };
	// A reader re-entering the room they always enter is the ordinary case, and
	// it changes nothing here. Saying so anyway would replace the object every
	// other surface resolves against and redraw the page for it.
	if (next.room === was.room && next.locator === was.locator && next.nick === was.nick) return;
	projection.set({ remembered: next });
}

/** What the join card shows, and the evidence behind each field. */
export function answers(
	projection: PageProjection,
	snapshot: Readonly<Pick<State, "homeDir" | "reaching" | "edits" | "remembered">> = projection.get(),
	context: DirectoryDestinationContext = { home: snapshot.homeDir, defaultDirectory: null },
): JoinAnswers {
	return joinAnswers(snapshot.reaching, snapshot.edits, snapshot.remembered, context);
}

/** The name this reader goes by when nothing else has granted one.
 *
 * Every "do we have a name to enter a room with" asks this, so a name typed
 * into the card but not yet used counts, and so does one remembered from a
 * past visit. A directory's own grant is a different and stronger answer, and
 * lives in `dirNick`. */
export function reachingNick(projection: PageProjection): string {
	return answers(projection).nick.value;
}
