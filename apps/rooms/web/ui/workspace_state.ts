// The durable workspace projection for the Rooms browser application.
//
// This document is deliberately not a snapshot of live runtime state. It keeps
// the choices a reader expects to survive a refresh and nothing that belongs to
// a CapTP connection: no Session, Ref, Room, promise, timer, File, object URL,
// or transient presence row. Boot projects these records back into the store;
// the network layer then realizes them as fresh sessions and references.

import * as z from "zod/mini";
import * as store from "./store.ts";
import { LS } from "./storage.ts";
import { type DirId, dirId, type OpsCap } from "./types.ts";
import {
	MAX_WORKSPACE_CONVERSATIONS,
	MAX_WORKSPACE_DIRECTORIES,
	MAX_WORKSPACE_DOCUMENT_CHARS,
	MAX_WORKSPACE_IGNORED_NAMES,
	MAX_WORKSPACE_INVITATIONS,
	MAX_WORKSPACE_OPERATION_CREDENTIALS,
	MAX_WORKSPACE_PEERING,
	parseWorkspaceOperationCredentials,
	parseWorkspaceState,
	peeringIntentsForOperations,
	redactWorkspaceCapabilities,
	ROOMS_SESSION_STATE_VERSION,
	type RoomsControllerSelection,
	type RoomsWorkspaceState,
	RoomsWorkspaceStateSchema,
	WORKSPACE_STATE_KEY,
	WORKSPACE_STATE_VERSION,
	type WorkspaceConversation,
	type WorkspaceDirectory,
	type WorkspaceOperationCredential,
	type WorkspacePeeringIntent,
	WorkspacePeeringIntentSchema,
} from "../../lib/rooms_state.ts";
import { announceWorkspaceReplacement } from "./workspace/sync.ts";

export {
	parseWorkspaceState,
	type RoomsWorkspaceState,
	WORKSPACE_STATE_KEY,
	WORKSPACE_STATE_VERSION,
} from "../../lib/rooms_state.ts";

const SAVE_COALESCE_MS = 200;

interface RetainedWorkspaceState {
	controller: RoomsControllerSelection;
	dmMode: RoomsWorkspaceState["session"]["dmMode"];
	vizOverride: string;
	operations: WorkspaceOperationCredential[];
	archivePeer: string | null;
	peering: WorkspacePeeringIntent[];
}

const EMPTY_RETAINED: RetainedWorkspaceState = {
	controller: { kind: "none" },
	dmMode: "webrtc",
	vizOverride: "",
	operations: [],
	archivePeer: null,
	peering: [],
};

let retained: RetainedWorkspaceState = { ...EMPTY_RETAINED, operations: [] };
let persistenceBlocked = false;
let persistenceControl: { flush(): boolean; stop(): void } | null = null;

function retain(document: RoomsWorkspaceState | null): void {
	retained = document == null ? { ...EMPTY_RETAINED, operations: [] } : {
		controller: document.controller,
		dmMode: document.session.dmMode,
		vizOverride: document.session.vizOverride,
		operations: [...document.session.capabilities.operations],
		archivePeer: document.session.capabilities.archivePeer,
		peering: [...document.session.peering],
	};
}

