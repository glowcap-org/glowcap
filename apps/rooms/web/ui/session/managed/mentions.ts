// Both the command and room controls write one complete selection for the original room.
import { MAX_ROOM_AUDIENCE } from "../../../../lib/application_data.ts";
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import { applicationModule } from "../../application.ts";
import * as store from "../../store.ts";

function selection(projection: store.PageProjection, key: string, names: readonly string[]) {
	const room = store.getConv(projection, key);
	if (
		room?.type !== "room" || room.membershipKind !== "participant" || (names.length && room.membership !== "joined")
	) {
		throw new LocalRefusal("mentions-room");
	}
	if (!names.length) return { room, canonical: [] };
	if (names.length > MAX_ROOM_AUDIENCE) throw new LocalRefusal("mentions-limit");
	const nick = store.dirNick(projection, room.dir).toLowerCase();
	const members = new Map(
		[...store.membersOf(projection, key)]
			.filter(([, member]) => member.online)
			.map(([name]) => [name.toLowerCase(), name]),
	);
	const selected = new Set<string>();
	for (const wanted of names) {
		if (!applicationModule().roomAudienceName(wanted)) throw new LocalRefusal("mentions-name");
		const folded = wanted.toLowerCase();
		const member = members.get(folded);
		if (!member) throw new LocalRefusal("mentions-offline");
		if (folded === nick || selected.has(member)) throw new LocalRefusal("mentions-members");
		selected.add(member);
	}
	return { room, canonical: [...selected] };
}

export async function setRoomMentions(
	projection: store.PageProjection,
	key: string,
	names: readonly string[],
	write: (id: string, names: string[], validate: () => void) => Promise<unknown>,
): Promise<readonly string[]> {
	const { room, canonical } = selection(projection, key, names);
	await write(room.persistId, canonical, () => {
		// A roster may change while the command waits to acquire a workspace revision.
		if (selection(projection, key, canonical).room.persistId !== room.persistId) {
			throw new LocalRefusal("command-selection-changed");
		}
	});
	return canonical;
}
