// The rail: the rooms this tab is in and the direct conversations it has open,
// as two lists. They are the rail's two lists whatever this tab holds, because
// rooms and direct lines are different kinds of thing rather than different
// places, and a directory is something a row is on rather than a box a row
// lives in. The reader's own seat under the lists is next door in
// `sidebar/Foot.tsx`, because it is about the reader rather than about what
// they hold.
//
// Both "+" fields behave identically — open one and the other closes, click
// away or press Escape and it puts itself away and hands focus back — so they
// are one component held in two places rather than two sets of handlers kept in
// step.
//
// The rooms heading is also the filter, which is how much of the rail the
// reader is looking at. What it asks belongs to the rail rather than to either
// list, because the questions are about rows and both lists hold rows. It hangs
// off that heading because a control with a line of its own over both lists read
// as a third heading with nothing under it. What it never does is move a row: it
// hides and shows, and the order underneath is the reader's.

import { Link } from "react-router";
import { memo, useEffect, useMemo, useState } from "react";
import { usePeer } from "./peer.ts";
import { implied, named } from "./intent.ts";
import { destination, type JoinAnswers } from "./joining.ts";
import {
	type Conv,
	type DirId,
	dirId,
	type DirView,
	type Invitation,
	liveRoomNames,
	type SessionPhase,
} from "./types.ts";
import { DmRows } from "./sidebar/dms.tsx";
import { YourRooms } from "./sidebar/rooms.tsx";
import { RailFilter } from "./sidebar/Filter.tsx";
import {
	askedNothing,
	dirRow,
	dmRow,
	type FilterAnswers,
	inviteRow,
	railCriteria,
	type RailRow,
	roomRow,
	rowShows,
} from "./sidebar/filter.ts";
import { DirectoryPicks, typeAnotherAddress } from "./DirectoryPicks.tsx";
import { Wordmark } from "./icons.tsx";
import { IconButton } from "./IconButton.tsx";
import { SettingsButton } from "./SettingsButton.tsx";
import { MAX_NICK, MAX_ROOM } from "../../lib/limits.ts";
import { Foot } from "./sidebar/Foot.tsx";
import { RailSection } from "./sidebar/Section.tsx";
import type { AddField } from "./sidebar/NamePanel.tsx";
function SidebarPane(
	{
		cardUp,
		convs,
		dirs,
		homeDir,
		activeKey,
		acting,
		join,
		railShown,
		mobile,
		session,
		emptyDirs,
		standing,
		invites,
		settingsOpen,
	}: {
		/** The join card is the workarea: no conversation open and nothing
		 * else standing in the content cell. App owns what that cell shows,
		 * so App says. */
		cardUp: boolean;
		convs: ReadonlyMap<string, Conv>;
		/** Every directory this tab holds, in the order it opened them. */
		dirs: ReadonlyMap<DirId, DirView>;
		/** Those of them with nothing open, which get a row of their own: holding
		 * one is a session and a registered name whatever is open on it, and that
		 * state used to have nowhere to appear. */
		emptyDirs: DirView[];
		homeDir: DirId | null;
		activeKey: string | null;
		/** The directory the page is acting on, from the store's one answer: the
		 * one the open conversation is on, or the first this tab holds while the
		 * join card is up. Null before any has been reached. */
		acting: DirId | null;
		/** The join card's answers. While the card is the workarea the rail's
		 * room field is a second view of the same form rather than a form of
		 * its own, so it reads the one resolved answer rather than the state
		 * behind it. */
		join: JoinAnswers;
		railShown: boolean;
		mobile: boolean;
		session: SessionPhase;
		/** Where this reader stands everywhere, which the foot both shows and
		 * sets. */
		standing: string;
		/** Rooms somebody handed this tab and it has not answered yet. */
		invites: readonly Invitation[];
		settingsOpen: boolean;
	},
) {
	// Whether this tab is in any room, which is what the direct-message section
	// needs: a direct line starts from a roster, and any room's roster will do.
	const inARoom = [...convs.values()].some((conv) => conv.type === "room");
	// Which directory the section's "+" names a room on: the one the page is
	// acting on, which the store answers once for everything that asks. Reaching
	// a room on a directory this tab has not opened is the join card's job, and
	// the card is where the locator lives.
	const here = acting ?? dirId("");
	// At most one "+" field is open, which is the rail's rule to keep rather than
	// each section's, so it is one value here instead of a flag in each.
	const peer = usePeer();
	// How much of the rail this reader is looking at. It is a view and it is
	// theirs, so it is held here rather than in the store: nothing outside the
	// rail reads it, and no other tab is looking through this reader's eyes.
	const [filter, setFilter] = useState<FilterAnswers>(askedNothing);
	const criteria = useMemo(() => railCriteria(dirs, homeDir), [dirs, homeDir]);
	const shows = (row: RailRow) => rowShows(criteria, filter, row);
	// Counted over every row the rail holds, in one place, because the filter is
	// one control over both lists and has to answer for both. Each list still
	// decides its own rows, so nothing here says which list a row landed in.
	const railRows = [
		...invites.map(inviteRow),
		...[...convs.values()].map((conv) => conv.type === "room" ? roomRow(conv) : dmRow(conv)),
		...emptyDirs.map((dir) => dirRow(dir, homeDir)),
	];
	const shown = railRows.filter(shows).length;
	// With the join card up, this panel is a second view of it: one room name,
	// one lock, and one destination. So where a room lands is the card's locator
	// field, resolved exactly as the card resolves it, rather than the directory
	// the reader was last standing on — the panel and the card cannot state two
	// destinations for the one name being typed into both.
	//
	// With a room open there is no card to be a view of, and standing in a room
	// on a directory has one reading: the next room named here goes there. That
	// is the same reading `showRoom` files as an implied locator when a room it
	// cannot open puts the card up, so the two surfaces still agree.
	// Whether the join card is the workarea, which is when this rail's field
	// is a second view of it. Not re-derived from the selection: with /ops
	// standing in the cell nothing is selected and the card is still not up.
	const linked = cardUp;
	const aimed = linked
		? destination(join.locator.value, peer.directoryId(join.locator.value.trim()), dirs, homeDir, "this directory")
		// The same classification, asked of a directory already in hand rather
		// than of a field: naming the answer twice is how the panel and the card
		// came to disagree, and this branch is the copy that was left behind.
		: destination(here, here, dirs, homeDir, "this directory");
	// At most one "+" field is open anywhere in the rail, so this is the open
	// panel's own id rather than a flag per place that could hold one.
	const [open, setOpen] = useState<string | null>(null);
	const opener = (panel: string) => (shown: boolean) => setOpen(shown ? panel : null);
	// Landing in a conversation puts an open panel away: what was typed into it
	// was aimed somewhere else. Coming back the other way leaves it standing,
	// because the thing that brought the join card up is usually this panel's
	// own destination line, and taking the field away at the moment it gains
	// its other half is the opposite of what that press meant.
	useEffect(() => {
		if (activeKey !== null) setOpen(null);
	}, [activeKey]);

	// What the two fields can finish. Rooms come from the directory the field is
	// aimed at, since that is where the room will land and a name advertised
	// somewhere else would open a different room. People come from the rosters
	// this tab can see, so the name is spelled the way its directory granted it,
	// filtered to those a directory says are reachable and never including the
	// reader, who cannot be written to.
	const roomOffers = liveRoomNames(dirs.get(here)?.liveRooms ?? new Map());
	const dmOffers = (() => {
		const names = new Map<string, string>();
		for (const conv of convs.values()) {
			if (conv.type !== "room") continue;
			const dir = dirs.get(conv.dir);
			if (dir === undefined) continue;
			for (const name of conv.members.keys()) {
				const key = name.toLowerCase();
				if (key === dir.nick.toLowerCase()) continue;
				if (!dir.dmablePeers.has(key)) continue;
				names.set(key, name);
			}
		}
		return [...names.values()];
	})();

	// The one field that names a room, whatever this tab holds. Where the room
	// lands is stated on the field rather than decided by where the field sits,
	// which is what lets the destination be changed without leaving the rail.
	const roomField: AddField = {
		id: "newRoom",
		open: open === "newRoom",
		// Said whatever this tab holds, because the line under the field says it
		// whatever this tab holds; a label that named the destination only
		// sometimes left a listener with less than a reader had.
		label: "Create or open a room in " + aimed.name,
		placeholder: "room name",
		max: MAX_ROOM,
		noun: "room name",
		canAdd: true,
		canBePrivate: true,
		offers: roomOffers,
		sigil: "#",
		onOpen: opener("newRoom"),
		onSubmit: (name: string, isPrivate: boolean) =>
			isPrivate ? peer.openPrivateRoom(here, name) : peer.pickRoom(here, name),
		onError: (text: string) => peer.toast("failure", text),
		// With the join card on screen, this field and that form name one room:
		// one draft, one lock, and Enter submits the form itself, so the locator
		// and name the reader filled in over there are honored rather than
		// silently dropped. The form's id is a pinned selector, and
		// `requestSubmit` is the platform's own way to submit it.
		link: linked
			? {
				form: "#joinForm",
				value: join.room.value,
				secret: join.secret.value,
				onValue: (value: string) => peer.editJoin({ room: value }),
				onSecret: (secret: boolean) => peer.editJoin({ secret }),
			}
			: undefined,
		// With the card up the destination is one of this tab's own directories
		// away, so it is changed here rather than by sending the reader to the
		// card to change it: picking writes the card's locator exactly as typing
		// in this field writes the card's room name, and the panel's line, the
		// card's field and the card's stripe all move together because all three
		// read that one answer. An address this tab does not hold has nowhere
		// here to be typed, so that last row hands over the field where it can be.
		//
		// A pick is an edit and files no act, which is what lets it leave every
		// other answer standing: an act would supersede the one the reader is
		// answering and take the room name in this very field with it.
		picks: linked
			? (close: () => void) => (
				<DirectoryPicks
					className="where-picks"
					locator={join.locator.value}
					dirs={dirs}
					homeDir={homeDir}
					onPick={(locator) => {
						peer.editJoin({ locator });
						close();
					}}
					onElsewhere={() =>
						typeAnotherAddress(() => {
							close();
							// The card is already the surface here, so nothing is
							// filed. On a phone it is still a screen away, which is
							// what this brings forward; on a wide window it is
							// already beside this panel, which stays where it is.
							peer.showJoinCard();
						})}
				/>
			)
			: undefined,
		// Without a card there is nothing to be a second view of, so this press is
		// what puts one there, and that is an act: it carries the room being named
		// and the directory this panel was aimed at, so nothing has to be picked
		// again. It ends where the menu's last row ends, because a reader who
		// pressed "change directory" is going to type one, and arriving in front
		// of a card with the caret nowhere asks them to find the field the press
		// was about.
		onElsewhere: linked ? undefined : (name: string) =>
			typeAnotherAddress(() =>
				// The address, not the identity: an act's locator is something to
				// dial, and an identity is what is left after the routing hints have
				// been taken off it.
				peer.reachFor({
					source: "press",
					room: named(name),
					locator: implied(peer.dirAddress(here)),
				})
			),
		// Stated whether or not this tab holds more than one directory. A room row
		// stays quiet about its directory while there is only one, because there
		// is nothing to tell apart; this panel is the one moment the answer is
		// still open, so it says where the room is going even then.
		where: aimed,
	};

	return (
		<nav className="sidebar" aria-label="Rooms">
			<div className="workspace">
				<IconButton
					id="railToggle"
					className="mark-btn"
					icon="mark"
					label="Rooms and direct messages"
					size={mobile ? "large" : "normal"}
					title={railShown ? "Hide the rooms list" : "Show the rooms list"}
					aria-pressed={railShown}
					onClick={() => peer.showRail(false)}
				/>
				<Link className="wordmark-link" to="/" aria-label="The front page">
					<Wordmark />
				</Link>
				{railShown && <SettingsButton id="settingsBtn" mobile={mobile} settingsOpen={settingsOpen} />}
			</div>
			<div className="sidebar-body">
				<RailSection
					title="Your rooms"
					listId="roomList"
					field={roomField}
					heading={(title) => (
						<RailFilter
							title={title}
							criteria={criteria}
							answers={filter}
							shown={shown}
							total={railRows.length}
							onAnswers={setFilter}
						/>
					)}
				>
					<YourRooms
						convs={convs}
						dirs={dirs}
						home={homeDir}
						activeKey={activeKey}
						empty={emptyDirs}
						invites={invites}
						shows={shows}
						onTake={peer.acceptInvite}
						onDrop={peer.declineInvite}
						onPick={(conv) => peer.pickRoom(conv.dir, conv.id, conv.key)}
						onLeave={peer.leaveRoom}
						onAbout={peer.aboutDirectory}
						// The address, not the identity: what a row hands over has to be
						// dialable, and the hints are part of what makes it so.
						onJoinOn={(dir) => peer.reachFor({ source: "press", locator: named(peer.dirAddress(dir)) })}
						onLeaveDir={peer.leaveDirectory}
					/>
				</RailSection>
				<RailSection
					className="dms"
					title="Direct messages"
					listId="dmList"
					field={{
						id: "newDm",
						open: open === "newDm",
						label: "Start a direct message",
						placeholder: "member name",
						max: MAX_NICK,
						noun: "name",
						canAdd: inARoom,
						offers: dmOffers,
						sigil: "@",
						onOpen: opener("newDm"),
						onSubmit: peer.startDm,
						onError: (text) => peer.toast("failure", text),
					}}
				>
					<DmRows
						convs={convs}
						activeKey={activeKey}
						inARoom={inARoom}
						dirs={dirs}
						home={homeDir}
						shows={shows}
						onOpen={peer.openConv}
						onClose={peer.closeDm}
						onAbout={peer.aboutDirectory}
					/>
				</RailSection>
			</div>
			<Foot dirs={dirs} home={homeDir} session={session} standing={standing} />
		</nav>
	);
}

// Memoised: see `useStore`. Composer keystrokes change none of these props;
// the join card's answers do change per keystroke, but only while the card is
// on screen, where the rail's linked field has to redraw anyway.
export const Sidebar = memo(SidebarPane);