export function workspaceStateOf(state: Readonly<store.State>): RoomsWorkspaceState {
	return {
		version: WORKSPACE_STATE_VERSION,
		controller: retained.controller,
		session: {
			version: ROOMS_SESSION_STATE_VERSION,
			directories: [...state.dirs.values()].map((directory) => ({
				id: directory.id,
				locator: directory.locator,
				home: directory.id === state.homeDir,
				nick: directory.requestedNick,
				standing: directory.standing,
			})),
			conversations: [...state.convs.values()].map((conversation): WorkspaceConversation => {
				const draft = state.drafts.get(conversation.key)?.text ?? "";
				if (conversation.type === "dm") {
					return {
						kind: "direct",
						id: conversation.persistId,
						directory: conversation.dir,
						peer: conversation.id,
						peerRegistrationId: conversation.peerRegistrationId,
						closed: conversation.line === "closed",
						draft,
					};
				}
				return {
					kind: "room",
					id: conversation.persistId,
					directory: conversation.dir,
					name: conversation.id,
					held: conversation.held,
					...(conversation.link == null ? {} : { link: conversation.link }),
					...(conversation.steward == null ? {} : { steward: conversation.steward }),
					...(conversation.publicationId == null ? {} : { publicationId: conversation.publicationId }),
					...(Object.hasOwn(conversation, "irc") ? { irc: conversation.irc } : {}),
					standing: conversation.standing,
					draft,
				};
			}),
			invitations: state.invites.filter((invitation) => invitation.way === "link").map((invitation) => ({
				kind: "room-link" as const,
				id: invitation.id,
				directory: invitation.dir,
				locator: invitation.locator ?? "",
				nick: invitation.nick ?? "",
				label: invitation.label,
				from: invitation.from,
				link: invitation.link,
			})),
			active: state.activeKey == null ? null : state.convs.get(state.activeKey)?.persistId ?? null,
			standing: state.standing,
			ignored: [...state.ignored],
			keepHistory: state.keepHistory,
			join: { ...state.remembered },
			dmMode: retained.dmMode,
			vizOverride: retained.vizOverride,
			capabilities: {
				operations: retained.operations,
				archivePeer: retained.archivePeer,
			},
			peering: retained.peering,
		},
		view: {
			theme: state.theme,
			notifyOn: state.notifyOn,
			railOpen: state.railOpen,
			rosterOpen: state.rosterOpen,
			settingsTab: state.settingsTab,
			opsPane: state.opsPane,
		},
	};
}

export function workspaceControllerSelection(): RoomsControllerSelection {
	return retained.controller;
}

/** An attached checkpoint is the authority for shared settings and bearers;
 * the browser envelope keeps only its own controller selection. */
export function adoptAttachedSessionState(session: RoomsWorkspaceState["session"]): void {
	retained = {
		...retained,
		dmMode: session.dmMode,
		vizOverride: session.vizOverride,
		operations: [...session.capabilities.operations],
		archivePeer: session.capabilities.archivePeer,
		peering: [...session.peering],
	};
}

export function setWorkspaceControllerSelection(controller: RoomsControllerSelection): boolean {
	const prior = retained;
	const wasBlocked = persistenceBlocked;
	retained = { ...retained, controller };
	// Choosing a controller is an explicit replacement act. It may recover from
	// an obsolete or invalid saved document that boot correctly refused to
	// overwrite on behalf of unrelated store traffic.
	persistenceBlocked = false;
	if (persistCurrentWorkspace()) return true;
	retained = prior;
	persistenceBlocked = wasBlocked;
	return false;
}

function validatedWorkspaceState(): RoomsWorkspaceState | null {
	const document = workspaceStateOf(store.get());
	if (
		document.session.directories.length > MAX_WORKSPACE_DIRECTORIES ||
		document.session.conversations.length > MAX_WORKSPACE_CONVERSATIONS ||
		document.session.invitations.length > MAX_WORKSPACE_INVITATIONS ||
		document.session.ignored.length > MAX_WORKSPACE_IGNORED_NAMES ||
		document.session.capabilities.operations.length > MAX_WORKSPACE_OPERATION_CREDENTIALS ||
		document.session.peering.length > MAX_WORKSPACE_PEERING
	) return null;
	const parsed = z.safeParse(RoomsWorkspaceStateSchema, document);
	return parsed.success ? parsed.data : null;
}

function encodedWorkspaceState(): string | null {
	const document = validatedWorkspaceState();
	if (document == null) return null;
	const encoded = JSON.stringify(document);
	return encoded.length <= MAX_WORKSPACE_DOCUMENT_CHARS ? encoded : null;
}

function persistCurrentWorkspace(): boolean {
	if (persistenceBlocked) return false;
	if (persistenceControl != null) return persistenceControl.flush();
	const encoded = encodedWorkspaceState();
	return encoded != null && LS.set(WORKSPACE_STATE_KEY, encoded);
}

export function workspaceConnectionSettings(): { dmMode: "webrtc" | "relay"; vizOverride: string } {
	const document = parseWorkspaceState(LS.get(WORKSPACE_STATE_KEY));
	return document == null
		? { dmMode: "webrtc", vizOverride: "" }
		: { dmMode: document.session.dmMode, vizOverride: document.session.vizOverride };
}

