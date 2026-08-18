// The rail: the rooms that exist, the direct conversations this tab has open,
// and the foot that says what the connection is doing.
//
// The two "+" fields behave identically — open one and the other closes, click
// away or press Escape and it puts itself away and hands focus back — so they
// are one component used twice rather than two sets of handlers kept in step.

import { memo, useEffect, useMemo, useState } from "react";
import { usePeer } from "./peer.ts";
import { implied, named } from "./intent.ts";
import type { JoinAnswers } from "./joining.ts";
import {
	awayByPeer,
	awayOf,
	type Conv,
	type DirId,
	dirId,
	dirMark,
	dirsAreMarked,
	type DirView,
	type DmConv,
	type Invitation,
	type RoomConv,
	type SessionPhase,
} from "./types.ts";
import { Avatar, PresenceAvatar } from "./Avatar.tsx";
import { directoryName, footState } from "./text.ts";
import { Icon, Wordmark } from "./icons.tsx";
import { IconButton } from "./IconButton.tsx";
import { SettingsButton } from "./SettingsButton.tsx";
import { StandingMenu } from "./Standing.tsx";
import { Button } from "./Button.tsx";
import { MAX_NICK, MAX_ROOM } from "../../lib/limits.ts";
import { type PanelName, RailSection } from "./sidebar/Section.tsx";
import { Empty, EmptyDirRow, InviteRow, RoomRow, RowClose } from "./sidebar/rows.tsx";
/** The rooms this tab is in, across every directory, in the order it entered
 * them, and under them the directories it is on with nothing open.
 *
 * Insertion order and nothing else. Nobody else's activity can move a row, and
 * joining appends rather than inserting into the middle, so the list a reader
 * learned stays the list they have. */
function YourRooms(
	{
		convs,
		dirs,
		home,
		activeKey,
		marked,
		empty,
		invites,
		onPick,
		onLeave,
		onAbout,
		onJoinOn,
		onLeaveDir,
		onTake,
		onDrop,
	}: {
		convs: ReadonlyMap<string, Conv>;
		dirs: ReadonlyMap<DirId, DirView>;
		home: DirId | null;
		activeKey: string | null;
		/** Rooms handed to this tab and not answered yet. */
		invites: readonly Invitation[];
		onTake: (id: string) => void;
		onDrop: (id: string) => void;
		/** Whether rows say which directory they are in. Worth saying only once
		 * there is more than one to be in, and never worth saying past the ramp's
		 * length,
		 * where a mark for some and none for others would claim a sameness that is
		 * not there. */
		marked: boolean;
		/** Directories held with nothing open on them, listed under the rooms so a
		 * connection nobody can see is not a connection nobody can end. */
		empty: DirView[];
		onPick: (conv: RoomConv) => void;
		onLeave: (key: string) => void;
		onAbout: (dir: DirId) => void;
		onJoinOn: (dir: DirId) => void;
		onLeaveDir: (dir: DirId) => void;
	},
) {
	const rows = [...convs.values()].filter((conv): conv is RoomConv => conv.type === "room");
	if (rows.length === 0 && empty.length === 0 && invites.length === 0) {
		return (
			<Empty
				text={dirs.size === 0
					? "Reaching a directory…"
					: "Rooms you join appear here. Name one above to open it."}
			/>
		);
	}
	return (
		<>
			{invites.map((invite) => (
				<InviteRow
					key={invite.id}
					invite={invite}
					mark={marked ? dirMark(invite.dir, home, dirs.get(invite.dir)?.slot) : undefined}
					onTake={onTake}
					onDrop={onDrop}
				/>
			))}
			{rows.map((conv) => {
				const held = dirs.get(conv.dir);
				// Every row names its directory once there is more than one, the page's
				// own included. Leaving that one out would make the colour beside a home
				// room the only thing telling it apart, and would leave the line that
				// opens its card unreachable.
				return (
					<RoomRow
						key={conv.key}
						conv={conv}
						unread={conv.unread.kind === "unread" ? conv.unread.count : 0}
						here={activeKey === conv.key}
						directory={marked ? directoryName(conv.dir, home) : null}
						mark={marked ? dirMark(conv.dir, home, held?.slot) : undefined}
						phase={held?.session ?? "disconnected"}
						onPick={onPick}
						onLeave={onLeave}
						onAbout={onAbout}
					/>
				);
			})}
			{empty.map((dir) => (
				<EmptyDirRow
					key={dir.id}
					dir={dir}
					home={home}
					marked={marked}
					onJoinOn={onJoinOn}
					onLeave={onLeaveDir}
					onAbout={onAbout}
				/>
			))}
		</>
	);
}

