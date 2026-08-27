// Bounded durable schema and storage for one Rooms session's external effects.

import * as z from "zod/mini";
import { fixedHex, nonemptyText, nonnegativeSafeInteger } from "../lib/schema.ts";
import { atomicWrite, readBoundedText } from "../lib/durable_file.ts";

const FILE = "effects.json";
const VERSION = 1;
export const RECENT_OPERATIONS = 64;
export const PENDING_OPERATIONS = 64;
const MAX_OPERATION_ID_CHARS = 128;
const MAX_RESULT_KIND_CHARS = 64;
const MAX_RESULT_TEXT_CHARS = 32 * 1024;
const MAX_EFFECT_SUBJECT_CHARS = 256;
const MAX_EFFECTS_STATE_BYTES = 4 * 1024 * 1024;

const operationId = nonemptyText(MAX_OPERATION_ID_CHARS);

/** Validate an operation identity at the inbound session boundary. The effect
 * ledger owns this grammar so checkpoint commands and external effects cannot
 * drift into accepting different identities. */
export function validateOperationId(value: unknown): string {
	const parsed = z.safeParse(operationId, value);
	if (!parsed.success) throw new Error("session operation id is out of range");
	return parsed.data;
}
const digest = fixedHex(32);
const resultKind = nonemptyText(MAX_RESULT_KIND_CHARS);
const resultText = nonemptyText(MAX_RESULT_TEXT_CHARS);
const effectSubjectText = nonemptyText(MAX_EFFECT_SUBJECT_CHARS);

const RecentOperationShape = {
	id: operationId,
	digest,
	revision: nonnegativeSafeInteger,
};

export const RecentOperationSchema = z.strictObject(RecentOperationShape);

export const OrdinaryPendingEffectSchema = z.strictObject({
	type: z.literal("ordinary"),
	id: operationId,
	digest,
	subject: effectSubjectText,
});

const ResultApplyMarkerSchema = z.strictObject({
	revision: nonnegativeSafeInteger,
	applyKind: resultKind,
	resultDigest: digest,
});

export const PendingResultEffectSchema = z.strictObject({
	type: z.literal("result"),
	id: operationId,
	digest,
	resultKind,
	baseRevision: nonnegativeSafeInteger,
	intent: resultText,
	result: z.nullable(resultText),
	marker: z.nullable(ResultApplyMarkerSchema),
}).check(z.refine((effect) =>
	effect.marker == null ||
	(effect.result != null && effect.marker.revision > effect.baseRevision &&
		effect.marker.applyKind === effect.resultKind)
));

export const PendingEffectSchema = z.union([OrdinaryPendingEffectSchema, PendingResultEffectSchema]);

export const RecentEffectSchema = z.strictObject({
	...RecentOperationShape,
	outcome: z.enum(["committed", "abandoned"]),
	resultKind: z.nullable(resultKind),
	result: z.nullable(resultText),
}).check(
	z.refine((effect) =>
		effect.outcome === "committed" ? (effect.resultKind == null) === (effect.result == null) : effect.result == null
	),
);

const EffectsStateShapeSchema = z.strictObject({
	version: z.literal(VERSION),
	recent: z.array(RecentEffectSchema).check(z.maxLength(RECENT_OPERATIONS)),
	pending: z.array(PendingEffectSchema).check(z.maxLength(PENDING_OPERATIONS)),
});

function hasValidEffectRelations(
	state: { recent: readonly RecentEffect[]; pending: readonly PendingEffect[] },
): boolean {
	const ids = new Set<string>();
	for (const effect of state.recent) {
		if (ids.has(effect.id)) return false;
		ids.add(effect.id);
	}
	let resultEffects = 0;
	for (const effect of state.pending) {
		if (ids.has(effect.id)) return false;
		ids.add(effect.id);
		if (effect.type === "result") resultEffects += 1;
	}
	return resultEffects <= 1;
}

export const EffectsStateSchema = EffectsStateShapeSchema.check(
	z.refine(hasValidEffectRelations, "effect operation identities or result concurrency are inconsistent"),
);

