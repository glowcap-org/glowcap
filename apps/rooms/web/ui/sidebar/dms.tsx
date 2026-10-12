// The direct-message section's rows, and the list they make.
//
// A direct line is between two people on one directory, and everything here is
// about saying which two and which one: a name may be granted twice on two
// directories and mean two people, so a row wears its directory as a colour and
// says it in words. Its sibling rooms.tsx holds the same for the rooms section,
// and the rail itself only decides which sections there are.

import { PRESENTATION, useProgress } from "../presentation.ts";
import { useMemo } from "react";
import { dmMarkTitle, dmRemove, dmSectionTitle } from "../../../lib/text/controls.ts";
import {
	dmJoinARoomFirst,
	dmMemberNamePlaceholder,
	dmMessageAMember,
	dmOnDirectory,
	dmOpen,
	dmOpenClosed,
	dmRemoveSaid,
	dmStart,
	railClosed,
	railIn,
} from "../../../lib/text/rail.ts";
import { useRoomsState, useSessionPaused } from "../hooks.ts";
import { NO_MEMBERS } from "../store/core.ts";
import { MAX_NICK } from "../limits.ts";
import { Avatar, PresenceAvatar } from "../Avatar.tsx";
import { Button } from "../Button.tsx";
import { Icon } from "../icons.tsx";
import { dirCaptionSaid, directoryName, dirStanding, type DirWhere, dirWhere, nothingWhilePaused } from "../text.ts";
import {
	awayByPeer,
	awayOf,
	CAUGHT_UP,
	type Conv,
	type DirId,
	type DirView,
	type DmConv,
	type SessionPhase,
	type Standing,
	type Unread,
} from "../types.ts";
import { dmRow, type RailRow, unreadCount } from "./filter.ts";
import { Empty, heldBack, nothingMatches, RowClose } from "./rows.tsx";
import { RailSection } from "./Section.tsx";

function DmRow(
	{ conv, unread, online, away, where, home, phase, here, canInteract, onOpen, onClose, onAbout }: {
		conv: DmConv;
		unread: Unread;
		online: boolean;
		/** Why the peer has stepped away, by the shared rooms' word, or null
		 * while they are here, `peerAway`'s answer, worn by the chip's
		 * pip exactly as the roster wears it. */
		away: string | null;
		/** Which directory this line was introduced on, or nothing at all while
		 * this tab holds one. It is drawn on the row and said in the row's label
		 * as well as worn as a color, because two people may hold the same
		 * nickname on two directories and color alone cannot tell a reader which
		 * is which. The two arrive as one value so that a row cannot be given the
		 * color on its own. */
		where: DirWhere;
		/** The directory this page came from, so the caption can name the one this
		 * line was introduced on even where the drawn line has nothing worth
		 * naming. */
		home: DirId | null;
		/** How that directory is doing. A direct line is reached through the
		 * directory that introduced it, so a directory that is not connected is a
		 * line this reader cannot use, and the row says so rather than looking
		 * ordinary. */
		phase: SessionPhase;
		here: boolean;
		canInteract: boolean;
		onOpen: (key: string) => void;
		onClose: (conv: DmConv) => void | Promise<void>;
		onAbout: (dir: DirId) => void;
	},
) {
	// How the directory that introduced this line is doing, and empty while it is
	// connected. A line reached through a directory that is not connected is a
	// line this reader cannot use, which is a fact about this row.
	const progress = useProgress(phase === "connecting" || phase === "reconnecting", PRESENTATION.connection, phase);
	const standing = phase === "disconnected" || progress ? dirStanding(phase) : "";
	// Every trailing mark hangs off one group, because the close button takes the
	// whole group's slot rather than a slot of its own. Naming the marks one by
	// one in the stylesheet is what let a closed row keep its "closed" label under
	// the button and draw the two on top of each other.
	//
	// A closed row has lost its direct route and needs a fresh introduction.
	// Its history stays readable. Room membership has its own lifetime.
	//
	// The close button is on every conversation, not only the one on screen: the
	// room you are in can be left while you are reading a direct message, and the
	// reverse has to be true too.
	const lineMark = conv.line === "closed"
		? <span className="closed-mark">{railClosed}</span>
		: conv.line === "live"
		? (
			<span className="lock" title={dmMarkTitle}>
				<Icon name="lock" size={12} />
			</span>
		)
		: null;
	return (
		<li
			className={(here ? "here" : "") + (online ? "" : " off") +
				(conv.line === "closed" ? " closed" : "")}
			data-dir={where.mark}
		>
			<button
				type="button"
				className="dm-open"
				aria-label={(conv.line === "closed" ? dmOpenClosed(conv.id) : dmOpen(conv.id)) +
					(where.name === null ? "" : dmOnDirectory(where.name))}
				onClick={() => onOpen(conv.key)}
			>
				{
					/* Seeded by the name alone, deliberately: the same person must wear
					   the same tint here and in the log, and the log knows only the name.
					   Which directory they are on is carried by the ring around this chip
					   and by the line under it, so two people holding one nickname on two
					   directories are still told apart, by the two channels that mean
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
				    own label carries the whole name for a reader who is listening. A
				    reader who is looking had nothing. */
				}
				<span className="rname" title={conv.id}>{conv.id}</span>
				<span className="dm-marks">
					{lineMark}
					{unread.kind === "unread" && <span className="rcount">{unreadCount(unread)}</span>}
				</span>
			</button>
			{(where.name !== null || standing !== "") && (
				// Beside the row's button rather than inside it, and the same control a
				// room row carries: a person's directory is as worth asking about as a
				// room's, and one shape for both means one rule places both. How that
				// directory is doing rides the same line for the same reason.
				<Button
					variant="caption"
					className="rwhere"
					title={where.name ?? undefined}
					aria-label={dirCaptionSaid(directoryName(conv.dir, home), phase)}
					onClick={() => onAbout(conv.dir)}
				>
					<Icon name="directory" size={12} />
					{where.name !== null && <span className="rwhere-said">{railIn} {where.name}</span>}
					{standing !== "" && <span className="rwhere-how">{standing}</span>}
				</Button>
			)}
			{canInteract && (
				<RowClose
					title={dmRemove}
					said={dmRemoveSaid(conv.id)}
					onClose={() => onClose(conv)}
				/>
			)}
		</li>
	);
}

