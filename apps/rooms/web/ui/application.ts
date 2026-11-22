// Load the Rust application and adapt its pure projections for the page.
// Browser effects, including server HTTP reads, live in their owning modules.
import { invariant } from "../../lib/invariant.ts";
import * as z from "zod/mini";
import type { InitInput } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import { type DirId, dirId } from "./directory.ts";
import type { WorkspaceIntent } from "./session/managed/model.ts";

/** Parse a JSON projection from the Rust application, proving its shape
 * before any consumer reads it. A wrong shape names a defect in the shared
 * build. It is never cast into place. */
export function applicationProjection<S extends z.ZodMiniType>(encoded: string, schema: S, what: string): z.infer<S> {
	const parsed = z.safeParse(schema, JSON.parse(encoded));
	if (!parsed.success) {
		invariant(false, `the Rooms application answered an invalid ${what}:\n${z.prettifyError(parsed.error)}`);
	}
	return parsed.data;
}

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
	invariant(loaded != null, "the Rooms application has not initialized");
	return loaded;
}

export function directoryId(locator: string): DirId | null {
	const authority = applicationModule().directoryAuthority(locator);
	return authority == null ? null : dirId(authority);
}

export function directConversationId(directory: string, registration: string): string {
	return applicationModule().directConversationId(directory, registration);
}

export function directHistoryId(directory: string, registration: string): string {
	return applicationModule().directHistoryId(directory, registration);
}

/** Which direct row reaches a member, by the rule the session holds: the open
 * row a new route is given back to, and the closed row a new route reopens
 * when none is open. Each is a conversation id, or null. */
export interface DirectReach {
	readonly open: string | null;
	readonly reopened: string | null;
}

const DirectReachSchema = z.object({
	open: z.nullable(z.number()),
	reopened: z.nullable(z.number()),
});

export function directReach(intent: WorkspaceIntent, directory: string, registration: string): DirectReach {
	const rows = intent.conversations.map((row) =>
		row.kind === "direct"
			? { directory: row.directory, registration: row.introduction?.registration ?? null, closed: row.closed }
			: null
	);
	const encoded = applicationModule().directReach(JSON.stringify(rows), directory, registration);
	const reach = applicationProjection(encoded, DirectReachSchema, "direct reach");
	const id = (at: number | null) => at == null ? null : intent.conversations[at]?.id ?? null;
	return { open: id(reach.open), reopened: id(reach.reopened) };
}

/** Display facts from the shared Rooms route reader. They hold no live capability. */
export interface RoomsAddress {
	readonly authority: string;
	readonly address: string;
	readonly transport: string;
	readonly designator: string;
}

const RoomsAddressSchema: z.ZodMiniType<RoomsAddress> = z.object({
	authority: z.string(),
	address: z.string(),
	transport: z.string(),
	designator: z.string(),
});

export function inspectDirectory(value: string): RoomsAddress | null {
	const encoded = applicationModule().inspectDirectory(value);
	return encoded == null ? null : applicationProjection(encoded, RoomsAddressSchema, "directory address");
}

/** How this browser, with no Rooms server, would reach a typed address: the
 * relay of the first door it opens by itself, or null when the address names
 * none it can open, and whether any door needs a Rooms server. Null for text
 * that is not a directory address. */
export interface BrowserDoors {
	readonly relay: URL | null;
	readonly throughServer: boolean;
}

const BrowserDoorsSchema = z.object({ relay: z.nullable(z.string()), throughServer: z.boolean() });

export function browserDoors(address: string): BrowserDoors | null {
	return doorsFrom(applicationModule().browserDoors(address));
}

/** The same for a pasted capability link, or null for text that is not one. */
export function capabilityDoors(link: string): BrowserDoors | null {
	return doorsFrom(applicationModule().browserCapabilityDoors(link));
}

function doorsFrom(encoded: string | undefined): BrowserDoors | null {
	if (encoded == null) return null;
	const doors = applicationProjection(encoded, BrowserDoorsSchema, "door list");
	// The application admitted the relay as an absolute WebSocket URL.
	return { relay: doors.relay === null ? null : new URL(doors.relay), throughServer: doors.throughServer };
}

/** Whether reaching a pasted link takes a Rooms server: one of its doors is a
 * door this browser cannot open on its own. Text that is no link has no doors,
 * and the act that takes it refuses it for what it is. */
export function linkNeedsServer(link: string): boolean {
	return capabilityDoors(link)?.throughServer ?? false;
}

export function inspectCapability(value: string): RoomsAddress | null {
	const encoded = applicationModule().inspectCapability(value);
	return encoded == null ? null : applicationProjection(encoded, RoomsAddressSchema, "capability address");
}

export function roomAuthorityToken(sturdyref: string): string {
	return applicationModule().roomAuthorityToken(sturdyref);
}

export type RustNicknameAvailability =
	| { readonly kind: "unknown" }
	| { readonly kind: "available" }
	| { readonly kind: "taken"; readonly source: "directory" | "room"; readonly suggestion: string };

const NicknameAvailabilitySchema = z.discriminatedUnion("kind", [
	z.object({ kind: z.literal("unknown") }),
	z.object({ kind: z.literal("available") }),
	z.object({
		kind: z.literal("taken"),
		source: z.enum(["directory", "room"]),
		suggestion: z.string(),
	}),
]);

/** This tab's own name on a directory: the one it granted, or the one this
 * tab's registration asked for before the directory answered. */
export type OwnNick = { readonly granted: string } | { readonly requested: string };

export function nicknameAvailability(
	nick: string,
	own: OwnNick | null,
	directory: readonly string[] | null,
	room: readonly string[] | null,
): RustNicknameAvailability {
	// wasm-bindgen types every JavaScript Array as mutable. Rust only iterates
	// these arrays, so keep the caller's read-only contract without copying.
	return applicationProjection(
		applicationModule().nicknameAvailability(
			nick,
			own != null && "granted" in own ? own.granted : undefined,
			own != null && "requested" in own ? own.requested : undefined,
			directory == null ? undefined : directory as string[],
			room == null ? undefined : room as string[],
		),
		NicknameAvailabilitySchema,
		"nickname availability",
	);
}

export function suggestedNickname(nick: string): string {
	return applicationModule().suggestedNickname(nick);
}

export function richTextOf(text: string): string {
	return applicationModule().richText(text);
}

export function lineMentionsOf(from: string, text: string, own: string): string {
	return applicationModule().lineMentions(from, text, own);
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
