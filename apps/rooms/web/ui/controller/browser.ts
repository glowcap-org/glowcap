// Browser-owned presentation and session-establishment, independent of whether
// the established session is local or attached.

import { createContext, useContext, useSyncExternalStore } from "react";
import type { RoomsControllerSelection } from "../../../lib/rooms_state.ts";
import type { RoomPreset } from "../room_policy.ts";
import type { Reach } from "../intent.ts";
import type { HelpTab } from "../store/core.ts";
import type { AttachmentView, DirId, MemberRef, OpsCap, SettingsTab, ToastKind } from "../types.ts";
import type { DraftPreview, OpenGraphMetadata, PreviewFailure } from "../link_preview.ts";

/** Keeping these outside the session controller prevents an attached view from
 * borrowing browser behavior from the local session implementation. */
export interface RoomsBrowserController {
	showRail(shown: boolean): void;
	reachFor(act: Reach): void;
	showJoinCard(): void;
	aboutDirectory(dir: DirId | null, askingLeave?: boolean): void;
	showDirectory(dir: DirId): void;
	aboutMember(about: MemberRef | null): void;
	aboutConversation(pane?: "about" | "bridge" | "capabilities", askingLeave?: boolean): void;
	manageBridgeIdentity(): void;
	closeAboutConversation(): void;
	showError(detail: { title: string; text: string }): void;
	closeError(): void;
	toast(kind: ToastKind, text: string): void;
	showRoster(shown: boolean): void;
	toggleNotify(): Promise<string | null>;
	openSettings(): void;
	closeSettings(): void;
	setSettingsTab(tab: SettingsTab): void;
	setTheme(theme: "light" | "dark"): void;
	/** Open Help, on the tab a control asked for when it names one. */
	openHelp(tab?: HelpTab): void;
	setHelpTab(tab: HelpTab): void;
	closeHelp(): void;
	openOperations(): void;
	/** Acknowledge a conversation after its selection settles, while this arrival remains current. */
	showActiveConversation(selection: Promise<void>): Promise<void>;
	setOpsPane(pane: OpsCap): void;
	changeLine(id: number, text: string): void;
	changeFiles(id: number, caption: string, keeping: readonly AttachmentView[]): void;
	dropKeptFile(index: number): void;
	cancelChange(): void;
	addFiles(files: readonly File[]): void;
	removeFile(index: number): void;
	startPreview(key: string, id: number): DraftPreview | null;
	settlePreview(
		key: string,
		id: number,
		attempt: number,
		outcome: { state: "ready"; metadata: OpenGraphMetadata } | { state: "failed"; failure: PreviewFailure },
	): void;
	cancelPreview(key: string, id: number, attempt: number): void;
	removePreview(key: string, id: number): void;
	retryPreview(key: string, id: number): void;
	closeViewer(): void;
	editJoin(patch: {
		room?: string;
		locator?: string;
		nick?: string;
		roomPreset?: RoomPreset;
	}): void;
	attachRoomsSession(sturdyref: string): Promise<string>;
	shareRoomsSession(): Promise<string>;
	useLocalRoomsSession(): Promise<string>;
	leaveRoomsSession(): Promise<string>;
	readonly controllerSelection: {
		getSnapshot(): RoomsControllerSelection;
		subscribe(changed: () => void): () => void;
	};
	resetBrowserWorkspace(): Promise<string>;
	deleteBrowserData(): Promise<string>;
}

const RoomsBrowserContext = createContext<RoomsBrowserController | null>(null);

export const RoomsBrowserProvider = RoomsBrowserContext.Provider;

export function useRoomsBrowser(): RoomsBrowserController {
	const controller = useContext(RoomsBrowserContext);
	if (controller == null) {
		throw new Error("rooms: browser behavior was requested outside its provider");
	}
	return controller;
}

/** Every component rendering session kind or custody subscribes to its owner. */
export function useRoomsController(): RoomsControllerSelection {
	const selection = useRoomsBrowser().controllerSelection;
	return useSyncExternalStore(selection.subscribe, selection.getSnapshot, selection.getSnapshot);
}