/** Every direct line this tab has open, by name, which is the order this list
 * has always used and the only one a reader can predict for a set they did not
 * choose the arrival order of.
 *
 * A row says which directory introduced it and wears that directory's color,
 * once there is more than one to tell apart, because the counterparty is a
 * nickname and a nickname is one directory's to grant and reclaim. It says how
 * that directory is doing whenever it is not simply connected, because the line
 * is reached through it.
 *
 * The filter takes rows out of this list and puts them back, and does nothing
 * else to it: what is left is still by name, in the order it has always been
 * in. */
function DmRows(
	{ convs, unreads, activeKey, inARoom, dirs, home, canInteract, shows, onOpen, onClose, onAbout }: {
		convs: ReadonlyMap<string, Conv>;
		unreads: ReadonlyMap<string, Unread>;
		activeKey: string | null;
		/** Whether this tab is in any room at all. A direct line starts from a
		 * roster, so which room it came from does not matter here, only that
		 * there is one. */
		inARoom: boolean;
		/** Every directory, because whether a peer is reachable is one directory's
		 * answer: the same nick on another directory is a different person, and a
		 * merged set of reachable names would say the wrong one is online. */
		dirs: ReadonlyMap<DirId, DirView>;
		home: DirId | null;
		canInteract: boolean;
		/** Whether the reader is looking at this row. The same question the
		 * rooms list is asked, so one answer covers the whole rail. */
		shows: (row: RailRow) => boolean;
		onOpen: (key: string) => void;
		onClose: (conv: DmConv) => void | Promise<void>;
		onAbout: (dir: DirId) => void;
	},
) {
	const paused = useSessionPaused();
	const unreadOf = (key: string) => unreads.get(key) ?? CAUGHT_UP;
	const rows = [...convs.values()]
		.filter((c): c is DmConv => c.type === "dm")
		.sort((a, b) => a.id.localeCompare(b.id));
	const open = rows.filter((conv) => shows(dmRow(conv, unreadOf(conv.key))));
	const hidden = rows.length - open.length;
	// One walk over every roster, shared by all the rows below. Presence writes
	// the members map, not the conversation, so this depends on both.
	const members = useRoomsState((state) => state.members);
	const away = useMemo(() => awayByPeer(convs, members), [convs, members]);
	if (rows.length === 0) {
		return (
			<Empty
				text={paused ? nothingWhilePaused : inARoom ? dmMessageAMember : dmJoinARoomFirst}
			/>
		);
	}
	if (hidden === rows.length) {
		return <Empty text={nothingMatches} />;
	}
	return (
		<>
			{open.map((conv) => (
				<DmRow
					key={conv.key}
					conv={conv}
					unread={unreadOf(conv.key)}
					online={dirs.get(conv.dir)?.dmablePeers.get(conv.id.toLowerCase())?.registrationId ===
						conv.peerRegistrationId}
					away={awayOf(away, conv.dir, conv.id)}
					where={dirWhere(conv.dir, home, dirs)}
					home={home}
					phase={dirs.get(conv.dir)?.session ?? "disconnected"}
					here={conv.key === activeKey}
					canInteract={canInteract}
					onOpen={onOpen}
					onClose={onClose}
					onAbout={onAbout}
				/>
			))}
			{hidden > 0 && <Empty text={heldBack(hidden)} />}
		</>
	);
}

