// The startup anchor and saved strong fields choose actual authority. A local
// storage document or an inventory row cannot reconstruct an attached view.
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import { applicationModule } from "../../application.ts";
import { serverInUse } from "../../server_choice.ts";
import { ManagedRoomsSession } from "./session.ts";
import { type PageStorage, sessionArea } from "../../page_storage.ts";
import type { WorkspaceSnapshot } from "./model.ts";
import type { RoomsManagedWorkspace } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";

const ACTIVE_VIEW = "active-view";
const TAB = "rooms.managed-tab";

export class ManagedSessionStartupFailure extends LocalRefusal {
	constructor(cause: unknown, readonly cleanup: unknown) {
		super("session-startup-failed", { cause: [cause, cleanup] });
	}
}

/** This tab's workspace identity, minted on first use and kept across the
 * tab's reloads. A browser that refuses to keep it is refused here: a session
 * opened under an identity nobody kept could never be found again. */
export function tabIdentity(storage: PageStorage = sessionArea): string {
	let id = storage.read(TAB);
	if (id == null) {
		id = crypto.randomUUID();
		const refused = storage.write(TAB, id);
		if (refused != null) throw refused;
	}
	if (!/^[a-zA-Z0-9-]{1,64}$/.test(id)) throw new LocalRefusal("tab-identity-invalid");
	return id;
}

/** This tab's identity if it already has one, without minting one. Null on a
 * fresh tab, and on a tab whose browser refuses to read it. */
export function keptTabIdentity(storage: PageStorage = sessionArea): string | null {
	return storage.read(TAB);
}

export async function openManagedSession(
	report: (source: string, error: unknown) => void,
	selection: "saved" | "local" = "saved",
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
	);
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
		throw error;
	}
}
