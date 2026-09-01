// Atomic controller changes for one browser Rooms workspace.

import type { RoomsSessionSnapshot } from "../../../lib/session/client.ts";
import { type RoomsControllerSelection, type RoomsSessionState, sharedRoomsSession } from "../../../lib/rooms_state.ts";
import { roomsSturdyrefLocator } from "../../../lib/locator.ts";
import { attachedSessionFailureText } from "./attached_failure.ts";

export interface VerifiedRoomsSession {
	readonly current: RoomsSessionSnapshot | null;
	adoptWorkspace(checkpoint: RoomsSessionState): Promise<RoomsSessionSnapshot>;
	close(): Promise<void>;
}

export interface RoomsControllerTransition {
	current(): RoomsControllerSelection;
	localCheckpoint(): RoomsSessionState;
	connect(sturdyref: string): Promise<VerifiedRoomsSession>;
	/** Try a capability over the session this browser already holds, for a
	 * capability naming that session's own peer. Null when there is no live
	 * session to ask, which leaves the peer free for `connect` to reach. */
	verifyOverAttached(sturdyref: string): Promise<void> | null;
	select(controller: RoomsControllerSelection): boolean;
	reportCleanupFailure(error: unknown): void;
}

/** Whether two session capabilities name the same peer.
 *
 * A capability is a peer and a swissnum, and the peer is the transport and
 * designator the Host dials. That pair is also what the Host asks about before
 * it admits a dial, so this answers the same question it does. A capability
 * that cannot be read names nobody, and says so by being nobody's peer: the
 * caller then takes the path that opens a session and reports what the peer or
 * the parser actually said. */
function samePeer(one: string, two: string): boolean {
	try {
		const here = roomsSturdyrefLocator(one);
		const there = roomsSturdyrefLocator(two);
		return here.transport === there.transport && here.designator === there.designator;
	} catch {
		// tolerant: an unreadable capability is not a swap, and the path below
		// is where its refusal gets said.
		return false;
	}
}

/** Try the capability, then commit the browser selection to it.
 *
 * How it is tried depends on whose peer it names. A capability for another
 * session is tried by opening one, and that connection is always retired
 * before this promise settles, so a caller may reload without racing a second
 * CapTP pair. A capability for the peer this browser is already attached to
 * cannot be tried that way and is tried over the session in hand, which opens
 * nothing and so retires nothing.
 *
 * Either way nothing is committed until the capability has answered, because
 * committing is what costs the reader the capability that was working. */
export async function attachRoomsController(
	sturdyref: string,
	transition: RoomsControllerTransition,
): Promise<string> {
	const normalized = sturdyref.trim();
	const current = transition.current();
	const shared = sharedRoomsSession(current);
	if (shared != null && shared.sturdyref === normalized) return "";
	if (shared != null && samePeer(shared.sturdyref, normalized)) {
		// Changing which capability this browser holds for the session it is
		// already in, rather than moving to another session.
		//
		// The connection opened below cannot be opened here: a Host keeps one
		// session per peer, and this browser is that peer's session. So the
		// capability is tried over the session in hand, which is also the only
		// way to try it without first giving up the one that works. Nothing
		// else the connection does applies. It exists to hand a local workspace
		// over before committing, and a session accepts one exactly once:
		// being attached to this one is what closed its adoption.
		const trying = transition.verifyOverAttached(normalized);
		if (trying !== null) {
			try {
				await trying;
			} catch (error) {
				return attachedSessionFailureText(error);
			}
			if (current.kind === "hosted") return "";
			return transition.select({ kind: "attached", sturdyref: normalized })
				? ""
				: "This browser refused to save the shared session capability.";
		}
		// No live session to that peer after all, so it is free to be reached
		// the ordinary way and there is nothing to work around.
	}
	let attached: VerifiedRoomsSession | null = null;
	let adoptedLocalWorkspace = false;
	try {
		attached = await transition.connect(normalized);
		const snapshot = attached.current;
		if (snapshot == null) throw new Error("the shared session produced no checkpoint");
		if (snapshot.workspaceAdoption === "available") {
			await attached.adoptWorkspace(transition.localCheckpoint());
			adoptedLocalWorkspace = true;
		}
		if (!transition.select({ kind: "attached", sturdyref: normalized })) {
			return adoptedLocalWorkspace
				? "The shared session adopted this workspace, but this browser refused to remember the session capability. Retry the same capability to finish attaching."
				: "This browser refused to save the shared session capability.";
		}
		return "";
	} catch (error) {
		return attachedSessionFailureText(error);
	} finally {
		if (attached != null) {
			try {
				await attached.close();
			} catch (error) {
				transition.reportCleanupFailure(error);
			}
		}
	}
}
