// The durable workspace projection for the Rooms browser application.
//
// This document is deliberately not a snapshot of live runtime state. It keeps
// the choices a reader expects to survive a refresh and nothing that belongs to
// a CapTP connection: no Session, Ref, Room, promise, timer, File, object URL,
// or transient presence row. Boot projects these records back into the store;
// the network layer then realizes them as fresh sessions and references.

import * as store from "./store.ts";
import { LS } from "./storage.ts";
import { isSessionConv, type OpsCap } from "./types.ts";
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
	ROOMS_SESSION_STATE_VERSION,
	type RoomsControllerSelection,
	type RoomsWorkspaceState,
	RoomsWorkspaceStateSchema,
	WORKSPACE_STATE_KEY,
	WORKSPACE_STATE_VERSION,
	type WorkspaceConversation,
	type WorkspaceOperationCredential,
	type WorkspacePeeringIntent,
	WorkspacePeeringIntentSchema,
} from "../../lib/rooms_state.ts";
import * as z from "zod/mini";
import type { RoomsPageContext } from "./page.ts";
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

/** In-memory working copy of the durable workspace document for one page. */
export class PageWorkspace {
	retained: RetainedWorkspaceState = { ...EMPTY_RETAINED, operations: [] };
	persistenceBlocked = false;
	persistenceControl: { flush(): boolean; stop(): void } | null = null;
}

/** Adopt `document` as the retained working copy, or empty it. Exported for
 * `workspace/bundle.ts`, which installs and clears whole documents. */
export function retainWorkspace(page: RoomsPageContext, document: RoomsWorkspaceState | null): void {
	page.workspace.retained = document == null ? { ...EMPTY_RETAINED, operations: [] } : {
		controller: document.controller,
		dmMode: document.session.dmMode,
		vizOverride: document.session.vizOverride,
		operations: [...document.session.capabilities.operations],
		archivePeer: document.session.capabilities.archivePeer,
		peering: [...document.session.peering],
	};
}

