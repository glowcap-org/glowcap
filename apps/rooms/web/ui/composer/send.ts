// One interpretation of a new composer submission for every Rooms controller.

import { validateAttachmentSource } from "../../../lib/attachment.ts";
import { lineCost, MAX_DIRECT_ATTACHMENT_BYTES, MAX_LINE, MAX_MESSAGE_FILES } from "../../../lib/limits.ts";
import { commandIn, type CommandPowers } from "../commands.ts";
import { pickedSource } from "../file_source.ts";
import { lineRoom, tooLong } from "../text.ts";
import type { Conv } from "../types.ts";

export interface ComposerDraft {
	readonly text: string;
	readonly files: readonly File[];
	readonly keeping?: readonly unknown[];
}

export type PreparedComposerSend =
	| { kind: "nothing" }
	| { kind: "handled"; original: string }
	| { kind: "refused"; why: string }
	| { kind: "send"; original: string; text: string; files: readonly File[] };

export function composerLineRefusal(conv: Conv, text: string): string | null {
	const cap = lineRoom(conv, MAX_LINE);
	return lineCost(text) > cap ? tooLong("Message", cap) : null;
}

export function prepareComposerSend(
	conv: Conv | null,
	draft: ComposerDraft,
	powers: CommandPowers,
): PreparedComposerSend {
	const original = draft.text;
	const files = [...draft.files];
	if ((original.trim() === "" && files.length === 0 && draft.keeping == null) || conv == null) {
		return { kind: "nothing" };
	}
	const lineRefusal = composerLineRefusal(conv, original);
	if (lineRefusal != null) return { kind: "refused", why: lineRefusal };

	let text = original;
	const named = commandIn(original);
	if (named != null) {
		const outcome = named.command.run(named.rest, powers, conv);
		if (outcome.kind === "done") return { kind: "handled", original };
		if (outcome.kind === "refused") return { kind: "refused", why: outcome.why };
		if (outcome.kind === "action" && files.length > 0) {
			return { kind: "refused", why: "An /me action cannot carry files. Send them as a separate message." };
		}
		text = outcome.kind === "action" ? `/me ${outcome.text}` : outcome.text;
	}
	if (files.length > MAX_MESSAGE_FILES) {
		return { kind: "refused", why: `A message may carry at most ${MAX_MESSAGE_FILES} files.` };
	}
	if (conv.type === "dm" && files.reduce((sum, file) => sum + file.size, 0) > MAX_DIRECT_ATTACHMENT_BYTES) {
		return {
			kind: "refused",
			why: `A direct message may carry at most ${MAX_DIRECT_ATTACHMENT_BYTES / (1024 * 1024)} MB.`,
		};
	}
	try {
		for (const file of files) validateAttachmentSource(pickedSource(file));
	} catch (error) {
		return { kind: "refused", why: error instanceof Error ? error.message : String(error) };
	}
	return { kind: "send", original, text, files };
}