function DmRow(
	{ conv, online, away, where, mark, here, onOpen, onClose, onAbout }: {
		conv: DmConv;
		online: boolean;
		/** Why the peer has stepped away, by the shared rooms' word, or null
		 * while they are simply here — `peerAway`'s answer, worn by the chip's
		 * pip exactly as the roster wears it. */
		away: string | null;
		/** Which directory this line was introduced on, or null while there is only
		 * one and saying so would be noise. It is said in words as well as worn as
		 * a colour, because two people may hold the same nickname on two
		 * directories and colour alone cannot tell a reader which is which. */
		where: string | null;
		mark: string | undefined;
		here: boolean;
		onOpen: (key: string) => void;
		onClose: (conv: DmConv) => void;
		onAbout: (dir: DirId) => void;
	},
) {
	// Every trailing mark hangs off one group, because the close button takes the
	// whole group's slot rather than a slot of its own. Naming the marks one by
	// one in the stylesheet is what let a closed row keep its "closed" label under
	// the button and draw the two on top of each other.
	//
	// A closed row is one whose member left, which puts their name back in the
	// room's hands. The conversation stays, its history is yours, but it reaches
	// nobody, and the row says so rather than looking like someone merely offline.
	//
	// The close button is on every conversation, not only the one on screen: the
	// room you are in can be left while you are reading a direct message, and the
	// reverse has to be true too.
	const lineMark = conv.line === "closed"
		? <span className="closed-mark">closed</span>
		: conv.line === "live"
		? (
			<span className="lock" title="Direct, peer-to-peer">
				<Icon name="lock" size={12} />
			</span>
		)
		: null;
	return (
		<li
			className={(here ? "here" : "") + (online ? "" : " off") +
				(conv.line === "closed" ? " closed" : "")}
			data-dir={mark}
		>
			<button
				type="button"
				className="dm-open"
				aria-label={(conv.line === "closed"
					? "Open the closed conversation with " + conv.id
					: "Open direct message with " + conv.id) + (where === null ? "" : " on " + where)}
				onClick={() => onOpen(conv.key)}
			>
				{
					/* Seeded by the name alone, deliberately: the same person must wear
					   the same tint here and in the log, and the log knows only the name.
					   Which directory they are on is carried by the ring around this chip
					   and by the line under it, so two people holding one nickname on two
					   directories are still told apart — by the two channels that mean
					   that, rather than by a fill that would then disagree with the
					   conversation it opens. */
				}
				{
					/* The chip wears the member's presence on its corner, except on a
				    closed row: a conversation that reaches nobody is not somebody
				    offline, and the trailing mark says "closed" instead. */
				}
				{conv.line === "closed" ? <Avatar name={conv.id} /> : (
					<PresenceAvatar
						name={conv.id}
						state={online ? (away !== null ? "away" : "online") : "offline"}
						reason={away ?? undefined}
					/>
				)}
				{
					/* Titled like a room's name, because it truncates like one. The row's
				    own label carries the whole name for a reader who is listening; a
				    reader who is looking had nothing. */
				}
				<span className="rname" title={conv.id}>{conv.id}</span>
				<span className="dm-marks">
					{lineMark}
					{conv.unread.kind === "unread" && <span className="rcount">{conv.unread.count}</span>}
				</span>
			</button>
			{where !== null && (
				// Beside the row's button rather than inside it, and the same control a
				// room row carries: a person's directory is as worth asking about as a
				// room's, and one shape for both means one rule places both.
				<Button
					variant="caption"
					className="rwhere"
					title={where}
					aria-label={"About " + where}
					onClick={() => onAbout(conv.dir)}
				>
					<Icon name="directory" size={12} />
					<span className="rwhere-said">in {where}</span>
				</Button>
			)}
			<RowClose
				title="Close this direct message"
				said={"Close the direct message with " + conv.id}
				onClose={() => onClose(conv)}
			/>
		</li>
	);
}

