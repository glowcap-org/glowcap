// The mark a room wears in front of its name.

import type { ReactNode } from "react";
import { Icon } from "./icons.tsx";
import type { RoomPreset } from "./room_policy.ts";

/** The mark for a room in this standing: the hash for a public name, the eye
 * for a room that is listed but offers only watching, the lock for one the
 * directory does not list at all.
 *
 * One answer, because the rail, the topbar, the conversation card, the log and
 * the panel that names a new room all draw it, and a reader compares them. The
 * panel drew all three while the rest drew two, so a moderated room was a
 * public one everywhere except the panel that made it.
 *
 * Not `roomPresetFace`'s icon, which is the access control's own vocabulary: a
 * public room's mark is the hash it is called by, not a picture of a group. */
export function roomMarkGlyph(standing: RoomPreset, size: number): ReactNode {
	if (standing === "private") return <Icon name="lock" size={size} />;
	if (standing === "moderated") return <Icon name="observer" size={size} />;
	return "#";
}

/** What a mark that stands for this room should say to a reader who stops on
 * it. Public names need no gloss: the hash is the name's own punctuation. */
export function roomMarkTitle(standing: RoomPreset): string | undefined {
	if (standing === "private") {
		return "A private room: it is not listed, and only people it was handed to are here";
	}
	if (standing === "moderated") {
		return "A moderated room: it is listed, and its public name offers watching rather than speaking";
	}
	return undefined;
}
