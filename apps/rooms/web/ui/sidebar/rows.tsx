// Rows in the rooms rail: a room you are in, a directory with nothing open,
// an invitation waiting, and the mark that ends a row.

import { useState } from "react";
import { type DirId, type DirView, type Invitation, membersHere, type RoomConv, type SessionPhase } from "../types.ts";
import { dirCaptionSaid, directoryName, dirStanding, type DirWhere, phaseWord, roomCalled } from "../text.ts";
import { Icon } from "../icons.tsx";
import { IconButton } from "../IconButton.tsx";
import { Button } from "../Button.tsx";

export function Empty({ text }: { text: string }) {
	return <li className="empty">{text}</li>;
}

/** What a list says when the filter is holding every one of its rows back.
 *
 * Two different things a reader has to tell apart: a list with nothing in it,
 * and a list whose rows are all hidden. Both lists say it the same way, so the
 * words live here beside the row that carries them rather than once per
 * list. */
export const nothingMatches = "Nothing here matches the filter.";

/** And what a list says when the filter is holding only some of them back. */
export function heldBack(hidden: number): string {
	return hidden === 1 ? "1 more, hidden by the filter" : hidden + " more, hidden by the filter";
}

/** The mark that ends a row, in the slot the row's badge otherwise fills. Both
 * lists carry one and they differ only in what they are called.
 *
 * Leaving is ordinary and reversible, so the mark wears the quiet ink. The one
 * exception is `oneWay`, a leave that cannot be walked back: it keeps the
 * danger tone, on the same condition the spoken label already warns about. */
export function RowClose(
	{ title, said, oneWay, disabled, onClose }: {
		title: string;
		said: string;
		oneWay?: boolean;
		disabled?: boolean;
		onClose: () => void;
	},
) {
	return (
		<IconButton
			className="room-leave"
			icon="close"
			label={said}
			size="small"
			variant="ghost"
			tone={oneWay ? "danger" : "neutral"}
			title={title}
			disabled={disabled}
			onClick={(e) => {
				e.stopPropagation();
				onClose();
			}}
		/>
	);
}

/** One room this tab is in.
 *
 * The rail lists the rooms you hold, not the rooms a directory advertises. Those
 * are two different things, and rendering the second while inferring the first
 * from it is what made this list a catalogue that reordered itself under the
 * pointer whenever a stranger joined something. The catalogue has its own
 * surface now; what is left here is short, stable, and yours.
 *
 * The badge is unread, for the same reason: a head-count is somebody else's
 * activity, and nothing on this list should move or change because of it. */
export function RoomRow(
	{ conv, unread, here, where, home, phase, bridgedFrom, canInteract, onPick, onLeave, onAbout }: {
		conv: RoomConv;
		/** Where a bridged room's IRC channel lives, or null for every other
		 * room: a fact about the row, said in words and in its label. */
		bridgedFrom: string | null;
		unread: number;
		here: boolean;
		/** Which directory this room is in, as words and as the color beside
		 * them, or nothing at all while this tab holds one directory and saying
		 * so would be noise. The words are drawn on the row as well as spoken in
		 * its label, and the color is only the glance, so `DirWhere` is what
		 * keeps a color from ever being the whole of what a reader is given. */
		where: DirWhere;
		/** The directory this page came from, so the caption can name the one this
		 * room is on even where the drawn line has nothing worth naming. */
		home: DirId | null;
		phase: SessionPhase;
		canInteract: boolean;
		onPick: (conv: RoomConv) => void;
		onLeave: (key: string) => void;
		onAbout: (dir: DirId) => void;
	},
) {
	const directory = where.name;
	// How the directory serving this room is doing, and empty while it is
	// connected. A room you cannot reach is a fact about this row, so it is said
	// here rather than once for a page that may be holding rooms on a directory
	// with nothing wrong with it.
	const standing = dirStanding(phase);
	// The row opens the room and carries a second control beside it to leave.
	// Both are real buttons: an interactive control nested inside another is a
	// structure no assistive software can read out.
	//
	// Leaving lives in the badge's slot, so the row gives up no width to hold it
	// and no name is cut short for a mark that is not showing.
	const inDir = directory === null ? "" : " in " + directory;
	// The written phrase, never the raw token: a row that read out
	// ", directory reconnecting" was saying a word nothing else on the page says.
	const unwell = phase === "connected" ? "" : ", directory " + phaseWord(phase);
	// The sigil belongs in the spoken name too. The row draws it, the header
	// draws it, and a reader who hears "annex" where everyone else reads "#annex"
	// is being told about a different thing. A private room has no hash-name, so
	// what is spoken is the label; the lock is drawn, and ", a private room"
	// carries the rest.
	const named = roomCalled(conv.id, conv.held);
	// The badge answers whichever question is live. Unread is the urgent one and
	// takes the slot when there is any; otherwise the slot says how many people
	// are in there, which is what it has always said and what a reader glances at
	// to decide where to go next.
	//
	// The count is free to show now that nothing sorts by it. It used to order
	// the list, so a stranger joining anywhere walked the rows out from under the
	// pointer — but that was the ordering, not the number, and the ordering is
	// gone.
	const people = membersHere(conv.members);
	const membership = conv.membership === "joined"
		? ""
		: conv.membership === "joining"
		? ", joining"
		: ", not joined; select to retry";
	const said = (here ? named : "Open " + named) + (conv.held ? ", a private room" : "") + inDir +
		(bridgedFrom !== null ? ", an IRC channel bridged via " + bridgedFrom : "") +
		(unread > 0 ? ", " + unread + " unread" : people > 0 ? ", " + people + " in the room" : membership) + unwell;
	return (
		<li
			className={[here ? "here" : "", conv.held ? "held" : "", `membership-${conv.membership}`].filter(Boolean)
				.join(" ")}
			data-dir={where.mark}
		>
			<button
				type="button"
				className="room-open invite-take"
				aria-label={said}
				aria-current={here ? "page" : undefined}
				onClick={() => onPick(conv)}
			>
				<span className="hash" aria-hidden="true">
					{conv.held ? <Icon name="lock" size={13} /> : "#"}
				</span>
				<span className="rname" title={conv.id}>
					<span className="rname-text">{conv.id}</span>
					{bridgedFrom !== null && <span className="irc-chip">IRC</span>}
				</span>
				{unread > 0
					? <span className="rcount unread">{unread}</span>
					: people > 0
					? <span className="rcount">{people}</span>
					: conv.membership !== "joined"
					? <span className="rcount room-state">{conv.membership === "joining" ? "joining" : "retry"}</span>
					: null}
			</button>
			{(directory !== null || standing !== "") && (
				// A sibling of the row's own button, never inside it: a control within
				// a control is a shape no assistive software can announce, and this one
				// goes somewhere different from the row it sits under. It is where a
				// reader asks what this directory is, which belongs on the row because
				// the directory is a fact about the room rather than about a box the
				// room was put in.
				//
				// How that directory is doing goes on the same line for the same
				// reason, and is what brings the line out while this tab holds one
				// directory: naming the only directory there is would be noise, and a
				// room a reader cannot reach never is.
				<Button
					variant="caption"
					className="rwhere"
					title={directory ?? undefined}
					aria-label={dirCaptionSaid(directoryName(conv.dir, home), phase)}
					onClick={() => onAbout(conv.dir)}
				>
					<Icon name="directory" size={12} />
					{directory !== null && <span className="rwhere-said">in {directory}</span>}
					{standing !== "" && <span className="rwhere-how">{standing}</span>}
				</Button>
			)}
			{canInteract && (
				<RowClose
					title="Leave"
					said={"Leave " + named + inDir +
						(conv.held ? ". You can only return if somebody hands it to you again" : "")}
					oneWay={conv.held}
					onClose={() => onLeave(conv.key)}
				/>
			)}
		</li>
	);
}

