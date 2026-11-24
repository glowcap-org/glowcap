// Replacing what a page keeps over its link to a session with what a new link
// to it holds. A dial that fails changes nothing, and once the new handles are
// installed the link is live. Each owner of something kept then moves it, and
// a failure there is that owner's own, never the link's.
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import { managedAccessText as text } from "../../../../lib/text/managed_access.ts";
import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";
import type {
	RoomsManagedApplication,
	RoomsManagedObservation,
	RoomsManagedObservationRequest,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
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

/** Register a new observation of `workspace`, and release its request. With
 * `keep`, the request stays held while its submission is unanswered, so its
 * owner can submit it again. Without, a failed submission releases it. */
export async function registerObservation(
	workspace: RoomsManagedWorkspace,
	keep?: (request: RoomsManagedObservationRequest | null) => void,
): Promise<RoomsManagedObservation> {
	const registering: RoomsManagedObservationRequest = await workspace.prepareObservation();
	keep?.(registering);
	try {
		const observation = await registering.submit();
		registering.free();
		keep?.(null);
		return observation;
	} catch (error) {
		if (keep == null) registering.free();
		throw error;
	}
}

/** Dial the saved access again in place of `stale`, and read what the page needs
 * first. The new handles are released if any step fails, so the page keeps
 * what it had. */
export async function dialAgain(
	application: RoomsManagedApplication,
	stale: RoomsManagedWorkspace,
	stopped: () => boolean,
): Promise<DialedLink> {
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
		return { workspace, observation, first, snapshot };
	} catch (error) {
		observation?.free();
		workspace.free();
		throw error;
	}
}

/** Run one owner's move. Its failure is reported as its own, and a lost
 * connection says the link is gone again. */
export type Step = (
	source: string,
	work: (current: () => boolean) => void | Promise<void>,
) => Promise<void>;

/** Move everything the page keeps over the link onto the new one, in order. */
export async function resumeLink(
	session: ManagedRoomsSession,
	step: Step,
	reportControl: (id: string, error: unknown) => void,
	listeners: Iterable<() => void | Promise<void>>,
): Promise<void> {
	const adopt = session.permits("resolvePending");
	await step(managedText.resultRecovery, () => session.effects.relink(adopt));
	await step(managedText.acquisitionRecovery, () => session.actions.relink());
	await step(text.management, (current) => session.management.relink(reportControl, current));
	await step(text.link, () => session.typing.relink());
	session.drafts.resume();
	for (const listener of listeners) await step(text.link, listener);
}
