// Replacing what a page keeps over its link to a session with what a new link
// to it holds. A dial that fails changes nothing, and once the new handles are
// installed the link is live. Each owner of something kept then moves it, and
// a failure there is that owner's own, never the link's.
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import { managedAccessText as text, savedControlSource } from "../../../../lib/text/managed_access.ts";
import type {
	RoomsManagedApplication,
	RoomsManagedObservation,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";
import { registerObservation } from "./observation_registration.ts";
import { reportMoveFailure } from "./control_reach.ts";
import { TYPING_SOURCE } from "./typing.ts";
import type { ManagedRoomsSession } from "./session.ts";
import { ACTIVE_VIEW, type ObservationView, permitted, type WorkspaceSnapshot } from "./model.ts";

/** Everything a new link answers before the page adopts it. */
export interface DialedLink {
	readonly workspace: RoomsManagedWorkspace;
	readonly observation: RoomsManagedObservation;
	readonly first: ObservationView;
	/** The accepted workspace, or null while this access may not observe it. */
	readonly snapshot: WorkspaceSnapshot | null;
}

/** Dial the saved access again in place of `stale`, read what the page needs
 * first, and hand it to `adopt` in the same turn as the last check. If any
 * step fails, the session the dial opened is closed and the new handles are
 * released, so the page keeps what it had and the next dial opens a session of
 * its own: the Host reuses a live session to the same peer. Whatever in
 * `adopt` can throw runs before it replaces anything, so its throw is one more
 * failed step. */
export async function dialAgain(
	application: RoomsManagedApplication,
	stale: RoomsManagedWorkspace,
	stopped: () => boolean,
	adopt: (dialed: DialedLink) => void,
): Promise<void> {
	const workspace: RoomsManagedWorkspace = await application.relink(ACTIVE_VIEW, stale);
	let observation: RoomsManagedObservation | null = null;
	try {
		if (stopped()) throw new LocalRefusal("session-closed");
		observation = await registerObservation(workspace);
		const first: ObservationView = await observation.poll();
		const snapshot: WorkspaceSnapshot | null = permitted(first.source, "observeWorkspace")
			? await workspace.snapshot()
			: null;
		if (stopped()) throw new LocalRefusal("session-closed");
		adopt({ workspace, observation, first, snapshot });
	} catch (error) {
		observation?.free();
		await workspace.retire().catch(() => {
			// best-effort: the dial's own failure is what the link reads. A close
			// that failed goes on in the binding, and the next dial's own close
			// waits on that same close before it dials.
		}).finally(() => workspace.free());
		throw error;
	}
}

/** The owners of what the session object keeps over its link, which a move
 * moves in its own order. */
export type LinkOwners = Pick<
	ManagedRoomsSession,
	"actions" | "management" | "navigation" | "typing" | "drafts" | "effects"
>;

/** What one link move reports through. */
interface Move {
	/** Whether this move is still the newest link's. */
	current(): boolean;
	/** Ask whether the new link still answers, after a lost connection over a call that is not its own. */
	probe(): void;
	report(source: string, error: unknown): void;
	/** Owners of something kept outside the session object. */
	listeners: Iterable<() => void>;
}

/** Run one step of a move. A throw there is reported as the move's, and the
 * steps after it still run. */
function step(move: Move, run: () => void): void {
	try {
		run();
	} catch (error) {
		move.report(managedText.sessionReconnect, error);
	}
}

/** Move everything the page keeps over the link onto the new one, in order.
 * Held access reaches its sessions over connections of its own, so it moves
 * beside the rest and holds none of it back. Each owner's failure is its own,
 * reported under that owner's name, or as the move's when the owner throws,
 * and every owner after it still moves. The move is not repeated after a lost
 * connection: the next link starts it again.
 * A receipt this page holds is looked up by its operation id when its worker,
 * or a person, next asks for it (`rehome`). One it does not hold belongs to the
 * tab that sent it, so only startup adopts it. */
export async function resumeLink(session: LinkOwners, move: Move): Promise<void> {
	if (!move.current()) return;
	step(move, () => session.actions.relink(move.report));
	// The access owner tracks this move, so the page's close waits for it.
	step(move, () =>
		void session.management.relink({
			current: move.current,
			report: (id, error) => move.report(savedControlSource(id), error),
			probe: move.probe,
		}).catch((error: unknown) => {
			// A newer link moves held access again and says what fails there.
			if (!move.current()) return;
			// A lost connection of held access only asks whether the page's link
			// still answers.
			reportMoveFailure(move, text.management, error);
		}));
	step(move, () => void session.typing.relink().catch((error: unknown) => move.report(TYPING_SOURCE, error)));
	step(move, () => session.drafts.resume());
	step(move, () => session.navigation.relink());
	for (const listener of move.listeners) step(move, listener);
	try {
		await session.effects.resumeRestore();
	} catch (error) {
		move.report(managedText.resultRecovery, error);
	}
}