export function setWorkspaceConnectionSettings(next: { dmMode?: "webrtc" | "relay"; vizOverride?: string }): boolean {
	const prior = retained;
	retained = { ...retained, ...next };
	if (persistCurrentWorkspace()) return true;
	retained = prior;
	return false;
}

export function rememberedWorkspaceOperation(capability: OpsCap, scope: string): string | null {
	return retained.operations.find((row) => row.capability === capability && row.scope === scope)?.swiss ?? null;
}

export function rememberedWorkspaceOperations(): readonly WorkspaceOperationCredential[] {
	return retained.operations;
}

export function workspacePeeringIntents(): readonly WorkspacePeeringIntent[] {
	return retained.peering;
}

/** Add one restartable publication intent before its runtime lease is made. */
export function addWorkspacePeeringIntent(intent: WorkspacePeeringIntent): boolean {
	const parsed = z.safeParse(WorkspacePeeringIntentSchema, intent);
	if (!parsed.success || retained.peering.some((entry) => entry.id === intent.id)) return false;
	const prior = retained;
	retained = { ...retained, peering: [...retained.peering, parsed.data] };
	if (persistCurrentWorkspace()) return true;
	retained = prior;
	return false;
}

/** Remove a publication intent. Runtime lease cleanup remains the peering module's job. */
export function removeWorkspacePeeringIntent(id: string): boolean {
	if (!retained.peering.some((entry) => entry.id === id)) return true;
	const prior = retained;
	retained = { ...retained, peering: retained.peering.filter((entry) => entry.id !== id) };
	if (persistCurrentWorkspace()) return true;
	retained = prior;
	return false;
}

/** Remove publications whose source conversation is being forgotten. */
export function removeWorkspacePeeringForSource(source: string): boolean {
	const next = retained.peering.filter((intent) => intent.source !== source);
	if (next.length === retained.peering.length) return true;
	const prior = retained;
	retained = { ...retained, peering: next };
	if (persistCurrentWorkspace()) return true;
	retained = prior;
	return false;
}

/** Drop all local publication intents when their operator capability is explicitly forgotten. */
export function clearWorkspacePeering(): boolean {
	if (retained.peering.length === 0) return true;
	const prior = retained;
	retained = { ...retained, peering: [] };
	if (persistCurrentWorkspace()) return true;
	retained = prior;
	return false;
}

export function setRememberedWorkspaceOperations(operations: readonly WorkspaceOperationCredential[]): boolean {
	const normalized = parseWorkspaceOperationCredentials(operations);
	if (normalized == null) return false;
	const prior = retained;
	const wasBlocked = persistenceBlocked;
	const peering = peeringIntentsForOperations(normalized, retained.peering);
	retained = { ...retained, operations: normalized, peering };
	// Saving the complete capability set is an explicit replacement act. It may
	// recover from an invalid saved document that boot preserved rather than
	// silently overwriting from an unrelated store update.
	persistenceBlocked = false;
	if (persistCurrentWorkspace()) return true;
	retained = prior;
	persistenceBlocked = wasBlocked;
	return false;
}

export function setRememberedWorkspaceOperation(
	capability: OpsCap,
	scope: string,
	swiss: string | null,
): boolean {
	const normalized = swiss == null
		? null
		: parseWorkspaceOperationCredentials([{ capability, scope, swiss }])?.[0]?.swiss ?? null;
	if (swiss != null && normalized == null) return false;
	const existing = retained.operations.find((row) => row.capability === capability && row.scope === scope)?.swiss ??
		null;
	if (existing === normalized) return true;
	const operations = retained.operations.filter((row) => row.capability !== capability || row.scope !== scope);
	if (normalized != null) operations.push({ capability, scope, swiss: normalized });
	const prior = retained;
	retained = { ...retained, operations };
	if (persistCurrentWorkspace()) return true;
	retained = prior;
	return false;
}

export function rememberedWorkspaceArchivePeer(): string | null {
	return retained.archivePeer;
}

export function setRememberedWorkspaceArchivePeer(sturdyref: string | null): boolean {
	if (retained.archivePeer === sturdyref) return true;
	const prior = retained;
	retained = { ...retained, archivePeer: sturdyref };
	if (persistCurrentWorkspace()) return true;
	retained = prior;
	return false;
}

