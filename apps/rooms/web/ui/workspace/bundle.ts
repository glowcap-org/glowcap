// The durable workspace document as a whole: exporting it as a bundle,
// importing one, clearing it, and rebuilding the projection from it at boot.
// Field-level reads and writes, validation, and the persistence loop stay in
// `workspace_state.ts`; this module only ever handles the complete document.

import { applicationModule, readSavedWorkspace as parseWorkspaceState, workspaceStorageKey } from "../application.ts";
import * as store from "../store.ts";
import { LS } from "../storage.ts";
import { directoryLivePhase, type DirId, dirId } from "../types.ts";
import type { RoomsControllerSelection, RoomsWorkspaceState, WorkspaceDirectory } from "../../../lib/rooms_state.ts";
import {
	installWorkspaceStatePersistence,
	persistPreparedWorkspace,
	retainWorkspace,
	validatedWorkspaceState,
} from "../workspace_state.ts";
import { announceWorkspaceReplacement } from "./sync.ts";
import type { RoomsPageContext } from "../page.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import { bundleAndChoiceIncomplete, bundleIncomplete, bundleSaveRefused } from "../../../lib/text/attached.ts";
import { reconcileDraftPreviews } from "../link_preview.ts";

export function encodeWorkspaceState(document: RoomsWorkspaceState, includeCapabilities = false): string {
	return applicationModule().exportWorkspace(JSON.stringify(document), includeCapabilities);
}

export function exportWorkspaceState(page: RoomsPageContext, includeCapabilities = false): string {
	page.workspace.persistenceControl?.flush();
	const current = validatedWorkspaceState(page);
	if ("refused" in current) {
		throw new Error(`the current Rooms workspace is not a valid state bundle: ${current.refused}`);
	}
	return encodeWorkspaceState(current.document, includeCapabilities);
}

export function importWorkspaceState(
	page: RoomsPageContext,
	raw: string,
	controllerOverride?: RoomsControllerSelection,
): string {
	const document = parseWorkspaceState(raw);
	if (document == null) return bundleIncomplete;
	const candidate = controllerOverride == null ? document : { ...document, controller: controllerOverride };
	const installed = controllerOverride == null ? document : parseWorkspaceState(JSON.stringify(candidate));
	if (installed == null) return bundleAndChoiceIncomplete;
	const encoded = JSON.stringify(installed);
	if (page.workspace.persistenceControl == null) installWorkspaceStatePersistence(page);
	const persistence = page.workspace.persistenceControl;
	if (persistence == null || !persistence.replace(encoded)) {
		return bundleSaveRefused;
	}
	persistence.stop();
	page.workspace.persistenceBlocked = false;
	retainWorkspace(page, installed);
	announceWorkspaceReplacement();
	return "";
}

export function clearWorkspaceState(page: RoomsPageContext): boolean {
	if (page.workspace.persistenceControl == null) installWorkspaceStatePersistence(page);
	const persistence = page.workspace.persistenceControl;
	if (persistence == null || !persistence.clear()) return false;
	persistence.stop();
	page.workspace.persistenceBlocked = true;
	retainWorkspace(page, null);
	announceWorkspaceReplacement();
	return true;
}

