// The durable workspace projection for the Rooms browser application.
//
// This document is deliberately not a snapshot of live runtime state. It keeps
// the choices a reader expects to survive a refresh and nothing that belongs to
// a CapTP connection: no Session, Ref, Room, promise, timer, File, object URL,
// or transient presence row. Boot projects these records back into the store;
// the network layer then realizes them as fresh sessions and references.

import * as store from "./store.ts";
import { LS } from "./storage.ts";
import { type DirId, dirId } from "./types.ts";
import type {
	RoomsControllerSelection,
	RoomsWorkspaceState,
	WorkspaceOperationCredential,
	WorkspacePeeringIntent,
} from "../../lib/rooms_state.ts";
import { applicationModule, readSavedWorkspace as parseWorkspaceState, workspaceStorageKey } from "./application.ts";
export { readSavedWorkspace as parseWorkspaceState } from "./application.ts";
import type { RoomsPageContext } from "./page.ts";
import { refusalText } from "../../lib/text/failure.ts";
export type { RoomsWorkspaceState } from "../../lib/rooms_state.ts";

interface RetainedWorkspaceState {
	readonly controller: RoomsControllerSelection;
	dmMode: RoomsWorkspaceState["session"]["dmMode"];
	traceOverride: string;
	operations: WorkspaceOperationCredential[];
	archivePeer: string | null;
	peering: WorkspacePeeringIntent[];
}

const EMPTY_RETAINED: RetainedWorkspaceState = {
	controller: { kind: "none" },
	dmMode: "webrtc",
	traceOverride: "",
	operations: [],
	archivePeer: null,
	peering: [],
};

