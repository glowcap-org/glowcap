// Readiness on the accepted workspace. Each gesture keeps the authority it
// started with while waiting for supervision to complete the selection.
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import { conversationById } from "./conversation_lookup.ts";
import {
	conversationIdentity,
	type DirectIntent,
	type DirectoryIntent,
	type RoomIntent,
	type WorkspaceSnapshot,
} from "./model.ts";

/** Registration must finish for the directory and nickname the user chose. */
export function directoryRegistration(original: DirectoryIntent) {
	return (snapshot: WorkspaceSnapshot | null) => {
		const row = snapshot?.intent.directories.find((row) => row.id === original.id);
		if (
			row == null || row.access !== original.access || row.source !== original.source ||
			row.nick !== original.nick || row.nickAllocation !== original.nickAllocation
		) throw new LocalRefusal("registration-changed");
		return row.name != null && row.assignedNick != null;
	};
}

export interface OfferedDirect {
	access: DirectIntent["access"];
	inbox: DirectIntent["inbox"];
}

export function roomOffer(room: RoomIntent, direct: DirectIntent) {
	const entrance = room.access;
	const { id: roomId, directory, source } = room;
	// The opening owns an incoming DM while its outgoing access is still absent.
	const originalLine = conversationIdentity(direct, null);
	const { id: directId, access, inbox: originalInbox } = direct;
	let inbox = originalInbox;
	let route = access;
	const changed = () => new LocalRefusal("invite-selection-changed");
	if (entrance == null || direct.introduction == null || direct.closed || room.directory !== direct.directory) {
		throw changed();
	}
	const key = JSON.stringify(["offerRoom", roomId, directory, source, entrance, originalLine]);
	const ready = (snapshot: WorkspaceSnapshot | null) => {
		if (snapshot == null) return false;
		const held = conversationById(snapshot, roomId);
		const line = conversationById(snapshot, directId);
		if (
			held?.kind !== "room" || held.access !== entrance || held.directory !== directory ||
			held.source !== source ||
			line?.kind !== "direct" || line.closed || conversationIdentity(line, null) !== originalLine ||
			(access == null && inbox != null && line.inbox !== inbox) || (route != null && line.access !== route)
		) throw changed();
		inbox ??= line.inbox;
		route = line.access;
		return route != null;
	};
	return {
		key,
		get destination(): OfferedDirect {
			return { access: route, inbox };
		},
		accepts(actual: OfferedDirect) {
			return access != null ? access === actual.access : originalInbox == null || originalInbox === actual.inbox;
		},
		ready,
		validate(snapshot: WorkspaceSnapshot) {
			if (!ready(snapshot)) throw changed();
		},
	};
}
