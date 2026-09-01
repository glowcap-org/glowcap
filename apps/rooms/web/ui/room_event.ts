// Presentation classification for structured room events.

export function isStateOnlyRoomEvent(
	text: string,
	presence: { readonly kind: string } | null | undefined,
	attachments: readonly unknown[],
): boolean {
	return presence?.kind === "seat" && text === "" && attachments.length === 0;
}