/** Rebuild the durable workspace projection before any directory starts dialing. */
export function restoreWorkspaceState(
	page: RoomsPageContext,
	resolve: (locator: string) => DirId | null,
	restoreSelection = true,
	read: (raw: string | null) => RoomsWorkspaceState | null = parseWorkspaceState,
): { foreignLocators: string[]; savedHomeLocator: string | null } {
	const refuseRestore = (reason: string) => {
		page.workspace.persistenceBlocked = true;
		store.noteTrouble(page.projection, "workspace persistence", reason);
		return { foreignLocators: [], savedHomeLocator: null };
	};
	const raw = LS.get(workspaceStorageKey());
	const document = read(raw);
	if (raw != null && document == null) {
		refuseRestore("the saved workspace was invalid and was not restored");
	}
	retainWorkspace(page, document);
	if (document == null) return { foreignLocators: [], savedHomeLocator: null };
	const directories = [...document.session.directories].sort((left, right) => Number(right.home) - Number(left.home));
	const resolvedDirectories: { saved: WorkspaceDirectory; id: DirId }[] = [];
	const resolvedIds = new Set<DirId>();
	for (const directory of directories) {
		let resolved: DirId | null;
		try {
			resolved = resolve(directory.locator);
		} catch (error) {
			return refuseRestore(refusalText(error));
		}
		if (resolved == null || resolved !== dirId(directory.id) || resolvedIds.has(resolved)) {
			return refuseRestore("a saved directory route did not name its recorded authority");
		}
		resolvedIds.add(resolved);
		resolvedDirectories.push({ saved: directory, id: resolved });
	}
	for (const { saved, id } of resolvedDirectories) {
		store.openDir(page.projection, id, saved.locator);
		const reached = document.controller.kind !== "attached" && saved.reached === true;
		store.patchDir(page.projection, id, {
			requestedNick: saved.nick,
			nick: "",
			standing: saved.standing,
			reached,
			...directoryLivePhase(reached, false, undefined),
		});
		if (saved.home) store.setHomeDir(page.projection, id);
	}
	const drafts = new Map<string, store.Draft>();
	const byPersistentId = new Map<string, string>();
	for (const conversation of document.session.conversations) {
		const directory = dirId(conversation.directory);
		const restored = conversation.kind === "direct"
			? store.restoreDm(
				page.projection,
				directory,
				conversation.peer,
				conversation.peerRegistrationId,
				conversation.id,
				conversation.closed,
			)
			: store.ensureRoom(page.projection, directory, conversation.name, {
				persistId: conversation.id,
				key: conversation.held ? `held:${conversation.id}` : undefined,
				held: conversation.held,
				membership: "unavailable",
				...(conversation.reconnect === "manual" ? { reconnect: "manual" as const } : {}),
				link: conversation.link,
				manager: conversation.manager,
				steward: conversation.steward,
				publicationId: conversation.publicationId,
				bridgeIntent: conversation.bridgeIntent,
			});
		if (restored == null) throw new Error("validated workspace conversation could not be restored");
		if (conversation.kind === "room" && restored.type === "room" && restored.standing !== conversation.standing) {
			store.setRoomStanding(page.projection, restored.key, conversation.standing);
		}
		if (conversation.draft !== "") {
			drafts.set(restored.key, {
				text: conversation.draft,
				files: [],
				previews: reconcileDraftPreviews([], conversation.draft, () => page.projection.allocItemId()),
			});
		}
		byPersistentId.set(conversation.id, restored.key);
	}
	page.projection.set({
		drafts,
		activeKey: restoreSelection && document.session.active != null
			? byPersistentId.get(document.session.active) ?? null
			: null,
		standing: document.session.standing,
		theme: document.view.theme,
		notifyOn: document.view.notifyOn,
		ignored: new Set(document.session.ignored),
		invites: document.session.invitations.map((invitation) => ({
			id: invitation.id,
			dir: dirId(invitation.directory),
			locator: invitation.locator,
			nick: invitation.nick,
			way: "link" as const,
			label: invitation.label,
			from: invitation.from,
			link: invitation.link,
		})),
		railOpen: document.view.railOpen,
		rosterOpen: document.view.rosterOpen,
		settingsTab: document.view.settingsTab,
		opsPane: document.view.opsPane,
		keepHistory: document.session.keepHistory,
		remembered: { ...document.session.join },
	});
	const home = page.projection.get().homeDir;
	if (page.workspace.retained.controller.kind === "hosted") {
		page.workspace.retained = { ...page.workspace.retained, controller: { kind: "local" } };
		// Withdraw the dead tab's selector in the already-admitted document.
		// This choice must survive another reload even before a runtime opens.
		persistPreparedWorkspace(page, { ...document, controller: { kind: "local" } });
	}
	return {
		foreignLocators: [...page.projection.get().dirs.values()]
			.filter((directory) => directory.id !== home)
			.map((directory) => directory.locator),
		savedHomeLocator: document.session.directories.find((directory) => directory.home)?.locator ?? null,
	};
}