export function encodeWorkspaceState(document: RoomsWorkspaceState, includeCapabilities = false): string {
	const parsed = z.safeParse(RoomsWorkspaceStateSchema, document);
	if (!parsed.success) throw new Error("the current Rooms workspace is not a valid state bundle");
	const exported = includeCapabilities ? parsed.data : redactWorkspaceCapabilities(parsed.data);
	const encoded = JSON.stringify(exported);
	if (encoded.length > MAX_WORKSPACE_DOCUMENT_CHARS) throw new Error("the Rooms state is too large to export");
	return encoded;
}

export function exportWorkspaceState(includeCapabilities = false): string {
	persistenceControl?.flush();
	const current = validatedWorkspaceState();
	if (current == null) throw new Error("the current Rooms workspace is not a valid state bundle");
	return encodeWorkspaceState(current, includeCapabilities);
}

export function importWorkspaceState(raw: string, controllerOverride?: RoomsControllerSelection): string {
	const document = parseWorkspaceState(raw);
	if (document == null) return "That file is not a complete Rooms state bundle.";
	const candidate = controllerOverride == null ? document : { ...document, controller: controllerOverride };
	const accepted = z.safeParse(RoomsWorkspaceStateSchema, candidate);
	if (!accepted.success) return "That file and session choice do not form a complete Rooms state bundle.";
	const installed = accepted.data;
	const encoded = JSON.stringify(installed);
	persistenceControl?.stop();
	if (!LS.set(WORKSPACE_STATE_KEY, encoded)) {
		installWorkspaceStatePersistence();
		return "This browser refused to save the imported Rooms state.";
	}
	persistenceBlocked = false;
	retain(installed);
	announceWorkspaceReplacement();
	return "";
}

export function clearWorkspaceState(): boolean {
	persistenceControl?.stop();
	persistenceBlocked = true;
	retain(null);
	let cleared = LS.remove(WORKSPACE_STATE_KEY);
	try {
		for (const key of Object.keys(localStorage)) {
			if (key.startsWith("rooms.") && key !== WORKSPACE_STATE_KEY) localStorage.removeItem(key);
		}
	} catch {
		cleared = false;
	}
	if (cleared) announceWorkspaceReplacement();
	return cleared;
}