function DmRows(
	{ convs, activeKey, inARoom, dirs, home, marked, onOpen, onClose, onAbout }: {
		convs: ReadonlyMap<string, Conv>;
		activeKey: string | null;
		/** Whether this tab is in any room at all. A direct line starts from a
		 * roster, so which room it came from does not matter here — only that
		 * there is one. */
		inARoom: boolean;
		/** Every directory, because whether a peer is reachable is one directory's
		 * answer: the same nick on another directory is a different person, and a
		 * merged set of reachable names would say the wrong one is online. */
		dirs: ReadonlyMap<DirId, DirView>;
		home: DirId | null;
		/** Whether to say which directory each line is in, which is worth saying only
		 * once there is more than one to be on. */
		marked: boolean;
		onOpen: (key: string) => void;
		onClose: (conv: DmConv) => void;
		onAbout: (dir: DirId) => void;
	},
) {
	const rows = [...convs.values()]
		.filter((c): c is DmConv => c.type === "dm")
		.sort((a, b) => a.id.localeCompare(b.id));
	// One walk over every roster, shared by all the rows below; `convs` is a
	// fresh map whenever any roster changes, so this stays current without a
	// second walk per row.
	const away = useMemo(() => awayByPeer(convs), [convs]);
	if (rows.length === 0) {
		return (
			<Empty
				text={inARoom
					? "Message a member to start one."
					: "Join a room first, then message someone from the roster."}
			/>
		);
	}
	return (
		<>
			{rows.map((conv) => (
				<DmRow
					key={conv.key}
					conv={conv}
					online={dirs.get(conv.dir)?.dmablePeers.has(conv.id.toLowerCase()) ?? false}
					away={awayOf(away, conv.dir, conv.id)}
					where={marked ? directoryName(conv.dir, home) : null}
					mark={marked ? dirMark(conv.dir, home, dirs.get(conv.dir)?.slot) : undefined}
					here={conv.key === activeKey}
					onOpen={onOpen}
					onClose={onClose}
					onAbout={onAbout}
				/>
			))}
		</>
	);
}

/** The rail's foot: one lockup saying who this reader is and how they stand,
 * and pressing it opens the standing menu — the roster's two-row shape, worn by
 * the reader themselves.
 *
 * The foot is the one part of the page about the reader rather than about a
 * conversation, which is why standing lives here and not in a room's header:
 * stepping out is something you do, not something you do to a room. For the
 * same reason the top row never switches with the conversation being read: a
 * name is one directory's grant, so the row says the home directory's grant
 * and counts the others, with the whole list on its title, rather than letting
 * the rail claim one name covers every room.
 *
 * Which is exactly what a lone name at the foot of a page does look like it is
 * claiming, so when this tab holds more than one named directory the name
 * wears that directory's own mark — the same `data-dir` colour its rooms wear
 * in the rail above — and the chip beside it counts the other names in words.
 * A reader can then see that this name belongs to one of the directories on
 * screen rather than to the page. */
