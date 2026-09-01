// Asking a membership for its bridge's form, and answering it.
//
// The vocabulary next door says what a form *is*; this is the pair of verbs
// that carry one. They are separate because a form crosses as JSON and a room
// carries positional arguments, so somebody has to own the encoding, and it is
// neither the room client nor the shape.
//
// Both halves check what they receive. A bridge is trusted by whoever installed
// it and a client is trusted by nobody, and both are peers: what arrives is
// bounded and parsed before anything is built from it.

import type { Ref, Session } from "@pancake/runtime";
import * as z from "zod/mini";
import { ask } from "../ask.ts";
import { type BridgeAnswers, type BridgeForm, BridgeFormSchema } from "./form.ts";
import { MAX_FORM_JSON } from "../limits.ts";
import { BRIDGE_FORM, SUBMIT_BRIDGE_FORM } from "../protocol_irc.ts";

/** What form this membership's bridge wants drawn, or null when it wants none.
 *
 * Asked when a reader opens the surface rather than pushed on every change,
 * because a form is declared for the state it is in: a bridge that has moved on
 * answers differently the next time somebody looks. A room with no bridge
 * refuses the verb, which reads as no form at all. */
export async function askBridgeForm(session: Session, membership: Ref): Promise<BridgeForm | null> {
	const said = await ask(session, membership, BRIDGE_FORM, [], "the room did not answer its bridge form");
	if (said == null || said === "") return null;
	if (typeof said !== "string" || said.length > MAX_FORM_JSON) {
		throw new Error("the room answered an invalid bridge form");
	}
	let decoded: unknown;
	try {
		decoded = JSON.parse(said);
	} catch {
		throw new Error("the room answered a bridge form that is not JSON");
	}
	const parsed = z.safeParse(BridgeFormSchema, decoded);
	if (!parsed.success) throw new Error("the room answered an invalid bridge form");
	return parsed.data;
}

/** Press one of that form's actions with what the reader typed. The answer is
 * the bridge's own sentence about what happened. */
export async function answerBridgeForm(
	session: Session,
	membership: Ref,
	action: string,
	answers: BridgeAnswers,
): Promise<string> {
	const said = await ask(
		session,
		membership,
		SUBMIT_BRIDGE_FORM,
		[action, JSON.stringify(answers)],
		"the room did not answer the bridge form",
	);
	return typeof said === "string" ? said : "";
}