export function workspaceStateOf(page: RoomsPageContext, state: Readonly<store.State>): RoomsWorkspaceState {
	const selected = state.activeKey == null ? null : state.convs.get(state.activeKey) ?? null;
	const active = selected == null || !isSessionConv(selected) ? null : selected.persistId;
	return {
		version: WORKSPACE_STATE_VERSION,
		controller: page.workspace.retained.controller,
		session: {
			version: ROOMS_SESSION_STATE_VERSION,
			directories: [...state.dirs.values()].map((directory) => ({
				id: directory.id,
				locator: directory.locator,
				home: directory.id === state.homeDir,
				reached: directory.reached,
				nick: directory.requestedNick,
				standing: directory.standing,
			})),
			conversations: [...state.convs.values()].flatMap((conversation): WorkspaceConversation[] => {
				if (!isSessionConv(conversation)) return [];
				const draft = state.drafts.get(conversation.key)?.text ?? "";
				if (conversation.type === "dm") {
					return [{
						kind: "direct",
						id: conversation.persistId,
						directory: conversation.dir,
						peer: conversation.id,
						peerRegistrationId: conversation.peerRegistrationId,
						closed: conversation.line === "closed",
						draft,
					}];
				}
				return [{
					kind: "room",
					id: conversation.persistId,
					directory: conversation.dir,
					name: conversation.id,
					held: conversation.held,
					...(conversation.link == null ? {} : { link: conversation.link }),
					...(conversation.manager == null ? {} : { manager: conversation.manager }),
					...(conversation.steward == null ? {} : { steward: conversation.steward }),
					...(conversation.publicationId == null ? {} : { publicationId: conversation.publicationId }),
					...(conversation.reconnect === "manual" ? { reconnect: "manual" as const } : {}),
					...(Object.hasOwn(conversation, "bridgeIntent") ? { bridgeIntent: conversation.bridgeIntent } : {}),
					standing: conversation.standing,
					draft,
				}];
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
			active,
			standing: state.standing,
			ignored: [...state.ignored],
			keepHistory: state.keepHistory,
			join: { ...state.remembered },
			dmMode: page.workspace.retained.dmMode,
			vizOverride: page.workspace.retained.vizOverride,
			capabilities: {
				operations: page.workspace.retained.operations,
				archivePeer: page.workspace.retained.archivePeer,
			},
			peering: page.workspace.retained.peering,
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

export function workspaceControllerSelection(page: RoomsPageContext): RoomsControllerSelection {
	return page.workspace.retained.controller;
}

/** An attached checkpoint is the authority for shared settings and bearers;
 * the browser envelope keeps only its own controller selection. */
export function adoptAttachedSessionState(page: RoomsPageContext, session: RoomsWorkspaceState["session"]): void {
	page.workspace.retained = {
		...page.workspace.retained,
		dmMode: session.dmMode,
		vizOverride: session.vizOverride,
		operations: [...session.capabilities.operations],
		archivePeer: session.capabilities.archivePeer,
		peering: [...session.peering],
	};
}

export function setWorkspaceControllerSelection(page: RoomsPageContext, controller: RoomsControllerSelection): boolean {
	const prior = page.workspace.retained;
	const wasBlocked = page.workspace.persistenceBlocked;
	page.workspace.retained = { ...page.workspace.retained, controller };
	// Choosing a controller is an explicit replacement act. It may recover from
	// an obsolete or invalid saved document that boot correctly refused to
	// overwrite on behalf of unrelated store traffic.
	page.workspace.persistenceBlocked = false;
	if (persistCurrentWorkspace(page)) return true;
	page.workspace.retained = prior;
	page.workspace.persistenceBlocked = wasBlocked;
	return false;
}

/** A local fork of an attached session is a new peer. Directory names stay with
 * the session that still holds them, so reconstruction cannot retry those grants
 * and walk into every copied room as if this browser were still that member.
 * Returns a restore that undoes the drop when the controller commit fails. */
export function forgetForkedDirectoryNames(page: RoomsPageContext): () => void {
	const projection = page.projection;
	const prior = [...projection.get().dirs.values()].map((directory) => ({
		id: directory.id,
		requestedNick: directory.requestedNick,
		nick: directory.nick,
	}));
	const rememberedNick = projection.get().remembered.nick;
	for (const id of projection.get().dirs.keys()) {
		store.setRequestedDirNick(projection, id, "");
		store.setDirNick(projection, id, "");
	}
	store.remember(projection, { nick: "" });
	return () => {
		for (const directory of prior) {
			store.setRequestedDirNick(projection, directory.id, directory.requestedNick);
			store.setDirNick(projection, directory.id, directory.nick);
		}
		store.remember(projection, { nick: rememberedNick });
	};
}

/** The workspace document, or the sentence saying exactly why it cannot be
 * saved. A refused save leaves this browser reconstructing from the last good
 * document, so the reason has to name the bound and what would bring the
 * workspace back under it — "exceeds a persistence bound" alone left a reader
 * with a broken save and nothing to act on. */
export function validatedWorkspaceState(
	page: RoomsPageContext,
): { document: RoomsWorkspaceState } | { refused: string } {
	const document = workspaceStateOf(page, page.projection.get());
	const over = (held: number, most: number, what: string, shed: string) =>
		held > most ? { refused: `it holds ${held} ${what} and at most ${most} persist; ${shed}` } : null;
	const bound = over(
		document.session.directories.length,
		MAX_WORKSPACE_DIRECTORIES,
		"directories",
		"give one back from its card",
	) ?? over(
		document.session.conversations.length,
		MAX_WORKSPACE_CONVERSATIONS,
		"conversations",
		"leave or close some",
	) ?? over(
		document.session.invitations.length,
		MAX_WORKSPACE_INVITATIONS,
		"invitations",
		"answer or dismiss some",
	) ?? over(
		document.session.ignored.length,
		MAX_WORKSPACE_IGNORED_NAMES,
		"ignored names",
		"unignore some",
	) ?? over(
		document.session.capabilities.operations.length,
		MAX_WORKSPACE_OPERATION_CREDENTIALS,
		"remembered operations capabilities",
		"forget some in Settings",
	) ?? over(
		document.session.peering.length,
		MAX_WORKSPACE_PEERING,
		"peering intents",
		"revoke some on the Peering pane",
	);
	if (bound != null) return bound;
	const parsed = z.safeParse(RoomsWorkspaceStateSchema, document);
	if (!parsed.success) {
		const issue = parsed.error.issues[0];
		const at = issue == null ? "" : ` at ${issue.path.join(".")}`;
		return { refused: `a field refused its schema${at}: ${issue?.message ?? "unknown"}` };
	}
	return { document: parsed.data };
}

function encodedWorkspaceState(page: RoomsPageContext): { encoded: string } | { refused: string } {
	const validated = validatedWorkspaceState(page);
	if ("refused" in validated) return validated;
	const encoded = JSON.stringify(validated.document);
	if (encoded.length > MAX_WORKSPACE_DOCUMENT_CHARS) {
		return {
			refused: `the saved document would be ${encoded.length} characters and at most ` +
				`${MAX_WORKSPACE_DOCUMENT_CHARS} persist; long drafts are the usual weight`,
		};
	}
	return { encoded };
}

export function persistCurrentWorkspace(page: RoomsPageContext): boolean {
	if (page.workspace.persistenceBlocked) return false;
	if (page.workspace.persistenceControl != null) return page.workspace.persistenceControl.flush();
	const encoded = encodedWorkspaceState(page);
	return "encoded" in encoded && LS.set(WORKSPACE_STATE_KEY, encoded.encoded);
}

export function workspaceConnectionSettings(): { dmMode: "webrtc" | "relay"; vizOverride: string } {
	const document = parseWorkspaceState(LS.get(WORKSPACE_STATE_KEY));
	return document == null
		? { dmMode: "webrtc", vizOverride: "" }
		: { dmMode: document.session.dmMode, vizOverride: document.session.vizOverride };
}

export function setWorkspaceConnectionSettings(
	page: RoomsPageContext,
	next: { dmMode?: "webrtc" | "relay"; vizOverride?: string },
): boolean {
	const prior = page.workspace.retained;
	page.workspace.retained = { ...page.workspace.retained, ...next };
	if (persistCurrentWorkspace(page)) return true;
	page.workspace.retained = prior;
	return false;
}

export function rememberedWorkspaceOperation(page: RoomsPageContext, capability: OpsCap, scope: string): string | null {
	return page.workspace.retained.operations.find((row) => row.capability === capability && row.scope === scope)
		?.swiss ?? null;
}

export function rememberedWorkspaceOperations(page: RoomsPageContext): readonly WorkspaceOperationCredential[] {
	return page.workspace.retained.operations;
}

export function workspacePeeringIntents(page: RoomsPageContext): readonly WorkspacePeeringIntent[] {
	return page.workspace.retained.peering;
}

/** Add one restartable publication intent before its runtime lease is made. */
export function addWorkspacePeeringIntent(page: RoomsPageContext, intent: WorkspacePeeringIntent): boolean {
	const parsed = z.safeParse(WorkspacePeeringIntentSchema, intent);
	if (!parsed.success || page.workspace.retained.peering.some((entry) => entry.id === intent.id)) return false;
	const prior = page.workspace.retained;
	page.workspace.retained = {
		...page.workspace.retained,
		peering: [...page.workspace.retained.peering, parsed.data],
	};
	if (persistCurrentWorkspace(page)) return true;
	page.workspace.retained = prior;
	return false;
}

/** Remove a publication intent. Runtime lease cleanup remains the peering module's job. */
export function removeWorkspacePeeringIntent(page: RoomsPageContext, id: string): boolean {
	if (!page.workspace.retained.peering.some((entry) => entry.id === id)) return true;
	const prior = page.workspace.retained;
	page.workspace.retained = {
		...page.workspace.retained,
		peering: page.workspace.retained.peering.filter((entry) => entry.id !== id),
	};
	if (persistCurrentWorkspace(page)) return true;
	page.workspace.retained = prior;
	return false;
}

/** Remove publications whose source conversation is being forgotten. */
export function removeWorkspacePeeringForSource(page: RoomsPageContext, source: string): boolean {
	const next = page.workspace.retained.peering.filter((intent) => intent.source !== source);
	if (next.length === page.workspace.retained.peering.length) return true;
	const prior = page.workspace.retained;
	page.workspace.retained = { ...page.workspace.retained, peering: next };
	if (persistCurrentWorkspace(page)) return true;
	page.workspace.retained = prior;
	return false;
}

export function setRememberedWorkspaceOperations(
	page: RoomsPageContext,
	operations: readonly WorkspaceOperationCredential[],
): boolean {
	const normalized = parseWorkspaceOperationCredentials(operations);
	if (normalized == null) return false;
	const prior = page.workspace.retained;
	const wasBlocked = page.workspace.persistenceBlocked;
	const peering = peeringIntentsForOperations(normalized, page.workspace.retained.peering);
	page.workspace.retained = { ...page.workspace.retained, operations: normalized, peering };
	// Saving the complete capability set is an explicit replacement act. It may
	// recover from an invalid saved document that boot preserved rather than
	// silently overwriting from an unrelated store update.
	page.workspace.persistenceBlocked = false;
	if (persistCurrentWorkspace(page)) return true;
	page.workspace.retained = prior;
	page.workspace.persistenceBlocked = wasBlocked;
	return false;
}

export function setRememberedWorkspaceOperation(
	page: RoomsPageContext,
	capability: OpsCap,
	scope: string,
	swiss: string | null,
): boolean {
	const normalized = swiss == null
		? null
		: parseWorkspaceOperationCredentials([{ capability, scope, swiss }])?.[0]?.swiss ?? null;
	if (swiss != null && normalized == null) return false;
	const existing =
		page.workspace.retained.operations.find((row) => row.capability === capability && row.scope === scope)?.swiss ??
			null;
	if (existing === normalized) return true;
	const operations = page.workspace.retained.operations.filter((row) =>
		row.capability !== capability || row.scope !== scope
	);
	if (normalized != null) operations.push({ capability, scope, swiss: normalized });
	const prior = page.workspace.retained;
	page.workspace.retained = { ...page.workspace.retained, operations };
	if (persistCurrentWorkspace(page)) return true;
	page.workspace.retained = prior;
	return false;
}

export function rememberedWorkspaceArchivePeer(page: RoomsPageContext): string | null {
	return page.workspace.retained.archivePeer;
}

export function setRememberedWorkspaceArchivePeer(page: RoomsPageContext, sturdyref: string | null): boolean {
	if (page.workspace.retained.archivePeer === sturdyref) return true;
	const prior = page.workspace.retained;
	page.workspace.retained = { ...page.workspace.retained, archivePeer: sturdyref };
	if (persistCurrentWorkspace(page)) return true;
	page.workspace.retained = prior;
	return false;
}

/** Persist only when the durable projection changes. Store traffic includes
 * every message, presence tick, and transfer update; comparing the bounded
 * projection keeps those transient writes off browser storage. */
export function installWorkspaceStatePersistence(page: RoomsPageContext): () => void {
	if (page.workspace.persistenceControl != null) return () => {};
	let last = LS.get(WORKSPACE_STATE_KEY) ?? "";
	let dirty = false;
	let stopped = false;
	let refusedFor = "";
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
		if (stopped || page.workspace.persistenceBlocked) return false;
		if (saveTimer != null) {
			clearTimeout(saveTimer);
			saveTimer = null;
		}
		dirty = false;
		const answer = encodedWorkspaceState(page);
		if ("refused" in answer) {
			// Latched on the exact sentence, so a workspace that trips a second,
			// different bound is reported again rather than folded under the first.
			if (refusedFor !== answer.refused) {
				refusedFor = answer.refused;
				store.noteTrouble(
					page.projection,
					"workspace persistence",
					`this browser cannot save the Rooms workspace: ${answer.refused}`,
				);
			}
			return false;
		}
		const encoded = answer.encoded;
		if (encoded === last) {
			settleRetry();
			return true;
		}
		refusedFor = "";
		if (!LS.set(WORKSPACE_STATE_KEY, encoded)) {
			if (!storageFailureReported) {
				storageFailureReported = true;
				store.noteTrouble(
					page.projection,
					"workspace persistence",
					"this browser refused to save the Rooms workspace",
				);
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
		if (stopped || page.workspace.persistenceBlocked) return;
		dirty = true;
		if (saveTimer == null) saveTimer = setTimeout(commit, SAVE_COALESCE_MS);
	};
	const unsubscribe = page.projection.subscribe(() => {
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
		if (page.workspace.persistenceControl?.stop === stop) page.workspace.persistenceControl = null;
	};
	page.workspace.persistenceControl = { flush: commit, stop };
	schedule();
	return stop;
}
