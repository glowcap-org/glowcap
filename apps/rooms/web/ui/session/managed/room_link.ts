// A room link stages one workspace revision: the nickname the directory is
// entered under, the directory's custody when the page holds none, and the
// room's authority. One gesture, so supervisors cannot replace its inbox
// between two page mutations, and a refused fetch changes no directory.
import type { JoinNicknameIntent } from "../../controller/session.ts";
import { applicationModule } from "../../application.ts";
import { managedSessionText as managedText } from "../../../../lib/text/managed_session.ts";
import { type Coordinate, type FieldKey, fieldKey, type WorkspaceSnapshot } from "./model.ts";

/** Stage the room `uri` named `name` under `directory` in `snapshot`, which
 * the caller then acquires. Returns the new conversation's id, the field
 * holding the session access it is acquired under, and the imports. */
export function stageRoomLink(
	snapshot: WorkspaceSnapshot,
	directory: string,
	uri: string,
	name: string,
	selection: { route: string; nick: JoinNicknameIntent; home: boolean },
): { id: string; source: FieldKey; imports: { coordinate: Coordinate; uri: string }[] } {
	const id = crypto.randomUUID();
	const access = fieldKey();
	const source = fieldKey();
	const imports = [{ coordinate: { role: "roomAccess", key: access }, uri }];
	const nick = selection.nick.kind === "exact" ? selection.nick.name : selection.nick.base;
	const nickAllocation = selection.nick.kind === "exact" ? "exact" : "automatic";
	const row = snapshot.intent.directories.find((row) => row.id === directory);
	if (row == null) {
		const directoryAccess = fieldKey();
		imports.push({
			coordinate: { role: "directoryAccess", key: directoryAccess },
			uri: applicationModule().directoryCapability(selection.route),
		});
		if (selection.home) { for (const directory of snapshot.intent.directories) directory.home = false; }
		snapshot.intent.directories.push({
			id: directory,
			access: directoryAccess,
			source,
			home: selection.home,
			nick,
			nickAllocation,
			standing: null,
		});
	} else if (row.nick !== nick || row.nickAllocation !== nickAllocation) {
		row.nick = nick;
		row.nickAllocation = nickAllocation;
		delete row.assignedNick;
	}
	snapshot.intent.conversations.push({
		kind: "room",
		id,
		directory,
		name: name || managedText.sharedRoom,
		source,
		access,
		control: null,
		reconnect: "requested",
		standing: null,
		draft: "",
	});
	return { id, source, imports };
}
