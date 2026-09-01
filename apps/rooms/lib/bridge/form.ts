// A form a bridge describes and Rooms draws.
//
// Linking an identity on a bridged service asks for different things on every
// service: IRC wants a nick and optionally a registered account and password,
// XMPP wants a JID and a password, and a Matrix bridge that puppets its users
// wants nothing at all. Rooms cannot know those, and a bridge cannot draw a
// form, so the bridge says what it needs and Rooms decides what that looks
// like.
//
// The split is the same one the rest of the outlet keeps: a claim about the
// service is the bridge's to make, and a claim about what Rooms does with what
// you type is Rooms' to make and not the bridge's to word or to omit.
//
// There is deliberately no template language and no way to say "when this, show
// that" beyond one toggle. A bridge that needs a different form for a different
// state declares a different form; it already knows the state, so a language for
// deferring that decision would buy nothing and would be a second interface
// nobody can see the whole of.

import * as z from "zod/mini";
import {
	MAX_FORM_ACTIONS,
	MAX_FORM_FIELDS,
	MAX_FORM_HINT,
	MAX_FORM_JSON,
	MAX_FORM_LABEL,
	MAX_FORM_SAID,
	MAX_FORM_SCOPE,
	MAX_FORM_TITLE,
	MAX_FORM_VALUE,
} from "../limits.ts";
import { boundedText, nonemptyText } from "../schema.ts";

/** An identifier a bridge gives one of its own fields or actions. It is never
 * shown; it is what a submission names. */
const FormId = nonemptyText(32).check(z.regex(/^[a-z][a-z0-9-]*$/));

const Label = nonemptyText(MAX_FORM_LABEL);
const Hint = boundedText(MAX_FORM_HINT);

/** A line of text. Identifier treatment when drawn: a mobile keyboard that
 * capitalises a nick has changed it, and every field any real bridge has asked
 * for so far is an identifier rather than prose. */
export const BridgeTextFieldSchema = z.strictObject({
	kind: z.literal("text"),
	id: FormId,
	label: Label,
	hint: z.optional(Hint),
	/** What it starts as. A bridge fills this with what it already knows, so a
	 * reader corrects rather than retypes. */
	value: z.optional(boundedText(MAX_FORM_VALUE)),
	required: z.boolean(),
});

/** A line of text Rooms will not keep.
 *
 * There is no starting value, and that is not an omission: offering one would
 * mean Rooms had kept a credential in order to put it back. What `secret` means
 * is a promise Rooms makes, not a hint the bridge gives — see the renderer. */
export const BridgeSecretFieldSchema = z.strictObject({
	kind: z.literal("secret"),
	id: FormId,
	label: Label,
	hint: z.optional(Hint),
	required: z.boolean(),
});

const BridgeLeafFieldSchema = z.union([BridgeTextFieldSchema, BridgeSecretFieldSchema]);

/** A checkbox that may reveal a few fields under it.
 *
 * Exactly one level deep, and unrepresentable otherwise: a reveal holds leaves
 * and a leaf is not a toggle, so there is no nesting to bound at runtime. One
 * level is what the real case needs — IRC's "log in to a registered account"
 * showing an account and a password — and a form that wants a tree is asking to
 * be a layout language. */
export const BridgeToggleFieldSchema = z.strictObject({
	kind: z.literal("toggle"),
	id: FormId,
	label: Label,
	hint: z.optional(Hint),
	on: z.boolean(),
	reveals: z.array(BridgeLeafFieldSchema).check(z.maxLength(MAX_FORM_FIELDS)),
});

export const BridgeFieldSchema = z.union([
	BridgeTextFieldSchema,
	BridgeSecretFieldSchema,
	BridgeToggleFieldSchema,
]);

/** Something the reader can press. The tone picks from the three the product
 * already has: the commitment, the quiet way out, and the one that takes
 * something away. A bridge chooses which of the three, never how one looks. */
export const BridgeActionSchema = z.strictObject({
	id: FormId,
	label: Label,
	/** What the label becomes while this action is in flight. */
	busyLabel: Label,
	tone: z.enum(["primary", "quiet", "danger"]),
	/** Whether pressing this establishes standing a reconnect should restore.
	 *
	 * IRC's link and its disconnect are both remembered: "I am on libera as ada"
	 * and "I am staying Rooms-only" are each a state a reader chose and expects
	 * to find again. An action that merely does something once is not, and a
	 * bridge saying so is what keeps a one-shot act out of a checkpoint. */
	remembered: z.boolean(),
});

export const BridgeFormSchema = z.strictObject({
	/** What this form's answers are shared by, within one directory.
	 *
	 * A bridge decides how far one answer reaches. IRC shares an identity across
	 * every channel on a network, so its scope is the network: linking in one
	 * room links in all of them, and the password typed once serves the rest.
	 * A bridge whose answers are per-room names the room.
	 *
	 * It is the bridge's because only the bridge knows what it shares. Rooms
	 * uses it to decide which saved intent a submission replaces and which
	 * rooms a reconnect restores it to. */
	scope: nonemptyText(MAX_FORM_SCOPE),
	/** What this form is about, in the bridge's words: "Your libera identity". */
	title: nonemptyText(MAX_FORM_TITLE),
	/** Where things stand right now, in the bridge's words. A form is declared
	 * for the state it is in, so this is a sentence rather than a template. */
	said: boundedText(MAX_FORM_SAID),
	fields: z.array(BridgeFieldSchema).check(z.maxLength(MAX_FORM_FIELDS)),
	actions: z.array(BridgeActionSchema).check(z.minLength(1), z.maxLength(MAX_FORM_ACTIONS)),
});

