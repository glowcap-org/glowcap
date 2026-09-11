// The page loads the production Rust application before restoring durable
// choices. This module adapts its JSON projection to existing presentation
// types; it owns no protocol calls, validation rules, or Host.
import type { InitInput } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
export type { RoomsCommands } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { RoomsSessionState, RoomsWorkspaceState } from "../../lib/rooms_state.ts";
import { type DirId, dirId } from "./types.ts";

type Application = typeof import("../../../../zig-out/wasm/rooms/rooms_browser.js");
let loaded: Application | null = null;

/** The opening screen precedes application initialization. Load its generated
 * glue alongside the Wasm artifact, then expose one initialized module. */
export async function loadApplication(source: InitInput | Promise<InitInput>): Promise<void> {
	const [module, artifact] = await Promise.all([
		import("../../../../zig-out/wasm/rooms/rooms_browser.js"),
		source,
	]);
	await module.default({ module_or_path: artifact });
	loaded = module;
}

export function applicationModule(): Application {
	if (loaded == null) throw new Error("the Rooms application has not initialized");
	return loaded;
}

export function readSavedWorkspace(raw: string | null): RoomsWorkspaceState | null {
	if (raw == null) return null;
	const encoded = applicationModule().readWorkspace(raw);
	return encoded == null ? null : JSON.parse(encoded) as RoomsWorkspaceState;
}

export function directoryId(locator: string): DirId | null {
	const authority = applicationModule().directoryAuthority(locator);
	return authority == null ? null : dirId(authority);
}

export function directConversationId(directory: string, registration: string): string {
	return applicationModule().directConversationId(directory, registration);
}

/** Display facts from the shared Rooms route reader. They hold no live capability. */
export interface RoomsAddress {
	readonly authority: string;
	readonly address: string;
	readonly transport: string;
	readonly designator: string;
}

export function inspectDirectory(value: string): RoomsAddress | null {
	const encoded = applicationModule().inspectDirectory(value);
	return encoded == null ? null : JSON.parse(encoded) as RoomsAddress;
}

export function inspectCapability(value: string): RoomsAddress | null {
	const encoded = applicationModule().inspectCapability(value);
	return encoded == null ? null : JSON.parse(encoded) as RoomsAddress;
}

export function roomAuthorityToken(sturdyref: string): string {
	return applicationModule().roomAuthorityToken(sturdyref);
}

export function emptyRoomsSessionState(): RoomsSessionState {
	return JSON.parse(applicationModule().emptySessionCheckpoint()) as RoomsSessionState;
}

export function workspaceStorageKey(): string {
	return applicationModule().workspaceStorageKey();
}
