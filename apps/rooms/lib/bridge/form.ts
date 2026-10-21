// A form a bridge describes and Rooms draws.
//
// Linking an identity on a bridged service asks for different things on every
// service: IRC wants a nick and optionally a registered account and password,
// XMPP wants a JID and a password, and a Matrix bridge that puppets its users
// wants nothing at all. Rooms cannot know those, and a bridge cannot draw a
// form, so the bridge says what it needs and Rooms decides what that looks
// like.
//
// A claim about the service is the bridge's to make. A claim about what Rooms
// does with what you type is Rooms' to make, and the bridge may not reword or
// omit it.
//
// There is no template language and no way to say "when this, show that"
// beyond one toggle. A bridge that needs a different form for a different state
// declares a different form. It already knows the state, so a language for
// deferring that decision would add a second interface nobody can see the
// whole of.

import * as z from "zod/mini";
import {
	MAX_FORM_ACTIONS,
	MAX_FORM_FIELDS,
	MAX_FORM_HINT,
	MAX_FORM_LABEL,
	MAX_FORM_SAID,
	MAX_FORM_SCOPE,
	MAX_FORM_TITLE,
	MAX_FORM_VALUE,
} from "../limits.ts";
import { boundedText, nonemptyText } from "../schema.ts";

/** An identifier a bridge gives one of its fields or actions. It is never
 * shown. It is what a submission names. */
const FormId = nonemptyText(32).check(z.regex(/^[a-z][a-z0-9-]*$/));

const Label = nonemptyText(MAX_FORM_LABEL);
const Hint = boundedText(MAX_FORM_HINT);

/** A line of text. It gets identifier treatment when drawn, since a mobile
 * keyboard that capitalizes a nick has changed it, and every field any real
 * bridge has asked for so far is an identifier and not prose. */
export const BridgeTextFieldSchema = z.strictObject({
	kind: z.literal("text"),
	id: FormId,
	label: Label,
	hint: z.optional(Hint),
	/** A ghosted example of a good answer, in the bridge's words:
	 * `irc.libera.chat` for a server, a nick the reader might pick. It is shown
	 * and never submitted, so it says what a value looks like without becoming one. */
	placeholder: z.optional(Hint),
	/** A fixed mark the bridge always puts in front of this value, drawn joined to
	 * the box so a reader types the part that varies: IRC's `#` before a channel.
	 * It is decoration and not part of what is typed, and the bridge reads the
	 * submitted value knowing it owns the mark. */
	prefix: z.optional(nonemptyText(8)),
	/** What it starts as. A bridge fills this with what it already knows, so a
	 * reader corrects rather than retypes. */
	value: z.optional(boundedText(MAX_FORM_VALUE)),
	required: z.boolean(),
});

/** A line of text Rooms will not keep.
 *
 * There is no starting value, because offering one would mean Rooms had kept a
 * credential in order to put it back. What `secret` means is a promise Rooms
 * makes, not a hint the bridge gives. See the renderer. */
export const BridgeSecretFieldSchema = z.strictObject({
	kind: z.literal("secret"),
	id: FormId,
	label: Label,
	hint: z.optional(Hint),
	/** A ghosted example, shown and never submitted. A secret has no starting
	 * value, but it may still say what shape of answer it wants. */
	placeholder: z.optional(Hint),
	required: z.boolean(),
});

const BridgeLeafFieldSchema = z.union([BridgeTextFieldSchema, BridgeSecretFieldSchema]);

/** A checkbox that may reveal a few fields under it.
 *
 * Exactly one level deep, and unrepresentable otherwise: a reveal holds leaves
 * and a leaf is not a toggle, so there is no nesting to bound at runtime. One
 * level is what the real case needs (IRC's "log in to a registered account"
 * showing an account and a password), and a form that wants a tree is asking
 * to be a layout language. */
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
 * something away. A bridge chooses which of the three and never how one looks. */
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
	 * to find again. An action that does something once is not, and a bridge
	 * saying so keeps a one-shot act out of a checkpoint. */
	remembered: z.boolean(),
	/** When present, pressing this opens a second step before it runs, for an
	 * act that takes something away: IRC's disconnect ends a link. The words are
	 * the bridge's (the sentence about what is lost, the way out, and the
	 * commitment), in the reader's terms. Absent for an ordinary act. */
	confirm: z.optional(z.strictObject({
		say: nonemptyText(MAX_FORM_SAID),
		keep: Label,
		commit: Label,
	})),
});

export const BridgeFormSchema = z.strictObject({
	/** What this form's answers are shared by, within one directory.
	 *
	 * A bridge decides how far one answer reaches. IRC shares an identity across
	 * every channel on a network, so its scope is the network: linking in one
	 * room links in all of them, and the password typed once serves the rest.
	 * A bridge whose answers are per-room names the room.
	 *
	 * The bridge owns it because only the bridge knows what it shares. Rooms
	 * uses it to decide which saved intent a submission replaces and which
	 * rooms a reconnect restores it to. */
	scope: nonemptyText(MAX_FORM_SCOPE),
	/** What this form is about, in the bridge's words: "Your libera identity". */
	title: nonemptyText(MAX_FORM_TITLE),
	/** Where things stand right now, in the bridge's words. A form is declared
	 * for the state it is in, so this is a sentence and not a template. */
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

/** What a reader typed, by field id. Values only. Which action was pressed
 * travels beside this, because it is a different kind of fact. */
export const BridgeAnswersSchema = z.record(FormId, boundedText(MAX_FORM_VALUE)).check(
	z.refine((answers) => Object.keys(answers).length <= MAX_FORM_FIELDS * 2),
);
export type BridgeAnswers = z.infer<typeof BridgeAnswersSchema>;

/** Every field a form holds, revealed ones included, in the order drawn.
 *
 * One walk, so the renderer, the submission, and anything checking a form agree
 * about what is in it. A reveal's fields count whether or not the toggle is on.
 * They are part of the form either way, and the toggle decides only whether a
 * reader is being asked. */
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
 * reader sees turns on this, so it is answered here and no surface decides for
 * itself what counts as a credential. */
export function bridgeFormHasSecret(form: BridgeForm): boolean {
	return bridgeFormFields(form).some((field) => field.kind === "secret");
}

/** Split what a reader typed into the half that may be remembered and the half
 * that may not.
 *
 * The declaration decides, so no caller has to remember which of a bridge's
 * fields was a credential. What a `secret` field collected goes to `secrets`,
 * which the session stages for this run alone. Everything else goes to
 * `answers`, which is the saved intent a reconnect replays.
 *
 * Without this, each surface would build the two halves by hand and have to
 * remember to leave the password out of one of them. That is a convention, and
 * a convention that fails writes a credential to disk. Take the ids from
 * `bridgeFormSecretIds` so the split and the drawn form read the same
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
 * A toggle's state travels as `"on"` or `""`, because a toggle is an answer in
 * its own right: IRC's TLS decides whether the connection is encrypted, not
 * only whether more fields show. Its reveals ride only when it is on, so a
 * disclosure toggle keeps its hidden fields out when off while its state is
 * recorded either way. The primary action carries the answers. The quiet and
 * danger tones stand alone, so pressing a way out never sends a credential the
 * act does not need. A required visible field left empty refuses with the
 * field's label and is not submitted. */
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
			const on = toggles.has(field.id);
			asked[field.id] = on ? "on" : "";
			if (!on) return null;
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
