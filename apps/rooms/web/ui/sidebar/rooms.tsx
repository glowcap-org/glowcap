// The rooms section's rows, and the list they make.
//
// Three kinds of row share this list because they are three kinds of somewhere
// you are: a room this tab is in, a room somebody handed it and it has not
// answered yet, and a directory it is on with nothing open. Its sibling status-allow: pending state or quoted runtime label
// dms.tsx holds the same for the direct lines, and the rail itself only decides
// which sections there are.

import {
	CAUGHT_UP,
	type Conv,
	type DirId,
	dirMarkIn,
	type DirView,
	type Invitation,
	type RoomConv,
	type Unread,
} from "../types.ts";
import { dirWhere, nothingWhilePaused } from "../text.ts";
import { useRoomsState, useSessionPaused } from "../hooks.ts";
import { useRoomsBrowser } from "../controller/browser.ts";
import { dirRow, inviteRow, type RailRow, roomRow, unreadCount } from "./filter.ts";
import { Empty, EmptyDirRow, heldBack, InviteRow, nothingMatches, PendingRoomRow, RoomRow } from "./rows.tsx";
import { bridgedOrigin } from "../store.ts";
import { railReachingDirectory, railRoomsAppearHere } from "../../../lib/text/rail.ts";

/** The rooms this tab is in, across every directory, in the order it entered
 * them, and under them the directories it is on with nothing open.
 *
 * Insertion order and nothing else. Nobody else's activity can move a row, and
 * joining appends rather than inserting into the middle, so the list a reader
 * learned stays the list they have. The filter takes rows out of it and puts
 * them back, and that is all it does: a row hidden and shown again comes back
 * where it was.
 *
 * Every row says which directory it is on and wears that directory's color,
 * once there is more than one to tell apart, and says how that directory is
 * doing whenever it is not simply connected. The words are the row's own,
 * because the directory is a fact about the room rather than about where the
 * row happens to sit, and pressing them opens that directory. */
export function YourRooms(
	{
		canInteract,
		convs,
		unreads,
		dirs,
		home,
		activeKey,
		empty,
		invites,
		shows,
		onPick,
		onLeave,
		onAbout,
		onJoinOn,
		onLeaveDir,
		onTake,
		onDrop,
	}: {
		canInteract: boolean;
		convs: ReadonlyMap<string, Conv>;
		unreads: ReadonlyMap<string, Unread>;
		dirs: ReadonlyMap<DirId, DirView>;
		home: DirId | null;
		activeKey: string | null;
		/** Rooms handed to this tab and not answered yet.  status-allow: pending state or quoted runtime label */
		invites: readonly Invitation[];
		onTake: (id: string) => Promise<void>;
		onDrop: (id: string) => void | Promise<void>;
		/** Directories held with nothing open on them, listed under the rooms so a
		 * connection nobody can see is not a connection nobody can end. */
		empty: DirView[];
		/** Whether the reader is looking at this row. Every kind of row in the
		 * rail is asked the same way. */
		shows: (row: RailRow) => boolean;
		onPick: (conv: RoomConv) => void;
		onLeave: (key: string) => void | Promise<void>;
		onAbout: (dir: DirId) => void;
		onJoinOn: (dir: DirId) => void;
		onLeaveDir: (dir: DirId) => void | Promise<void>;
	},
) {
	const rooms = [...convs.values()].filter((conv): conv is RoomConv => conv.type === "room");
	const target = useRoomsState((state) => state.navigationTarget);
	const browser = useRoomsBrowser();
	// A typed name is still discovery, even if a saved room has the same name.
	// Its temporary row cannot claim that conversation's identity before lookup.
	const pending = target?.kind === "room" ? target : null;
	const paused = useSessionPaused();
	const unreadOf = (key: string) => unreads.get(key) ?? CAUGHT_UP;
	const held = invites.filter((invite) => shows(inviteRow(invite)));
	const open = rooms.filter((conv) => shows(roomRow(conv, unreadOf(conv.key))));
	const bare = empty.filter((dir) => shows(dirRow(dir, home)));
	const total = invites.length + rooms.length + empty.length;
	const hidden = total - held.length - open.length - bare.length;
	if (total === 0 && pending == null) {
		return (
			<Empty
				text={paused ? nothingWhilePaused : dirs.size === 0 ? railReachingDirectory : railRoomsAppearHere}
			/>
		);
	}
	if (hidden === total && pending == null) {
		return <Empty text={nothingMatches} />;
	}
	return (
		<>
			{held.map((invite) => (
				<InviteRow
					key={invite.id}
					canInteract={canInteract}
					invite={invite}
					where={dirWhere(invite.dir, home, dirs)}
					onTake={onTake}
					onDrop={onDrop}
				/>
			))}
			{open.map((conv) => (
				<RoomRow
					key={conv.key}
					canInteract={canInteract}
					conv={conv}
					unread={unreadCount(unreadOf(conv.key))}
					here={activeKey === conv.key}
					where={dirWhere(conv.dir, home, dirs)}
					home={home}
					phase={dirs.get(conv.dir)?.session ?? "disconnected"}
					bridgedFrom={bridgedOrigin(dirs.get(conv.dir), conv.publicationId)}
					onPick={onPick}
					onLeave={onLeave}
					onAbout={onAbout}
				/>
			))}
			{pending != null && <PendingRoomRow name={pending.name} onCancel={browser.cancelConversationOpening} />}
			{bare.map((dir) => (
				<EmptyDirRow
					key={dir.id}
					canInteract={canInteract}
					dir={dir}
					home={home}
					mark={dirMarkIn(dir.id, home, dirs)}
					onJoinOn={onJoinOn}
					onLeave={onLeaveDir}
					onAbout={onAbout}
				/>
			))}
			{hidden > 0 && <Empty text={heldBack(hidden)} />}
		</>
	);
}