function Foot(
	{ dirs, home, session, standing }: {
		dirs: ReadonlyMap<DirId, DirView>;
		home: DirId | null;
		session: SessionPhase;
		standing: string;
	},
) {
	const peer = usePeer();
	// Every directory that has granted a name, in the order this tab opened
	// them; the page's own directory answers first while it has granted one.
	const grants = [...dirs.values()].filter((held) => held.nick !== "");
	const primary = (grants.find((held) => held.id === home) ?? grants[0])?.nick ?? "";
	// Distinct names, not directories: two directories both granting "alice"
	// agree, and a count that said otherwise would raise a question the title
	// could not answer.
	const others = new Set(grants.map((held) => held.nick)).size - (primary === "" ? 0 : 1);
	const whoSaid = grants.map((held) => `${held.nick} on ${directoryName(held.id, home)}`).join(", ");
	const foot = footState(session, standing, primary !== "");
	// Whose grant this name is, drawn only when the reader can see the same
	// mark elsewhere: one directory needs no colour to be told apart from, and
	// past the ramp nothing is marked at all (`dirsAreMarked`).
	const named = grants.find((held) => held.id === home) ?? grants[0];
	const mark = named !== undefined && dirsAreMarked(dirs) ? dirMark(named.id, home, named.slot) : undefined;
	// The state row is the one live region the foot carries, in both arms, so a
	// phase change or a standing change is announced without a second voice.
	const stateRow = (className?: string) => (
		<span id="status" role="status" aria-live="polite" className={className} title={foot.said}>
			{foot.said}
		</span>
	);
	return (
		<div className="sidebar-foot">
			<StandingMenu
				id="standingBtn"
				own={standing}
				effective={standing}
				about="you"
				up
				faceClass="foot-lockup"
				label={primary === "" ? undefined : `${whoSaid} — where you are: ${foot.said}`}
				onSay={(said) => peer.setStanding(said ?? "")}
				face={primary === ""
					? (
						/* Before any directory grants a name there is nobody to draw, so
						   the dot stands alone beside the state text, as it always has. */
						<>
							<span id="dot" className={"dot " + session} />
							{stateRow()}
						</>
					)
					: (
						/* While the session cannot reach anybody the chip dims the way an
						   offline member's does, so the reader's own state is said in the
						   page's one vocabulary; the dot's shape still names which of the
						   four phases this is, on the corner seat it has always held. */
						<>
							<span className={"avatar-presence" + (session === "connected" ? "" : " offline")}>
								<Avatar name={primary} />
								<span id="dot" className={"dot " + session} />
							</span>
							<span className="name-line">
								<span className="foot-names" title={others > 0 ? whoSaid : primary} data-dir={mark}>
									<span className="name">{primary}</span>
									{others > 0 && (
										<span className="foot-more">
											+{others} {others === 1 ? "name" : "names"}
										</span>
									)}
								</span>
								{stateRow(foot.away ? "away-said" : "foot-said")}
							</span>
						</>
					)}
			/>
		</div>
	);
}

