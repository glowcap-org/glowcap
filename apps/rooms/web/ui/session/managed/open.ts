// The startup anchor and saved strong fields choose actual authority. A local
// storage document or an inventory row cannot reconstruct an attached view.
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";
import { applicationModule } from "../../application.ts";
import type { ControllerSelection } from "../../controller/selection.ts";
import type { PageProjection } from "../../store/projection.ts";
import { bindLinkToPage } from "./link_binding.ts";
import { serverInUse } from "../../server_choice.ts";
import { ManagedRoomsSession } from "./session.ts";
import { tabIdentity, workspaceChosen } from "../../workspace_choice.ts";
import { ACTIVE_VIEW, type WorkspaceSnapshot } from "./model.ts";
import type {
	RoomsManagedApplication,
	RoomsManagedWorkspace,
} from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";

export class ManagedSessionStartupFailure extends LocalRefusal {
	constructor(cause: unknown, readonly cleanup: unknown) {
		super("session-startup-failed", { cause: [cause, cleanup] });
	}
}

/** Where opening a session failed: in this browser's own saved session, or
 * in the session another place serves, which this browser attaches to. */
export type OpenOrigin = "this-browser" | "attached";

/** Open this tab's session, as `selection` says. A failure is rejected as it
 * is, once its opening is let go of, and `failed` hears it first with where
 * it arose. */
export function openManagedSession(
	report: (source: string, error: unknown) => void,
	selection: "saved" | "local",
	failed: (error: unknown, origin: OpenOrigin) => void,
): Promise<{
	session: ManagedRoomsSession;
	local: boolean;
}> {
	const admission = document.documentElement.dataset.roomsSessionAdmission;
	const application = new (applicationModule().RoomsManagedApplication)(
		tabIdentity(),
		report,
		admission,
		serverInUse()?.base,
		workspaceChosen(),
	);
	return openOn(application, report, selection, failed);
}

/** Open the session `openManagedSession` opens, through `application`. */
export async function openOn(
	application: RoomsManagedApplication,
	report: (source: string, error: unknown) => void,
	selection: "saved" | "local",
	failed: (error: unknown, origin: OpenOrigin) => void,
): Promise<{
	session: ManagedRoomsSession;
	local: boolean;
}> {
	let origin: OpenOrigin = "this-browser";
	let custody: RoomsManagedWorkspace | null = null;
	let workspace: RoomsManagedWorkspace | null = null;
	let session: ManagedRoomsSession | null = null;
	let freed = false;
	const closeOpening = async () => {
		if (freed) return;
		if (session != null) await session.close();
		else {
			await application.close();
			workspace?.free();
			custody?.free();
			application.free();
		}
		freed = true;
	};
	try {
		const heldCustody: RoomsManagedWorkspace = await application.workspace();
		custody = heldCustody;
		const home: WorkspaceSnapshot = await heldCustody.snapshot();
		// Choosing a replacement must not depend on restoring the old peer.
		// Local custody keeps the saved selection until the new choice commits.
		const local = selection === "local" ||
			!home.intent.accesses?.some((row) => row.id === ACTIVE_VIEW && row.access != null);
		if (!local) origin = "attached";
		const heldWorkspace: RoomsManagedWorkspace = local
			? await application.workspace()
			: await application.savedWorkspace(ACTIVE_VIEW);
		workspace = heldWorkspace;
		session = new ManagedRoomsSession(application, heldWorkspace, heldCustody, report, local);
		await session.start();
		// Restore management by the separately saved strong fields. The active
		// view's inventory supplies no new control and cannot widen this set.
		if (selection === "saved") {
			session.initializeManagement(
				local,
				(home.intent.accesses ?? [])
					.filter((row) => row.control != null)
					.map((row) => row.id),
			);
		}
		return { session, local };
	} catch (error) {
		// Failed cleanup leaves the original owner available to the error's
		// recovery action; never open another Store while it still holds a lock.
		try {
			await closeOpening();
		} catch (cleanup) {
			throw new ManagedSessionStartupFailure(error, cleanup);
		}
		failed(error, origin);
		throw error;
	}
}

/** What a page shows of the session it opened. */
export interface OpeningPage {
	readonly projection: PageProjection;
	readonly controllerSelection: ControllerSelection;
}

/** Show `session` as `page`'s: which kind it is, and for one attached
 * elsewhere, its link bound to the page and the link to the session, read once
 * its link answers, on this link or a later one. A read that fails for another
 * reason stays on the page with its failure and the way to read it again.
 * Nothing here waits on the link, so a page whose link is lost while it opens
 * still opens, and the link's notice says why it waits. The link is bound only
 * now, because a bound link probes the observation that `start` registers.
 * Returns the stop. */
export function presentSession(
	page: OpeningPage,
	session: ManagedRoomsSession,
	report: (source: string, error: unknown) => void,
): () => void {
	const link = session.link;
	if (link == null) {
		page.controllerSelection.set({ kind: "local" });
		return () => {};
	}
	page.controllerSelection.set({ kind: "attached", sturdyref: null });
	const stopLink = bindLinkToPage(page.projection, link);
	let reading: Promise<void> | null = null;
	// A link replaced a read under way, which the loss may have ended
	// unanswered, so one more read follows it.
	let again = false;
	/** Read the session's link, unless the page shows it. A read under way is
	 * joined. It settles once the page shows what the read found. */
	const read = (): Promise<void> => {
		const shown = page.controllerSelection.getSnapshot();
		if (shown.kind !== "attached" || shown.sturdyref != null) return Promise.resolve();
		reading ??= session.request((workspace) => workspace.publish()).then((sturdyref: string) => {
			const now = page.controllerSelection.getSnapshot();
			if (now.kind === "attached" && now.sturdyref == null) {
				page.controllerSelection.set({ kind: "attached", sturdyref });
			}
		}, (error: unknown) => {
			// A read the link ended is read again over the next link.
			if (session.linkEnded(error)) return;
			report(managedText.capabilityExport, error);
			const now = page.controllerSelection.getSnapshot();
			if (now.kind === "attached" && now.sturdyref == null) {
				page.controllerSelection.set({
					kind: "attached",
					sturdyref: null,
					unread: { failure: error, readAgain: read },
				});
			}
		}).finally(() => {
			reading = null;
			if (again) {
				again = false;
				void read();
			}
		});
		return reading;
	};
	const stopReading = session.onRelink(() => {
		if (reading == null) void read();
		else again = true;
	});
	void read();
	return () => {
		stopReading();
		stopLink();
	};
}

/** Open the page over `session` with `open`. A page that does not open stops
 * what `stop` names and closes its session, so nothing dials behind the page
 * that says it did not open. */
export async function openOver(
	session: ManagedRoomsSession,
	stop: () => void,
	open: () => Promise<void>,
): Promise<void> {
	try {
		await open();
	} catch (error) {
		stop();
		try {
			await session.close();
		} catch (cleanup) {
			throw new ManagedSessionStartupFailure(error, cleanup);
		}
		throw error;
	}
}
