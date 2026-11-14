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
const BridgeTextFieldSchema = z.strictObject({
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
const BridgeSecretFieldSchema = z.strictObject({
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
const BridgeToggleFieldSchema = z.strictObject({
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
const BridgeActionSchema = z.strictObject({
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
const BridgeAnswersSchema = z.record(FormId, boundedText(MAX_FORM_VALUE)).check(
	z.refine((answers) => Object.keys(answers).length <= MAX_FORM_FIELDS * 2),
);
export type BridgeAnswers = z.infer<typeof BridgeAnswersSchema>;
