// The rail: the rooms this tab is in and the direct conversations it has open,
// as two lists. They are the rail's two lists whatever this tab holds, because
// rooms and direct lines are different kinds of thing rather than different
// places, and a directory is something a row is on rather than a box a row
// lives in. The reader's own seat under the lists is next door in
// `sidebar/Foot.tsx`, because it is about the reader rather than about what
// they hold.
//
// Both "+" fields behave identically (open one and the other closes, click
// away or press Escape and it puts itself away and hands focus back) so they
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
import { frontPage, railToggleLabel, yourRooms } from "../../../lib/text/controls.ts";
import { railCreateOrOpenIn, railRoomNameNoun, railRoomNamePlaceholder } from "../../../lib/text/rail.ts";
import { railHide, railShow } from "../../../lib/text/conversation.ts";
import { brandRooms } from "../../../lib/text/page.ts";
import { memo, type MouseEvent, useEffect, useMemo, useState } from "react";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { implied, named } from "../intent.ts";
import {
	destination,
	type DirectoryDestinationContext,
	type JoinAnswers,
	type JoinResolution,
	joinRoomOffers,
	privateRoomNameRefusal,
} from "../joining.ts";
import { policyForRoomPreset } from "../room_policy.ts";
import { CAUGHT_UP, type DirId, dirId, type DirView, type Invitation, liveRoomNames } from "../types.ts";
import { DirectMessages } from "../sidebar/dms.tsx";
import { JoinRefusal } from "../sidebar/JoinRefusal.tsx";
import { YourRooms } from "../sidebar/rooms.tsx";
import { RailFilter } from "../sidebar/Filter.tsx";
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
} from "../sidebar/filter.ts";
import { DirectoryPicks, typeAnotherAddress } from "../DirectoryPicks.tsx";
import { Wordmark } from "../icons.tsx";
import { IconButton } from "../IconButton.tsx";
import { SettingsButton } from "../settings/SettingsButton.tsx";
import { MAX_ROOM } from "../limits.ts";
import { Foot } from "../sidebar/Foot.tsx";
import { RailSection } from "../sidebar/Section.tsx";
import type { AddField } from "../sidebar/NamePanel.tsx";
import { useRoomsState } from "../hooks.ts";
import { emptyDirs } from "../store.ts";

/** Whether following this link is going to happen in this tab. A middle or
 * modified click opens somewhere else, and rearranging the furniture here
 * would be rearranging it behind a reader who never left. */
function landsHere(press: MouseEvent<HTMLElement>): boolean {
	if (press.defaultPrevented || press.button !== 0) return false;
	return !press.metaKey && !press.ctrlKey && !press.shiftKey && !press.altKey;
}

