// The page loads the production Rust application before restoring durable
// choices. This module adapts its JSON projection to existing presentation
// types; it owns no protocol calls, validation rules, or Host.
import type { InitInput } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { RoomsSessionState, RoomsWorkspaceState } from "../../lib/rooms_state.ts";
import type { RoomsErrorCode, RoomsFailureRetry } from "../../lib/error_codes.ts";
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

export type RustNicknameAvailability =
	| { readonly kind: "unknown" }
	| { readonly kind: "available" }
	| { readonly kind: "taken"; readonly source: "directory" | "room"; readonly suggestion: string };

export function nicknameAvailability(
	nick: string,
	own: string | null,
	directory: readonly string[] | null,
	room: readonly string[] | null,
): RustNicknameAvailability {
	// wasm-bindgen types every JavaScript Array as mutable. Rust only iterates
	// these arrays, so keep the caller's read-only contract without copying.
	return JSON.parse(
		applicationModule().nicknameAvailability(
			nick,
			own ?? undefined,
			directory == null ? undefined : directory as string[],
			room == null ? undefined : room as string[],
		),
	) as RustNicknameAvailability;
}

export function suggestedNickname(nick: string): string {
	return applicationModule().suggestedNickname(nick);
}

export interface SessionFailureAdvice {
	readonly code: RoomsErrorCode;
	readonly subject: string;
	readonly retry: RoomsFailureRetry;
	readonly summary: string;
	readonly action: string;
}

export function attachmentFailureAdvice(reason: string): SessionFailureAdvice | null {
	const encoded = applicationModule().attachmentFailureAdvice(reason);
	return encoded == null ? null : JSON.parse(encoded) as SessionFailureAdvice;
}

export function markdownDocument(text: string): string {
	return applicationModule().markdownDocument(text);
}

export function openGraphTargets(text: string): string {
	return applicationModule().openGraphTargets(text);
}

export function openGraphSelection(text: string, encoded: string): string | undefined {
	return applicationModule().openGraphSelection(text, encoded);
}

export function openGraphMetadata(encoded: string): string | undefined {
	return applicationModule().openGraphMetadata(encoded);
}
