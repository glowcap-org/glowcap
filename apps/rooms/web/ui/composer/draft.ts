// Pure composer transformations shared by local and attached sessions.

export function draftWithMention(text: string, who: string): string {
	const gap = text !== "" && !/\s$/.test(text) ? " " : "";
	return `${text}${gap}@${who} `;
}

export function recalledDraft(
	draft: { readonly changing?: number; readonly files: readonly unknown[]; readonly text: string },
	last: string | undefined,
): string | null {
	if (draft.changing != null || draft.files.length > 0 || draft.text.trim() !== "") return null;
	return last ?? null;
}