function SidebarPane(
	{
		canInteract,
		cardUp,
		dirs,
		homeDir,
		directoryContext,
		activeKey,
		acting,
		join,
		joinResolution,
		railShown,
		mobile,
		standing,
		invites,
		settingsOpen,
	}: {
		canInteract: boolean;
		/** The join card is the workarea: no conversation open and nothing
		 * else standing in the content cell. App owns what that cell shows,
		 * so App says. */
		cardUp: boolean;
		/** Every directory this tab holds, in the order it opened them. */
		dirs: ReadonlyMap<DirId, DirView>;
		homeDir: DirId | null;
		directoryContext: DirectoryDestinationContext;
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
		/** The card and linked rail field consume one resolution owned by App. */
		joinResolution: JoinResolution;
		railShown: boolean;
		mobile: boolean;
		/** Where this reader stands everywhere, which the foot both shows and
		 * sets. */
		standing: string;
		/** Rooms somebody handed this tab and it has not answered yet.  status-allow: pending state or quoted runtime label */
		invites: readonly Invitation[];
		settingsOpen: boolean;
	},
) {
	const convs = useRoomsState((state) => state.convs);
	const unreads = useRoomsState((state) => state.unreads);
	/** Directories this tab holds with nothing open, which get a row of their
	 * own: holding one is a session and a registered name whatever is open on it. */
	const empty = emptyDirs({ convs, dirs, homeDir });
	// The direct-message section needs to know whether this tab is in any room:
	// a direct line starts from a roster, and any room's roster will do.
	const inARoom = [...convs.values()].some((conv) => conv.type === "room");
	// Which directory the section's "+" names a room on: the one the page is
	// acting on, which the store answers once for everything that asks. Reaching
	// a room on a directory this tab has not opened is the join card's job, and
	// the card is where the locator lives.
	const here = acting ?? dirId("");
	// At most one "+" field is open, which is the rail's rule to keep rather than
	// each section's, so it is one value here instead of a flag in each.
	const browser = useRoomsBrowser();
	const rooms = useRoomsSession();
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
		...[...convs.values()].flatMap((conv) => {
			if (conv.type === "directory") return [];
			const unread = unreads.get(conv.key) ?? CAUGHT_UP;
			return [conv.type === "room" ? roomRow(conv, unread) : dmRow(conv, unread)];
		}),
		...empty.map((dir) => dirRow(dir, homeDir)),
	];
	const shown = railRows.filter(shows).length;
	// With the join card up, this panel is a second view of it: one room name,
	// one lock, and one destination. So where a room lands is the card's locator
	// field, resolved exactly as the card resolves it, rather than the directory
	// the reader was last standing on: the panel and the card cannot state two
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
		? destination(
			join.locator.value,
			rooms.directoryId(join.locator.value.trim()),
			dirs,
			directoryContext,
			"this directory",
		)
		// The same classification, asked of a directory already in hand rather
		// than of a field: naming the answer twice is how the panel and the card
		// came to disagree, and this branch is the copy that was left behind.
		: destination(here, here, dirs, directoryContext, "this directory");
	// At most one "+" field is open anywhere in the rail, so this is the open
	// panel's own id rather than a flag per place that could hold one.
	const [open, setOpen] = useState<string | null>(null);
	const opener = (panel: string) => (shown: boolean) => setOpen(shown ? panel : null);
	// Landing in a conversation puts an open panel away: what was typed into it
	// was aimed somewhere else. Coming back the other way leaves it standing,
	// because the thing that brought the join card up is usually this panel's
	// own destination line, and taking the field away at the moment it gains status-allow: state at observation
	// its other half is the opposite of what that press meant.
	useEffect(() => {
		if (activeKey !== null) setOpen(null);
	}, [activeKey]);

	// What the room field can finish. Rooms come from the directory the field is
	// aimed at, since that is where the room will land and a name advertised
	// somewhere else would open a different room. Direct-line names are the
	// other field's, and they subscribe there so a join does not rebuild this
	// list.
	const roomOffers = linked
		? joinRoomOffers(join.locator.value, join.room.value, dirs, directoryContext, rooms.directoryId)
		: liveRoomNames(dirs.get(here)?.liveRooms ?? new Map());
	// The one field that names a room, whatever this tab holds. Where the room
	// lands is stated on the field rather than decided by where the field sits,
	// so the destination can change without leaving the rail.
	const roomField: AddField = {
		id: "newRoom",
		open: open === "newRoom",
		// Said whatever this tab holds, because the line under the field says it
		// whatever this tab holds; a label that named the destination only
		// sometimes left a listener with less than a reader had.
		label: railCreateOrOpenIn(aimed.name),
		placeholder: railRoomNamePlaceholder,
		max: MAX_ROOM,
		noun: railRoomNameNoun,
		canAdd: canInteract,
		canChooseAccess: true,
		offers: roomOffers,
		sigil: "#",
		onOpen: opener("newRoom"),
		onSubmit: (name, preset) => {
			if (preset === "private") {
				const refusal = privateRoomNameRefusal(name, roomOffers);
				if (refusal != null) {
					browser.toast("failure", refusal);
					return;
				}
			}
			void browser.showActiveConversation(
				preset === "open"
					? rooms.pickRoom(here, name)
					: rooms.openManagedRoom(here, name, policyForRoomPreset(preset)),
			);
		},
		onError: (text: string) => browser.toast("failure", text),
		// With the join card on screen, this field and that form name one room:
		// one draft, one lock, and Enter submits the form itself, so the locator
		// and name the reader filled in over there are honored rather than
		// silently dropped. The form's id is a pinned selector, and
		// `requestSubmit` is the platform's own way to submit it.
		link: linked
			? {
				form: "#joinForm",
				value: join.room.value,
				// The standing the card resolved, not the raw draft: one question
				// cannot have two answers because it is asked in two places.
				roomPreset: joinResolution.standing,
				accessFixed: joinResolution.fixed,
				onValue: (value: string) => browser.editJoin({ room: value }),
				onRoomPreset: (roomPreset) => browser.editJoin({ roomPreset }),
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
		// A pick is an edit and files no act, so it leaves every other answer
		// standing. An act would supersede the one the reader is
		// answering and take the room name in this very field with it.
		picks: linked
			? (close: () => void) => (
				<DirectoryPicks
					className="where-picks"
					locator={join.locator.value}
					dirs={dirs}
					context={directoryContext}
					onPick={(locator) => {
						browser.editJoin({ locator });
						close();
					}}
					onElsewhere={() =>
						typeAnotherAddress(() => {
							close();
							// The card is already the surface here, so nothing is
							// filed. On a phone it is still a screen away, which is
							// what this brings forward; on a wide window it is
							// already beside this panel, which stays where it is.
							browser.showJoinCard();
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
				browser.reachFor({
					source: "press",
					room: named(name),
					locator: implied(rooms.dirAddress(here)),
				})
			),
		// Stated whether or not this tab holds more than one directory. A room row
		// stays quiet about its directory while there is only one, because there
		// is nothing to tell apart; this panel is the one moment the answer is
		// still open, so it says where the room is going even then.
		where: aimed,
	};

	return (
		<nav className="sidebar" aria-label={brandRooms}>
			<div className="workspace">
				<IconButton
					id="railToggle"
					className="mark-btn"
					icon="mark-line"
					label={railToggleLabel}
					size={mobile ? "large" : "normal"}
					title={railShown ? railHide : railShow}
					aria-pressed={railShown}
					onClick={() => browser.showRail(false)}
				/>
				{
					/* Going to the front is a press as much as an address, so it puts the
				    phone's list away the way pressing a room does. The route cannot:
				    an address never moves the furniture (`router.tsx`). */
				}
				<Link
					className="wordmark-link"
					to="/"
					aria-label={frontPage}
					onClick={(press) => {
						if (landsHere(press)) browser.showJoinCard();
					}}
				>
					<Wordmark />
				</Link>
				{railShown && <SettingsButton id="settingsBtn" mobile={mobile} settingsOpen={settingsOpen} />}
			</div>
			<div className="sidebar-body">
				<RailSection
					title={yourRooms}
					listId="roomList"
					field={roomField}
					heading={(title, head) => (
						<RailFilter
							title={title}
							anchor={head}
							criteria={criteria}
							answers={filter}
							shown={shown}
							total={railRows.length}
							onAnswers={setFilter}
						/>
					)}
				>
					<YourRooms
						canInteract={canInteract}
						convs={convs}
						unreads={unreads}
						dirs={dirs}
						home={homeDir}
						activeKey={activeKey}
						empty={empty}
						invites={invites}
						shows={shows}
						onTake={rooms.acceptInvite}
						onDrop={rooms.declineInvite}
						onPick={(conv) => {
							void browser.showActiveConversation(rooms.pickRoom(conv.dir, conv.id, conv.key));
						}}
						onLeave={rooms.leaveRoom}
						onAbout={browser.showDirectory}
						// The address, not the identity: what a row hands over has to be
						// dialable, and the hints are part of what makes it so.
						onJoinOn={(dir) => browser.reachFor({ source: "press", locator: named(rooms.dirAddress(dir)) })}
						onLeaveDir={rooms.leaveDirectory}
					/>
					<JoinRefusal />
				</RailSection>
				<DirectMessages
					canInteract={canInteract}
					convs={convs}
					unreads={unreads}
					activeKey={activeKey}
					inARoom={inARoom}
					dirs={dirs}
					home={homeDir}
					shows={shows}
					open={open === "newDm"}
					onOpen={opener("newDm")}
					onSubmit={(name) => {
						void browser.showActiveConversation(rooms.startDm(name));
					}}
					onError={(text) => browser.toast("failure", text)}
					onSelect={(key) => {
						void browser.showActiveConversation(rooms.openConv(key));
					}}
					onClose={rooms.closeDm}
					onAbout={browser.showDirectory}
				/>
			</div>
			<Foot
				canInteract={canInteract}
				dirs={dirs}
				home={homeDir}
				standing={standing}
			/>
		</nav>
	);
}

// Memoised: see `useRoomsState`. Composer keystrokes change none of these props.
// The join card's answers do change per keystroke, but only while the card is
// on screen, where the rail's linked field has to redraw anyway.
export const Sidebar = memo(SidebarPane);
