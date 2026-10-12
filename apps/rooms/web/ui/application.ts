// The page loads the production Rust application before restoring durable
// choices. This module adapts its JSON projection to existing presentation
// types. It owns no protocol calls, validation rules, or Host.
import * as z from "zod/mini";
import type { InitInput } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import { ROOMS_FAILURES, type RoomsErrorCode, type RoomsFailureRetry } from "../../lib/error_codes.ts";
import { type DirId, dirId } from "./types.ts";

/** Parse a JSON projection from the Rust application, proving its shape
 * before any consumer reads it. A wrong shape names a defect in the shared
 * build. It is never cast into place. */
function projected<S extends z.ZodMiniType>(encoded: string, schema: S, what: string): z.infer<S> {
	const parsed = z.safeParse(schema, JSON.parse(encoded));
	if (!parsed.success) {
		throw new Error(`the Rooms application answered an invalid ${what}:\n${z.prettifyError(parsed.error)}`);
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
	if (loaded == null) throw new Error("the Rooms application has not initialized");
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
	return encoded == null ? null : projected(encoded, RoomsAddressSchema, "directory address");
}

export function inspectCapability(value: string): RoomsAddress | null {
	const encoded = applicationModule().inspectCapability(value);
	return encoded == null ? null : projected(encoded, RoomsAddressSchema, "capability address");
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

export function nicknameAvailability(
	nick: string,
	own: string | null,
	directory: readonly string[] | null,
	room: readonly string[] | null,
): RustNicknameAvailability {
	// wasm-bindgen types every JavaScript Array as mutable. Rust only iterates
	// these arrays, so keep the caller's read-only contract without copying.
	return projected(
		applicationModule().nicknameAvailability(
			nick,
			own ?? undefined,
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

export interface SessionFailureAdvice {
	readonly code: RoomsErrorCode;
	readonly subject: string;
	readonly retry: RoomsFailureRetry;
	readonly summary: string;
	readonly action: string;
}

/** The retry posture is not a free field: it must equal the posture the
 * failure table declares for the code. */
const SessionFailureAdviceSchema: z.ZodMiniType<SessionFailureAdvice> = z.object({
	code: z.custom<RoomsErrorCode>((value) => typeof value === "string" && Object.hasOwn(ROOMS_FAILURES, value)),
	subject: z.string(),
	retry: z.custom<RoomsFailureRetry>(() => true),
	summary: z.string(),
	action: z.string(),
}).check(z.refine((advice) => advice.retry === ROOMS_FAILURES[advice.code].retry));

export function attachmentFailureAdvice(reason: string): SessionFailureAdvice | null {
	const encoded = applicationModule().attachmentFailureAdvice(reason);
	return encoded == null ? null : projected(encoded, SessionFailureAdviceSchema, "attachment failure advice");
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
