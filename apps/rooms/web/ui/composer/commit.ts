// What both Rooms controllers do with an interpreted composer submission
// before they differ.
//
// `send.ts` is the one reading of a line. This file is the one store effect
// that follows: a refusal is delivered here, and a finished submission empties
// the conversation that was composed — not whoever is on screen after a
// command that left. Local and attached send then diverge on the wire.

import * as store from "../store.ts";
import type { CommandPowers } from "../commands.ts";
import type { Conv } from "../types.ts";
import type { PageProjection } from "../store/core.ts";
import { type ComposerDraft, prepareComposerSend, type PreparedComposerSend } from "./send.ts";
import { PHASE_SAID } from "../text.ts";

export type CommittedComposerSend = Extract<PreparedComposerSend, { kind: "handled" | "send" }>;

/** Interpret a composer submission. Refusals are delivered here so both
 * controllers explain a rejected line the same way. `null` means stop:
 * nothing to do, or the refusal already spoke. */
export function interpretComposerSend(
	projection: PageProjection,
	conv: Conv | null,
	draft: ComposerDraft,
	powers: CommandPowers,
): CommittedComposerSend | null {
	const prepared = prepareComposerSend(conv, draft, powers);
	if (prepared.kind === "nothing") return null;
	if (prepared.kind === "refused") {
		store.deliverActive(projection, store.sysItem(projection, prepared.why));
		return null;
	}
	return prepared;
}

/** Chat still needs the wire. A tab command does not: it already ran. */
export const COMPOSER_NOT_CONNECTED = PHASE_SAID.disconnected + ". Your message was not sent.";

/** Empty the conversation that was just composed. A command that has already
 * left or dismissed that conversation is a no-op: last sent and the draft
 * die with it, and whoever came forward keeps theirs. */
export function finishComposerSend(projection: PageProjection, key: string, submitted: string): void {
	store.rememberLastSent(projection, key, submitted);
	store.setDraft(projection, "", key);
	store.clearDraftFiles(projection, key);
}