/** A room somebody handed this tab, waiting to be taken up or let go.
 *
 * Above the rooms, and only while there are any: it is the one row in the rail
 * that is asking rather than telling, and a reader who has none should see no
 * trace of the idea.
 *
 * Which directory the offer arrived on matters here as much as it does on a
 * room: the same person may be reachable on two of them and mean two people,
 * and taking the offer up puts this reader in a room on one of them. So its
 * label names the directory it arrived on and it wears that directory's
 * color. */
export function InviteRow(
	{ invite, where, canInteract, onTake, onDrop }: {
		invite: Invitation;
		where: DirWhere;
		canInteract: boolean;
		onTake: (id: string) => Promise<void>;
		onDrop: (id: string) => void;
	},
) {
	const [taking, setTaking] = useState(false);
	const onDir = where.name === null ? "" : " on " + where.name;
	return (
		<li className="inviterow" data-dir={where.mark}>
			<button
				type="button"
				className="room-open"
				aria-label={taking
					? `Taking up ${invite.from}'s invitation to ${invite.label}${onDir}`
					: `Take up ${invite.from}'s invitation to ${invite.label}${onDir}`}
				data-busy={taking || undefined}
				disabled={taking || !canInteract}
				onClick={() => {
					setTaking(true);
					void onTake(invite.id).finally(() => setTaking(false));
				}}
			>
				<span className="hash" aria-hidden="true">
					<Icon name="lock" size={13} />
				</span>
				<span className="rname" title={invite.label}>{invite.label}</span>
				<span className="rcount invited">from {invite.from}</span>
			</button>
			{canInteract && (
				<RowClose
					title={"Decline " + invite.label}
					said={`Decline ${invite.from}'s invitation to ${invite.label}${onDir}`}
					disabled={taking}
					onClose={() => onDrop(invite.id)}
				/>
			)}
		</li>
	);
}

/** A directory this tab is on with nothing open on it.
 *
 * The same row a room gets, because it is the same kind of thing: somewhere you
 * are. Its mark is the directory glyph rather than a room's sigil, and the line
 * under it says why it is here rather than naming the directory again, because
 * the name is the row's own words above it. The way out gives the whole
 * directory back instead of one room, and pressing the row opens the join card
 * already aimed here, which is the one thing anybody wants from a server they
 * are on and in no room on. */
export function EmptyDirRow(
	{ dir, home, mark, canInteract, onJoinOn, onLeave, onAbout }: {
		dir: DirView;
		home: DirId | null;
		mark: string | undefined;
		canInteract: boolean;
		onJoinOn: (dir: DirId) => void;
		onLeave: (dir: DirId) => void;
		onAbout: (dir: DirId) => void;
	},
) {
	const name = directoryName(dir.id, home);
	const standing = dirStanding(dir.session);
	return (
		<li className="dirrow" data-dir={mark}>
			<button
				type="button"
				className="room-open"
				aria-label={"Join a room on " + name}
				disabled={!canInteract}
				onClick={() => onJoinOn(dir.id)}
			>
				<span className="hash" aria-hidden="true">
					<Icon name="directory" size={14} />
				</span>
				<span className="rname" title={dir.id}>{name}</span>
			</button>
			<Button
				variant="caption"
				className="rwhere"
				aria-label={dirCaptionSaid(name, dir.session)}
				onClick={() => onAbout(dir.id)}
			>
				{standing === ""
					? <span className="rwhere-said">no rooms yet</span>
					: <span className="rwhere-how">{standing}</span>}
			</Button>
			{canInteract && <RowClose title="Leave" said={"Leave " + name} onClose={() => onLeave(dir.id)} />}
		</li>
	);
}
