// Commit a submission to its originating conversation. Rust interprets commands;
// session effects return completion before the UI clears the submitted draft.

import * as store from "../store.ts";
import type { CommandPowers } from "../commands.ts";
import type { Conv } from "../types.ts";
import type { PageProjection } from "../store/core.ts";
import { type ComposerDraft, prepareComposerSend, type PreparedComposerSend } from "./send.ts";
import { PHASE_SAID } from "../text.ts";

export type CommittedComposerSend = Extract<PreparedComposerSend, { kind: "handled" | "send" }>;

/** Interpret a submission and display immediate refusals. `null` means no effect. */
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

/** A disconnected session cannot send chat. */
export const COMPOSER_NOT_CONNECTED = PHASE_SAID.disconnected + ". Your message was not sent.";

/** Empty the conversation that was just composed. A command that has already
 * left or dismissed that conversation is a no-op: last sent and the draft
 * die with it, and whoever came forward keeps theirs. */
export function finishComposerSend(projection: PageProjection, key: string, submitted: string): void {
	store.rememberLastSent(projection, key, submitted);
	store.setDraft(projection, "", key);
	store.clearDraftFiles(projection, key);
}
