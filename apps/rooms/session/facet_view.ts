// What one facet sees of a session.
//
// A view's access decides three things and nothing else decides them: whether
// the checkpoint arrives whole or with its bearer capabilities redacted, which
// rooms it hears about, and whether it is told what external operations are
// waiting. They are gathered here because they answer one question, and because
// a facet that carries nothing must be as easy to project as one that carries
// everything.

import type { Argument, Session } from "@glowcap/runtime";
import { mayInteract, mayObserve, type RoomsSessionAccess, type RoomsSessionRoomView } from "../lib/session/client.ts";
import { emptyRoomsSessionState, redactRoomsSessionCapabilities, type RoomsSessionState } from "../lib/rooms_state.ts";
import { describeRoomsSessionResult, EXTERNAL_SESSION_OPERATION } from "./result_commands.ts";
import { encodeSessionSnapshot } from "./snapshot_wire.ts";
import type { DurableRoomsSessionState } from "./state.ts";
import type { DurableRoomsRuntime } from "./runtime.ts";
import type { RoomsSessionGrantAuthority } from "./grants.ts";

export interface FacetViewOwner {
	readonly state: DurableRoomsSessionState;
	readonly runtime: DurableRoomsRuntime;
	readonly grants: RoomsSessionGrantAuthority;
}

function checkpointVisibleTo(rights: RoomsSessionAccess, checkpoint: RoomsSessionState): RoomsSessionState {
	return rights === "admin" ? checkpoint : redactRoomsSessionCapabilities(checkpoint);
}

export function roomViewsVisibleTo(
	rights: RoomsSessionAccess,
	views: readonly RoomsSessionRoomView[],
): RoomsSessionRoomView[] {
	return mayInteract(rights)
		? [...views]
		: views.map((view) => ({ ...view, canSetTopic: false, canModerate: false }));
}

export function effectDetailsFor(rights: RoomsSessionAccess, state: DurableRoomsSessionState): Argument[] {
	if (rights !== "admin") return [];
	return state.pendingEffectDetails().map((effect) =>
		[
			effect.id,
			effect.kind,
			effect.kind === "external"
				? effect.intent ?? EXTERNAL_SESSION_OPERATION
				: effect.intent == null
				? EXTERNAL_SESSION_OPERATION
				: describeRoomsSessionResult(effect.kind, effect.intent),
			effect.phase,
		] as Argument
	);
}

export function snapshotForFacet(
	rights: RoomsSessionAccess,
	session: Session,
	note: string,
	extraIssues: readonly { subject: string; reason: string }[],
	owner: FacetViewOwner,
): Argument[] {
	const snapshot = owner.state.snapshot();
	// A view with no access is answered with no session. It is the only honest
	// reading of "none": a paused link that is handed the rooms, the directories,
	// and who is in them has read the session, whether or not it may also act in
	// it, and it reads whatever has happened since the pause rather than what it
	// last saw. Holding it to what it saw would mean keeping a copy of the
	// session as it stood at the pause, durably, for a holder who is not
	// entitled to it — a second authority for the same facts, kept for the one
	// party with no right to them.
	//
	// The revision goes with it so the holder's own bookkeeping stays monotonic
	// across a pause it can do nothing during, and the note goes with it because
	// a browser showing nothing at all is owed the reason.
	//
	// Adoption is closed to it, and said to be. A browser attaching with a link
	// hands its own workspace over the moment it is told the session will take
	// one, and this holder's would be refused — so answering with the session's
	// real state would turn attaching with a paused link into a failure to
	// attach at all, rather than a workspace that says why it is empty. The one
	// door a paused link opens is finding out that it is paused.
	if (!mayObserve(rights)) {
		return encodeSessionSnapshot(
			snapshot.revision,
			emptyRoomsSessionState(),
			[],
			extraIssues,
			[],
			[],
			null,
			[],
			[],
			[],
			rights,
			"closed",
			[],
			[],
			note,
		);
	}
	return encodeSessionSnapshot(
		snapshot.revision,
		checkpointVisibleTo(rights, snapshot.checkpoint),
		owner.state.pendingEffectIds(),
		[...owner.runtime.issues(), ...extraIssues],
		owner.runtime.connectedDirectories(),
		effectDetailsFor(rights, owner.state),
		owner.runtime.memberLocator(),
		roomViewsVisibleTo(rights, owner.runtime.roomViews()),
		owner.runtime.archiveShares(),
		owner.runtime.directoryViews(),
		rights,
		owner.state.workspaceAdoption,
		rights === "admin" ? owner.grants.list(session) : [],
		owner.runtime.handedRooms.list(),
		note,
	);
}