export type RecentOperation = z.infer<typeof RecentOperationSchema>;
export type OrdinaryPendingEffect = z.infer<typeof OrdinaryPendingEffectSchema>;
export type PendingResultEffect = z.infer<typeof PendingResultEffectSchema>;
export type PendingEffect = z.infer<typeof PendingEffectSchema>;
export type RecentEffect = z.infer<typeof RecentEffectSchema>;
export type EffectsState = z.infer<typeof EffectsStateSchema>;

export function parseRecent(raw: unknown, minimumRevision = 1): RecentOperation[] {
	const parsed = z.safeParse(
		z.array(RecentOperationSchema).check(z.maxLength(RECENT_OPERATIONS)),
		raw,
	);
	if (!parsed.success) {
		throw new Error(`Rooms session has an invalid retry ledger:\n${z.prettifyError(parsed.error)}`);
	}
	const ids = new Set<string>();
	for (const operation of parsed.data) {
		if (operation.revision < minimumRevision || ids.has(operation.id)) {
			throw new Error("Rooms session has an invalid retry row");
		}
		ids.add(operation.id);
	}
	return parsed.data;
}

export function effectText(raw: unknown, field: string, max = MAX_RESULT_TEXT_CHARS): string {
	if (typeof raw !== "string" || raw === "" || raw.length > max) {
		throw new Error(`Rooms session has an invalid ${field}`);
	}
	return raw;
}

export function effectKind(raw: unknown): string {
	return effectText(raw, "result kind", MAX_RESULT_KIND_CHARS);
}

export async function textDigest(material: string): Promise<string> {
	const bytes = new TextEncoder().encode(material);
	const digestBytes = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
	return [...digestBytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** A redacted action name for crash recovery. The command material remains the
 * idempotency input; this description deliberately excludes its arguments. */
export function describeOrdinaryEffect(material: string): string {
	try {
		const decoded: unknown = JSON.parse(material);
		const command = Array.isArray(decoded) && typeof decoded[0] === "string" ? decoded[0] : "external";
		switch (command) {
			case "say":
				return "Send a message";
			case "sendFiles":
				return "Send message attachments";
			case "editLine":
				return "Edit a message";
			case "withdrawLine":
				return "Withdraw a message";
			case "setRoomTopic":
				return "Set a room topic";
			case "kickRoomMember":
				return "Ask a room member to leave";
			case "offerRoom":
				return "Offer a room invitation";
			case "operator":
				return "Run a Rooms operator action";
			case "operations":
				return "Run a directory operation";
			default:
				return "Run a shared session operation";
		}
	} catch {
		return "Run a shared session operation";
	}
}

function parse(text: string): EffectsState {
	let decoded: unknown;
	try {
		decoded = JSON.parse(text);
	} catch {
		throw new Error("Rooms session effect state is not JSON");
	}
	if (typeof decoded === "object" && decoded != null && (decoded as { version?: unknown }).version !== VERSION) {
		throw new Error(
			`Rooms session effect state version ${String((decoded as { version?: unknown }).version)} is not supported`,
		);
	}
	const parsed = z.safeParse(EffectsStateSchema, decoded);
	if (!parsed.success) throw new Error(`Rooms session effect state is invalid:\n${z.prettifyError(parsed.error)}`);
	return parsed.data;
}

export async function writeEffects(directory: string, effects: EffectsState): Promise<void> {
	const parsed = z.safeParse(EffectsStateSchema, effects);
	if (!parsed.success) {
		throw new Error(`Rooms session refused invalid effect state:\n${z.prettifyError(parsed.error)}`);
	}
	await atomicWrite(`${directory}/${FILE}`, new TextEncoder().encode(JSON.stringify(parsed.data) + "\n"));
}

export async function openEffects(directory: string, checkpointCreated: boolean): Promise<EffectsState> {
	try {
		return parse(
			await readBoundedText(`${directory}/${FILE}`, MAX_EFFECTS_STATE_BYTES, "Rooms session effect state"),
		);
	} catch (error) {
		if (!(error instanceof Deno.errors.NotFound)) throw error;
		if (!checkpointCreated) throw new Error("Rooms session effect state is missing beside an existing checkpoint");
		const effects: EffectsState = { version: VERSION, recent: [], pending: [] };
		await writeEffects(directory, effects);
		return effects;
	}
}