/** In-memory working copy of the durable workspace document for one page. */
export class PageWorkspace {
	#retained: RetainedWorkspaceState = { ...EMPTY_RETAINED, operations: [] };
	#controllerListeners = new Set<() => void>();
	readonly controllerSelection = {
		getSnapshot: (): RoomsControllerSelection => this.#retained.controller,
		subscribe: (changed: () => void): () => void => {
			this.#controllerListeners.add(changed);
			return () => {
				this.#controllerListeners.delete(changed);
			};
		},
	};
	get retained(): RetainedWorkspaceState {
		return this.#retained;
	}
	set retained(next: RetainedWorkspaceState) {
		const previous = this.#retained.controller;
		this.#retained = next;
		if (previous !== next.controller) {
			for (const changed of this.#controllerListeners) changed();
		}
	}
	leftPageDirectory: DirId | null = null;
	#blockedBeforePersistence = false;
	get persistenceBlocked(): boolean {
		return this.persistenceControl?.blocked() ?? this.#blockedBeforePersistence;
	}
	set persistenceBlocked(blocked: boolean) {
		if (this.persistenceControl != null) this.persistenceControl.setBlocked(blocked);
		else this.#blockedBeforePersistence = blocked;
	}
	persistenceControl: {
		flush(): boolean;
		compose(choices: string): string;
		commitEncoded(encoded: string): boolean;
		stop(): void;
		blocked(): boolean;
		setBlocked(blocked: boolean): void;
		select(controller: string, checkpoint?: string): boolean;
		replace(encoded: string): boolean;
		clear(): boolean;
		attach(link: string, home: string): Promise<void>;
	} | null = null;
}

/** Adopt `document` as the retained working copy, or empty it. Exported for
 * `workspace/bundle.ts`, which installs and clears whole documents. */
export function retainWorkspace(page: RoomsPageContext, document: RoomsWorkspaceState | null): void {
	page.workspace.leftPageDirectory = document?.leftPageDirectory == null ? null : dirId(document.leftPageDirectory);
	page.workspace.retained = document == null ? { ...EMPTY_RETAINED, operations: [] } : {
		controller: document.controller,
		dmMode: document.session.dmMode,
		traceOverride: document.session.traceOverride,
		operations: [...document.session.capabilities.operations],
		archivePeer: document.session.capabilities.archivePeer,
		peering: [...document.session.peering],
	};
}

function encodeWorkspace(page: RoomsPageContext, state: Readonly<store.State>): string {
	const choices = JSON.stringify({
		...(page.workspace.leftPageDirectory === null ? {} : { leftPageDirectory: page.workspace.leftPageDirectory }),
		controller: page.workspace.retained.controller,
		view: {
			theme: state.theme,
			notifyOn: state.notifyOn,
			railOpen: state.railOpen,
			rosterOpen: state.rosterOpen,
			settingsTab: state.settingsTab,
			opsPane: state.opsPane,
		},
	});
	const encoded = page.attachedSession.current?.encodeWorkspace(choices);
	if (encoded != null) return encoded;
	if (page.workspace.persistenceControl == null) installWorkspaceStatePersistence(page);
	if (page.workspace.persistenceControl == null) throw new Error("The workspace persistence owner is unavailable");
	return page.workspace.persistenceControl.compose(choices);
}

export function workspaceStateOf(page: RoomsPageContext, state: Readonly<store.State>): RoomsWorkspaceState {
	return JSON.parse(encodeWorkspace(page, state)) as RoomsWorkspaceState;
}

export function workspaceControllerSelection(page: RoomsPageContext): RoomsControllerSelection {
	return page.workspace.retained.controller;
}

function retainedWithSession(
	retained: RetainedWorkspaceState,
	session: RoomsWorkspaceState["session"],
): RetainedWorkspaceState {
	return {
		...retained,
		dmMode: session.dmMode,
		traceOverride: session.traceOverride,
		operations: [...session.capabilities.operations],
		archivePeer: session.capabilities.archivePeer,
		peering: [...session.peering],
	};
}

/** Make the checkpoint-owned fields of one session the browser's retained
 * working copy. Projection fields are reconciled by the caller that owns them. */
export function retainSessionState(page: RoomsPageContext, session: RoomsWorkspaceState["session"]): void {
	page.workspace.retained = retainedWithSession(page.workspace.retained, session);
}

function commitWorkspaceController(
	page: RoomsPageContext,
	controller: RoomsControllerSelection,
	session?: RoomsWorkspaceState["session"],
): boolean {
	if (page.workspace.persistenceControl == null) installWorkspaceStatePersistence(page);
	const persistence = page.workspace.persistenceControl;
	if (
		persistence == null ||
		!persistence.select(JSON.stringify(controller), session == null ? undefined : JSON.stringify(session))
	) {
		return false;
	}
	const prior = page.workspace.retained;
	page.workspace.retained = {
		...(session == null ? prior : retainedWithSession(prior, session)),
		controller,
	};
	if (session != null) persistence.stop();
	return true;
}

/** Commit a controller over the session currently projected in this browser. */
export function setWorkspaceControllerSelection(page: RoomsPageContext, controller: RoomsControllerSelection): boolean {
	return commitWorkspaceController(page, controller);
}

/** Commit a cross-peer controller and that peer's verified checkpoint as one
 * browser document, then fence persistence until the caller reloads. */
export function setWorkspaceControllerAndSession(
	page: RoomsPageContext,
	controller: RoomsControllerSelection,
	session: RoomsWorkspaceState["session"],
): boolean {
	return commitWorkspaceController(page, controller, session);
}

/** Rust supplies an admitted workspace or the reason it cannot be encoded. */
export function validatedWorkspaceState(
	page: RoomsPageContext,
): { document: RoomsWorkspaceState } | { refused: string } {
	try {
		return { document: workspaceStateOf(page, page.projection.get()) };
	} catch (error) {
		return { refused: refusalText(error) };
	}
}

function encodedWorkspaceState(page: RoomsPageContext): { encoded: string } | { refused: string } {
	try {
		return { encoded: encodeWorkspace(page, page.projection.get()) };
	} catch (error) {
		return { refused: refusalText(error) };
	}
}

export function persistCurrentWorkspace(page: RoomsPageContext): boolean {
	if (page.workspace.persistenceBlocked) return false;
	if (page.workspace.persistenceControl == null) installWorkspaceStatePersistence(page);
	return page.workspace.persistenceControl?.flush() ?? false;
}

/** Commit an already-prepared complete document without first projecting it
 * into live state. Destructive acts use this boundary so a refused browser
 * write leaves the old projection intact and retryable. */
export function persistPreparedWorkspace(page: RoomsPageContext, document: RoomsWorkspaceState): boolean {
	if (page.workspace.persistenceBlocked) return false;
	const encoded = JSON.stringify(document);
	const parsed = parseWorkspaceState(encoded);
	if (parsed == null) {
		store.noteTrouble(page.projection, "workspace persistence", "a prepared workspace transition was not valid");
		return false;
	}
	const canonical = JSON.stringify(parsed);
	if (page.workspace.persistenceControl == null) installWorkspaceStatePersistence(page);
	return page.workspace.persistenceControl?.commitEncoded(canonical) ?? false;
}

export function workspaceConnectionSettings(): { dmMode: "webrtc" | "relay"; traceOverride: string } {
	const document = parseWorkspaceState(LS.get(workspaceStorageKey()));
	return document == null
		? { dmMode: "webrtc", traceOverride: "" }
		: { dmMode: document.session.dmMode, traceOverride: document.session.traceOverride };
}

/** Persist only when the durable projection changes. Store traffic includes
 * every message, presence tick, and transfer update; comparing the bounded
 * projection keeps those transient writes off browser storage. */
export function installWorkspaceStatePersistence(page: RoomsPageContext): () => void {
	if (page.workspace.persistenceControl != null) return () => {};
	const saver = new (applicationModule().RoomsWorkspacePersistence)(
		LS.get(workspaceStorageKey()) ?? undefined,
		page.workspace.persistenceBlocked,
		() => {
			const result = encodedWorkspaceState(page);
			if ("refused" in result) throw new Error(result.refused);
			return result.encoded;
		},
		(encoded: string) => LS.set(workspaceStorageKey(), encoded),
		() => {
			try {
				for (const key of Object.keys(localStorage)) {
					if (key.startsWith("rooms.") && key !== workspaceStorageKey()) localStorage.removeItem(key);
				}
				return LS.remove(workspaceStorageKey());
			} catch {
				return false;
			}
		},
		(reason: string) => store.noteTrouble(page.projection, "workspace persistence", reason),
	);
	const unsubscribe = page.projection.subscribe(() => saver.schedule());
	const flushOnHide = () => {
		saver.flushIfDirty();
	};
	addEventListener("pagehide", flushOnHide);
	if (typeof document !== "undefined") document.addEventListener("visibilitychange", flushOnHide);
	const stop = () => {
		const blocked = saver.blocked();
		saver.stop();
		unsubscribe();
		removeEventListener("pagehide", flushOnHide);
		if (typeof document !== "undefined") document.removeEventListener("visibilitychange", flushOnHide);
		if (page.workspace.persistenceControl?.stop === stop) {
			page.workspace.persistenceControl = null;
			page.workspace.persistenceBlocked = blocked;
		}
	};
	page.workspace.persistenceControl = {
		flush: () => saver.flush(),
		compose: (choices) => saver.compose(choices),
		commitEncoded: (encoded) => saver.flush(encoded),
		blocked: () => saver.blocked(),
		setBlocked: (blocked) => saver.setBlocked(blocked),
		select: (controller, checkpoint) => {
			const saved = saver.select(controller, checkpoint);
			if (saver.stopped()) stop();
			return saved;
		},
		replace: (encoded) => saver.replace(encoded),
		clear: () => saver.clear(),
		attach: async (link, home) => {
			const current = page.attachedSession.current;
			const result = await (current == null
				? applicationModule().RoomsBrowserApplication.selectWorkspace(
					saver,
					link,
					home,
					(source: string, reason: string) => store.noteTrouble(page.projection, source, reason),
				)
				: current.selectWorkspace(saver, link, home));
			if (result.workspace != null) {
				stop();
				retainWorkspace(page, JSON.parse(result.workspace) as RoomsWorkspaceState);
			}
			if (result.cleanup != null) {
				store.noteTrouble(page.projection, "shared session attachment cleanup", result.cleanup);
			}
		},
		stop,
	};
	saver.schedule();
	return stop;
}