function SidebarPane(
	{
		convs,
		dirs,
		homeDir,
		activeKey,
		join,
		railShown,
		mobile,
		session,
		emptyDirs,
		standing,
		invites,
		settingsOpen,
	}: {
		convs: ReadonlyMap<string, Conv>;
		/** Every directory this tab holds, in the order it opened them. */
		dirs: ReadonlyMap<DirId, DirView>;
		/** Those of them with nothing open, which get a row of their own: holding
		 * one is a session and a registered name whatever is open on it, and that
		 * state used to have nowhere to appear. */
		emptyDirs: DirView[];
		homeDir: DirId | null;
		activeKey: string | null;
		/** The join card's answers. With no conversation open the card is the
		 * workarea, and the rail's room field is then a second view of the same
		 * form rather than a form of its own, so it reads the one resolved
		 * answer rather than the state behind it. */
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
	// The grouping appears only when it carries information. Holding one
	// directory, the rail draws exactly what it has always drawn: no heading, no
	// colour, nothing to read past the rooms themselves. The structure arrives
	// with the second directory, which is the first moment "which directory is this
	// room on" is a question anybody can have.
	const held = [...dirs.values()];
	// Whether rows name their directory, asked where that rule lives.
	const marked = dirsAreMarked(dirs);
	// Which directory the section's "+" names a room on. "Here" is the directory
	// of the conversation being read, which is the only reading of an unqualified
	// room name that a reader would recognise as their own. Reaching a room on a
	// directory this tab has not opened is the join card's job, and the card is
	// where the locator lives.
	const here = activeKey !== null ? convs.get(activeKey)?.dir ?? held[0]?.id ?? dirId("") : held[0]?.id ?? dirId("");
	// At most one "+" field is open, which is the rail's rule to keep rather than
	// each section's, so it is one value here instead of a flag in each.
	const peer = usePeer();
	const [open, setOpen] = useState<PanelName | null>(null);
	const opener = (panel: PanelName) => (shown: boolean) => setOpen(shown ? panel : null);
	// Switching conversations, or losing the room, puts an open panel away.
	useEffect(() => setOpen(null), [activeKey]);

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
				<Wordmark />
				{railShown && <SettingsButton id="settingsBtn" mobile={mobile} settingsOpen={settingsOpen} />}
			</div>
			<div className="sidebar-body">
				<RailSection
					id="newRoom"
					title="Your rooms"
					listId="roomList"
					open={open === "room"}
					label={marked
						? "Create or open a room in " + directoryName(here, homeDir)
						: "Create or open a room"}
					placeholder="room name"
					max={MAX_ROOM}
					noun="room name"
					canAdd
					onOpen={opener("room")}
					canBePrivate
					onSubmit={(name, isPrivate) =>
						isPrivate ? peer.openPrivateRoom(here, name) : peer.pickRoom(here, name)}
					// With the join card on screen, this field and that form name one
					// room: one draft, one lock, and Enter submits the form itself, so
					// the locator and name the reader filled in over there are honored
					// rather than silently dropped. The form's id is a pinned selector,
					// and `requestSubmit` is the platform's own way to submit it.
					link={activeKey === null
						? {
							value: join.room.value,
							secret: join.secret.value,
							onValue: (value) => peer.editJoin({ room: value }),
							onSecret: (secret) => peer.editJoin({ secret }),
							submit: () => document.querySelector<HTMLFormElement>("#joinForm")?.requestSubmit(),
						}
						: undefined}
					onElsewhere={(name) =>
						peer.reachFor({ source: "press", room: named(name), locator: implied(here) })}
					onError={(text) => peer.toast("failure", text)}
					sigil="#"
					// Stated whether or not this tab holds more than one directory. A room
					// row stays quiet about its directory while there is only one, because
					// there is nothing to tell apart; this panel is the one moment the
					// answer is still open, so it says where the room is going even then.
					where={{ name: directoryName(here, homeDir), mark: dirMark(here, homeDir, dirs.get(here)?.slot) }}
				>
					<YourRooms
						convs={convs}
						dirs={dirs}
						home={homeDir}
						activeKey={activeKey}
						marked={marked}
						empty={emptyDirs}
						invites={invites}
						onTake={peer.acceptInvite}
						onDrop={peer.declineInvite}
						onPick={(conv) => peer.pickRoom(conv.dir, conv.id, conv.key)}
						onLeave={peer.leaveRoom}
						onAbout={peer.aboutDirectory}
						onJoinOn={(dir) => peer.reachFor({ source: "press", locator: named(dir) })}
						onLeaveDir={peer.leaveDirectory}
					/>
				</RailSection>
				<RailSection
					id="newDm"
					className="dms"
					title="Direct messages"
					listId="dmList"
					open={open === "dm"}
					label="Start a direct message"
					placeholder="member name"
					max={MAX_NICK}
					noun="name"
					canAdd={inARoom}
					sigil="@"
					onOpen={opener("dm")}
					onSubmit={peer.startDm}
					onError={(text) => peer.toast("failure", text)}
				>
					<DmRows
						convs={convs}
						activeKey={activeKey}
						inARoom={inARoom}
						dirs={dirs}
						home={homeDir}
						marked={marked}
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