/** Names this tab's rosters can finish a new direct line with: reachable on
 * their directory, spelled as granted, never the reader. */
function dmNameOffers(
	convs: ReadonlyMap<string, Conv>,
	dirs: ReadonlyMap<DirId, DirView>,
	members: ReadonlyMap<string, ReadonlyMap<string, Standing>>,
): string[] {
	const names = new Map<string, string>();
	for (const conv of convs.values()) {
		if (conv.type !== "room") continue;
		const dir = dirs.get(conv.dir);
		if (dir === undefined) continue;
		for (const name of (members.get(conv.key) ?? NO_MEMBERS).keys()) {
			const key = name.toLowerCase();
			if (key === dir.nick.toLowerCase()) continue;
			if (!dir.dmablePeers.has(key)) continue;
			names.set(key, name);
		}
	}
	return [...names.values()];
}

/** The rail's direct-message list and its "+" field. Presence belongs here,
 * not on the rail shell: a join in one room should not rebuild the rooms list. */
export function DirectMessages(
	{
		canInteract,
		convs,
		unreads,
		activeKey,
		inARoom,
		dirs,
		home,
		shows,
		open,
		onOpen,
		onSubmit,
		onError,
		onSelect,
		onClose,
		onAbout,
	}: {
		canInteract: boolean;
		convs: ReadonlyMap<string, Conv>;
		unreads: ReadonlyMap<string, Unread>;
		activeKey: string | null;
		inARoom: boolean;
		dirs: ReadonlyMap<DirId, DirView>;
		home: DirId | null;
		shows: (row: RailRow) => boolean;
		open: boolean;
		onOpen: (shown: boolean) => void;
		onSubmit: (name: string) => void;
		onError: (text: string) => void;
		onSelect: (key: string) => void;
		onClose: (conv: DmConv) => void | Promise<void>;
		onAbout: (dir: DirId) => void;
	},
) {
	const members = useRoomsState((state) => state.members);
	const offers = useMemo(() => dmNameOffers(convs, dirs, members), [convs, dirs, members]);
	return (
		<RailSection
			className="dms"
			title={dmSectionTitle}
			listId="dmList"
			field={{
				id: "newDm",
				open,
				label: dmStart,
				placeholder: dmMemberNamePlaceholder,
				max: MAX_NICK,
				noun: "name",
				canAdd: canInteract && inARoom,
				offers,
				sigil: "@",
				onOpen,
				onSubmit,
				onError,
			}}
		>
			<DmRows
				canInteract={canInteract}
				convs={convs}
				unreads={unreads}
				activeKey={activeKey}
				inARoom={inARoom}
				dirs={dirs}
				home={home}
				shows={shows}
				onOpen={onSelect}
				onClose={onClose}
				onAbout={onAbout}
			/>
		</RailSection>
	);
}