export type BridgeTextField = z.infer<typeof BridgeTextFieldSchema>;
export type BridgeSecretField = z.infer<typeof BridgeSecretFieldSchema>;
export type BridgeToggleField = z.infer<typeof BridgeToggleFieldSchema>;
export type BridgeField = z.infer<typeof BridgeFieldSchema>;
export type BridgeAction = z.infer<typeof BridgeActionSchema>;
export type BridgeForm = z.infer<typeof BridgeFormSchema>;

/** What a reader typed, by field id. Values only: which action was pressed
 * travels beside this, because it is a different kind of fact. */
export const BridgeAnswersSchema = z.record(FormId, boundedText(MAX_FORM_VALUE)).check(
	z.refine((answers) => Object.keys(answers).length <= MAX_FORM_FIELDS * 2),
);
export type BridgeAnswers = z.infer<typeof BridgeAnswersSchema>;

/** Every field a form holds, revealed ones included, in the order drawn.
 *
 * One walk, so the renderer, the submission, and anything checking a form agree
 * about what is in it. A reveal's fields count whether or not the toggle is on:
 * they are part of the form either way, and what the toggle decides is whether
 * a reader is being asked. */
export function bridgeFormFields(form: BridgeForm): BridgeField[] {
	const all: BridgeField[] = [];
	for (const field of form.fields) {
		all.push(field);
		if (field.kind === "toggle") all.push(...field.reveals);
	}
	return all;
}

/** Which of a form's fields Rooms must not keep, by id. */
export function bridgeFormSecretIds(form: BridgeForm): ReadonlySet<string> {
	return new Set(bridgeFormFields(form).filter((field) => field.kind === "secret").map((field) => field.id));
}

/** Whether a form asks for anything Rooms must not keep. The disclosure a
 * reader sees turns on this, so it is answered here rather than by each
 * surface deciding for itself what counts as a credential. */
export function bridgeFormHasSecret(form: BridgeForm): boolean {
	return bridgeFormFields(form).some((field) => field.kind === "secret");
}

/** Split what a reader typed into the half that may be remembered and the half
 * that may not.
 *
 * The declaration decides, so no caller has to hold in mind which of a bridge's
 * fields was a credential. What a `secret` field collected goes to `secrets`,
 * which the session stages for this run alone; everything else goes to
 * `answers`, which is the saved intent a reconnect replays.
 *
 * This exists because the alternative is each surface building the two halves
 * by hand and remembering to leave the password out of one of them. That is a
 * convention, and a convention that fails writes a credential to disk. Take the
 * ids from `bridgeFormSecretIds` so the split and the drawn form read the same
 * declaration. */
export function splitBridgeSubmission(
	secretIds: ReadonlySet<string>,
	typed: BridgeAnswers,
): { answers: BridgeAnswers; secrets: BridgeAnswers } {
	const answers: BridgeAnswers = {};
	const secrets: BridgeAnswers = {};
	for (const [id, value] of Object.entries(typed)) {
		if (secretIds.has(id)) secrets[id] = value;
		else answers[id] = value;
	}
	return { answers, secrets };
}

/** Build one action's submission from a drawn form and what the reader typed.
 *
 * Only the fields a reader was being asked ride: a toggle that is off keeps
 * its reveals out, and the toggle itself never travels because it is
 * disclosure rather than an answer. The primary action carries the answers;
 * the quiet and danger tones stand alone, so pressing a way out never sends
 * a credential the act does not need. A required visible field left empty
 * refuses with the field's own label instead of submitting it. */
export function bridgeFormSubmission(
	form: BridgeForm,
	action: BridgeAction,
	typed: BridgeAnswers,
	toggles: ReadonlySet<string>,
): { answers: BridgeAnswers; secrets: BridgeAnswers } | { why: string } {
	if (action.tone !== "primary") return { answers: {}, secrets: {} };
	const asked: BridgeAnswers = {};
	const visit = (field: BridgeField): string | null => {
		if (field.kind === "toggle") {
			if (!toggles.has(field.id)) return null;
			for (const leaf of field.reveals) {
				const refused = visit(leaf);
				if (refused != null) return refused;
			}
			return null;
		}
		const value = typed[field.id] ?? "";
		if (value === "") {
			if (field.required) return `${field.label} is required.`;
			return null;
		}
		asked[field.id] = value;
		return null;
	};
	for (const field of form.fields) {
		const refused = visit(field);
		if (refused != null) return { why: refused };
	}
	return splitBridgeSubmission(bridgeFormSecretIds(form), asked);
}

/** Read what a reader typed, as it arrives on the wire.
 *
 * A submission is a peer's too — a client is as capable of sending nonsense as
 * a bridge is — so it is bounded and checked before a bridge is asked to make
 * anything of it. What this does not do is decide whether the answers make
 * sense: a form says what a field is called and whether it is required, and
 * what makes a password valid on somebody else's service is that service's. */
export function readBridgeAnswers(raw: string): BridgeAnswers {
	if (raw.length > MAX_FORM_JSON) throw new Error("bridge form answers are too long");
	let decoded: unknown;
	try {
		decoded = JSON.parse(raw);
	} catch {
		throw new Error("bridge form answers are not JSON");
	}
	const parsed = z.safeParse(BridgeAnswersSchema, decoded);
	if (!parsed.success) throw new Error("bridge form answers are not valid");
	return parsed.data;
}
