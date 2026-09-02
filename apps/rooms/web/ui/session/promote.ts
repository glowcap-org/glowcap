// In-place promote: this tab becomes the session host without a reload.
//
// Reload would mint a new wasm Host and a second member. Share drains local
// directory sessions, binds the actor onto this Host, and remounts the same
// attached view the CapTP path uses — through an in-process remote, because
// a Host keeps one session per peer and this tab cannot dial itself.

import { retainCleanupFailures } from "@glowcap/runtime";
import type { CapabilitySetEventSource } from "../ops/capability_set_events.ts";
import type { RoomsBrowserController } from "../controller/browser.ts";
import type { RoomsSessionController } from "../controller/session.ts";
import type { RoomsPageContext } from "../page.ts";
import { setWorkspaceControllerSelection, workspaceControllerSelection } from "../workspace_state.ts";
import { reconnectHeldDirectories } from "../net/held_directories.ts";
import { directoryLocator } from "../prefs.ts";
import { AttachedRoomsController } from "./attached.ts";
import { AttachedSessionFiles } from "./attached_files.ts";
import { createAttachedRoomsSession } from "./attached_session.ts";
import { type HostedRoomsSession, hostRoomsSession } from "./host.ts";
import { AttachedSessionProjection } from "./projection.ts";

export interface PromoteLocalSession {
	readonly page: RoomsPageContext;
	readonly browser: RoomsBrowserController;
	readonly capabilityEvents: CapabilitySetEventSource;
	stopLocal(): void | Promise<void>;
	remount(session: RoomsSessionController): void;
}

async function abandonHosted(page: RoomsPageContext, hosted: HostedRoomsSession): Promise<void> {
	try {
		await hosted.close();
	} finally {
		if (workspaceControllerSelection(page).kind === "hosted") {
			setWorkspaceControllerSelection(page, { kind: "local" });
		}
		reconnectHeldDirectories(page);
	}
}

export async function promoteLocalSessionToHosted(options: PromoteLocalSession): Promise<string> {
	const { page, browser, capabilityEvents } = options;
	if (workspaceControllerSelection(page).kind !== "local") {
		return "This browser can share only a local session.";
	}
	let hosted;
	try {
		hosted = await hostRoomsSession(page);
	} catch (error) {
		return error instanceof Error ? error.message : String(error);
	}
	if (!setWorkspaceControllerSelection(page, { kind: "hosted", sturdyref: hosted.sturdyref })) {
		const refusal = new Error("This browser refused to save that it is hosting this session.");
		await retainCleanupFailures(refusal, [() => abandonHosted(page, hosted)]);
		return refusal.message;
	}
	const controller = new AttachedRoomsController(hosted.remote, () => hosted.close());
	try {
		await controller.start();
	} catch (error) {
		await retainCleanupFailures(error, [() => abandonHosted(page, hosted)]);
		return error instanceof Error ? error.message : String(error);
	}
	const defaultDirectoryLocator = await directoryLocator();
	try {
		await options.stopLocal();
	} catch {
		// best-effort: the hosted controller is the owner now; a leftover local
		// archive peer must not block remounting the session that is already live.
	}
	try {
		page.attachedSession.hold(controller);
		const files = new AttachedSessionFiles(controller, page.projection);
		const projection = new AttachedSessionProjection(page, files, capabilityEvents);
		const stopProjection = projection.bind(controller);
		const session = createAttachedRoomsSession(page, browser, controller, files, {
			defaultDirectoryLocator,
			capabilityEvents,
		});
		addEventListener("pagehide", () => {
			page.attachedSession.release();
			stopProjection();
			files.close();
			void hosted.close();
		}, { once: true });
		options.remount(session);
		return "";
	} catch (error) {
		page.attachedSession.release();
		await retainCleanupFailures(error, [() => abandonHosted(page, hosted)]);
		return error instanceof Error ? error.message : String(error);
	}
}