/** Rebuild the durable workspace projection before any directory starts dialing. */
export function restoreWorkspaceState(
	resolve: (locator: string) => DirId | null,
	restoreSelection = true,
): { foreignLocators: string[]; savedHomeLocator: string | null } {
	const refuseRestore = (reason: string) => {
		persistenceBlocked = true;
		store.noteTrouble("workspace persistence", reason);
		return { foreignLocators: [], savedHomeLocator: null };
	};
	const raw = LS.get(WORKSPACE_STATE_KEY);
	const document = parseWorkspaceState(raw);
	if (raw != null && document == null) {
		refuseRestore("the saved workspace was invalid and was not restored");
	}
	retain(document);
	if (document == null) return { foreignLocators: [], savedHomeLocator: null };
	const directories = [...document.session.directories].sort((left, right) => Number(right.home) - Number(left.home));
	const resolvedDirectories: { saved: WorkspaceDirectory; id: DirId }[] = [];
	const resolvedIds = new Set<DirId>();
	for (const directory of directories) {
		let resolved: DirId | null;
		try {
			resolved = resolve(directory.locator);
		} catch (error) {
			return refuseRestore(error instanceof Error ? error.message : String(error));
		}
		if (resolved == null || resolved !== dirId(directory.id) || resolvedIds.has(resolved)) {
			return refuseRestore("a saved directory route did not name its recorded authority");
		}
		resolvedIds.add(resolved);
		resolvedDirectories.push({ saved: directory, id: resolved });
	}
	for (const { saved, id } of resolvedDirectories) {
		store.openDir(id, saved.locator);
		store.patchDir(id, {
			requestedNick: saved.nick,
			nick: "",
			standing: saved.standing,
			reached: true,
			session: "reconnecting",
		});
		if (saved.home) store.setHomeDir(id);
	}
	const drafts = new Map<string, store.Draft>();
	const byPersistentId = new Map<string, string>();
	for (const conversation of document.session.conversations) {
		const directory = dirId(conversation.directory);
		const restored = conversation.kind === "direct"
			? store.restoreDm(
				directory,
				conversation.peer,
				conversation.peerRegistrationId,
				conversation.id,
				conversation.closed,
			)
			: store.ensureRoom(directory, conversation.name, {
				persistId: conversation.id,
				key: conversation.held ? `held:${conversation.id}` : undefined,
				held: conversation.held,
				link: conversation.link,
				steward: conversation.steward,
				publicationId: conversation.publicationId,
				irc: conversation.irc,
			});
		if (restored == null) throw new Error("validated workspace conversation could not be restored");
		if (conversation.kind === "room" && restored.type === "room" && restored.standing !== conversation.standing) {
			store.setRoomStanding(restored.key, conversation.standing);
		}
		if (conversation.draft !== "") drafts.set(restored.key, { text: conversation.draft, files: [] });
		byPersistentId.set(conversation.id, restored.key);
	}
	store.set({
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
	const home = store.get().homeDir;
	return {
		foreignLocators: [...store.get().dirs.values()]
			.filter((directory) => directory.id !== home)
			.map((directory) => directory.locator),
		savedHomeLocator: document.session.directories.find((directory) => directory.home)?.locator ?? null,
	};
}

/** Persist only when the durable projection changes. Store traffic includes
 * every message, presence tick, and transfer update; comparing the bounded
 * projection keeps those transient writes off browser storage. */
export function installWorkspaceStatePersistence(): () => void {
	if (persistenceControl != null) return () => {};
	let last = LS.get(WORKSPACE_STATE_KEY) ?? "";
	let dirty = false;
	let stopped = false;
	let oversized = false;
	let storageFailureReported = false;
	let retryDelay = 1000;
	let saveTimer: ReturnType<typeof setTimeout> | null = null;
	let retryTimer: ReturnType<typeof setTimeout> | null = null;
	const settleRetry = () => {
		if (retryTimer != null) clearTimeout(retryTimer);
		retryTimer = null;
		storageFailureReported = false;
		retryDelay = 1000;
	};
	const commit = (): boolean => {
		if (stopped || persistenceBlocked) return false;
		if (saveTimer != null) {
			clearTimeout(saveTimer);
			saveTimer = null;
		}
		dirty = false;
		const encoded = encodedWorkspaceState();
		if (encoded == null) {
			if (!oversized) {
				oversized = true;
				store.noteTrouble("workspace persistence", "the Rooms workspace exceeds a persistence bound");
			}
			return false;
		}
		if (encoded === last) {
			settleRetry();
			return true;
		}
		oversized = false;
		if (!LS.set(WORKSPACE_STATE_KEY, encoded)) {
			if (!storageFailureReported) {
				storageFailureReported = true;
				store.noteTrouble("workspace persistence", "this browser refused to save the Rooms workspace");
			}
			if (retryTimer == null) {
				retryTimer = setTimeout(() => {
					retryTimer = null;
					commit();
				}, retryDelay);
				retryDelay = Math.min(retryDelay * 2, 30_000);
			}
			return false;
		}
		settleRetry();
		last = encoded;
		return true;
	};
	const schedule = () => {
		if (stopped || persistenceBlocked) return;
		dirty = true;
		if (saveTimer == null) saveTimer = setTimeout(commit, SAVE_COALESCE_MS);
	};
	const unsubscribe = store.subscribe(() => {
		schedule();
	});
	const flushOnHide = () => {
		if (dirty) commit();
	};
	addEventListener("pagehide", flushOnHide);
	if (typeof document !== "undefined") document.addEventListener("visibilitychange", flushOnHide);
	const stop = () => {
		if (stopped) return;
		stopped = true;
		unsubscribe();
		removeEventListener("pagehide", flushOnHide);
		if (typeof document !== "undefined") document.removeEventListener("visibilitychange", flushOnHide);
		if (saveTimer != null) clearTimeout(saveTimer);
		if (retryTimer != null) clearTimeout(retryTimer);
		if (persistenceControl?.stop === stop) persistenceControl = null;
	};
	persistenceControl = { flush: commit, stop };
	schedule();
	return stop;
}
