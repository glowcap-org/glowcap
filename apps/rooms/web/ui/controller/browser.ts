// Browser-owned presentation and session-establishment, independent of whether
// the established session is local or attached.

import { createContext, useContext } from "react";
import type { RoomsControllerSelection } from "../../../lib/rooms_state.ts";
import type { RoomPreset } from "../../../lib/room/policy.ts";
import type { Reach } from "../intent.ts";
import type { AttachmentView, DirId, MemberRef, OpsCap, SettingsTab, ToastKind } from "../types.ts";

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
	openHelp(): void;
	closeHelp(): void;
	openOperations(): void;
	showActiveConversation(): void;
	setOpsPane(pane: OpsCap): void;
	changeLine(id: number, text: string): void;
	changeFiles(id: number, caption: string, keeping: readonly AttachmentView[]): void;
	dropKeptFile(index: number): void;
	cancelChange(): void;
	addFiles(files: readonly File[]): void;
	removeFile(index: number): void;
	closeViewer(): void;
	editJoin(patch: {
		room?: string;
		locator?: string;
		nick?: string;
		roomPreset?: RoomPreset;
	}): void;
	attachRoomsSession(sturdyref: string): Promise<string>;
	shareRoomsSession(): Promise<string>;
	useLocalRoomsSession(): string;
	leaveRoomsSession(): string;
	roomsController(): RoomsControllerSelection;
	resetBrowserWorkspace(): string;
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
