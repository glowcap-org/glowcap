// The startup anchor and saved strong fields choose actual authority. A local
// storage document or an inventory row cannot reconstruct an attached view.
import { applicationModule } from "../../application.ts";
import { managedSessionText } from "../../../../lib/text/managed_session.ts";
import { ManagedRoomsSession } from "./session.ts";
import type { WorkspaceSnapshot } from "./model.ts";
import type { RoomsManagedWorkspace } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";

export const ACTIVE_VIEW = "active-view";
const TAB = "rooms.managed-tab";

export class ManagedSessionStartupFailure extends Error {
	constructor(cause: unknown, readonly cleanup: unknown) {
		super(managedSessionText.startupRecovery, { cause });
	}
}

export function tabIdentity(): string {
	let id = sessionStorage.getItem(TAB);
	if (id == null) {
		id = crypto.randomUUID();
		sessionStorage.setItem(TAB, id);
	}
	if (!/^[a-zA-Z0-9-]{1,64}$/.test(id)) throw new Error("This tab has an invalid workspace identity");
	return id;
}

export async function openManagedSession(
	report: (source: string, error: unknown) => void,
	selection: "saved" | "local" = "saved",
): Promise<{
	session: ManagedRoomsSession;
	local: boolean;
}> {
	const admission = document.documentElement.dataset.roomsSessionAdmission;
	const application = new (applicationModule().RoomsManagedApplication)(tabIdentity(), report, admission);
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
		// Choosing a replacement must not depend on restoring the old peer. status-allow: replacement state identity
		// Local custody keeps the saved selection until the new choice commits.
		const local = selection === "local" ||
			!home.intent.accesses?.some((row) => row.id === ACTIVE_VIEW && row.access != null);
		const heldWorkspace: RoomsManagedWorkspace = local
			? await application.workspace()
			: await application.savedWorkspace(ACTIVE_VIEW);
		workspace = heldWorkspace;
		session = new ManagedRoomsSession(application, heldWorkspace, heldCustody, report);
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
		throw error;
	}
}
