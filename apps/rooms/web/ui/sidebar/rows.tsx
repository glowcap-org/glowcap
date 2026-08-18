// Rows in the rooms rail: a room you are in, a directory with nothing open,
// an invitation waiting, and the mark that ends a row.

import {
	type DirId,
	dirMark,
	type DirView,
	type Invitation,
	membersHere,
	type RoomConv,
	type SessionPhase,
} from "../types.ts";
import { directoryName, roomCalled } from "../text.ts";
import { Icon } from "../icons.tsx";
import { PHASE_SAID } from "../text.ts";
import { IconButton } from "../IconButton.tsx";
import { Button } from "../Button.tsx";

export function Empty({ text }: { text: string }) {
	return <li className="empty">{text}</li>;
}

/** The mark that ends a row, in the slot the row's badge otherwise fills. Both
 * lists carry one and they differ only in what they are called.
 *
 * Leaving is ordinary and reversible, so the mark wears the quiet ink. The one
 * exception is `oneWay`, a leave that cannot be walked back: it keeps the
 * danger tone, on the same condition the spoken label already warns about. */
export function RowClose(
	{ title, said, oneWay, onClose }: { title: string; said: string; oneWay?: boolean; onClose: () => void },
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
	{ conv, unread, here, directory, mark, phase, onPick, onLeave, onAbout }: {
		conv: RoomConv;
		unread: number;
		here: boolean;
		/** What to call the directory this room is in, or null while this tab holds
		 * only one and saying so would be noise. It is drawn on the row, not only
		 * spoken: the colour beside it is the glance, and this is what carries the
		 * same fact for a reader who cannot use colour. */
		directory: string | null;
		/** Which mark that directory wears, or undefined when none wears one. Set
		 * together with `directory`, never alone, so a colour is never the only thing
		 * telling two rooms apart. */
		mark: string | undefined;
		phase: SessionPhase;
		onPick: (conv: RoomConv) => void;
		onLeave: (key: string) => void;
		onAbout: (dir: DirId) => void;
	},
) {
	// The row opens the room and carries a second control beside it to leave.
	// Both are real buttons: an interactive control nested inside another is a
	// structure no assistive software can read out.
	//
	// Leaving lives in the badge's slot, so the row gives up no width to hold it
	// and no name is cut short for a mark that is not showing.
	const where = directory === null ? "" : " in " + directory;
	const unwell = phase === "connected" ? "" : ", directory " + phase;
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
	const said = (here ? named : "Open " + named) + (conv.held ? ", a private room" : "") + where +
		(unread > 0 ? ", " + unread + " unread" : people > 0 ? ", " + people + " in the room" : "") + unwell;
	return (
		<li
			className={[here ? "here" : "", conv.held ? "held" : ""].filter(Boolean).join(" ")}
			data-dir={mark}
		>
			<button
				type="button"
				className="room-open"
				aria-label={said}
				aria-current={here ? "page" : undefined}
				onClick={() => onPick(conv)}
			>
				<span className="hash" aria-hidden="true">
					{conv.held ? <Icon name="lock" size={13} /> : "#"}
				</span>
				<span className="rname" title={conv.id}>{conv.id}</span>
				{unread > 0
					? <span className="rcount unread">{unread}</span>
					: people > 0
					? <span className="rcount">{people}</span>
					: null}
			</button>
			{directory !== null && (
				// A sibling of the row's own button, never inside it: a control within a
				// control is a shape no assistive software can announce, and this one
				// goes somewhere different from the row it sits under.
				<Button
					variant="caption"
					className="rwhere"
					title={directory}
					aria-label={"About " + directory}
					onClick={() => onAbout(conv.dir)}
				>
					<Icon name="directory" size={12} />
					<span className="rwhere-said">in {directory}</span>
				</Button>
			)}
			<RowClose
				title="Leave"
				said={"Leave " + named + where +
					(conv.held ? ". You can only return if somebody hands it to you again" : "")}
				oneWay={conv.held}
				onClose={() => onLeave(conv.key)}
			/>
		</li>
	);
}

/** A directory this tab is on with nothing open on it.
 *
 * The same row a room gets, because it is the same kind of thing: somewhere you
 * are. Its mark is the directory glyph rather than a room's sigil, the line
 * under it says why it is here, and the way out gives the whole directory back
 * instead of one room. Pressing it opens the join card already aimed here, which
 * is the one thing anybody wants from a server they are on and in no room on. */
/** A room somebody handed this tab, waiting to be taken up or let go.
 *
 * Above the rooms, and only while there are any: it is the one row in the rail
 * that is asking rather than telling, and a reader who has none should see no
 * trace of the idea. */
export function InviteRow(
	{ invite, mark, onTake, onDrop }: {
		invite: Invitation;
		mark: string | undefined;
		onTake: (id: string) => void;
		onDrop: (id: string) => void;
	},
) {
	return (
		<li className="inviterow" data-dir={mark}>
			<button
				type="button"
				className="room-open"
				aria-label={`Take up ${invite.from}'s invitation to ${invite.label}`}
				onClick={() => onTake(invite.id)}
			>
				<span className="hash" aria-hidden="true">
					<Icon name="lock" size={13} />
				</span>
				<span className="rname" title={invite.label}>{invite.label}</span>
				<span className="rcount invited">from {invite.from}</span>
			</button>
			<RowClose
				title={"Decline " + invite.label}
				said={`Decline ${invite.from}'s invitation to ${invite.label}`}
				onClose={() => onDrop(invite.id)}
			/>
		</li>
	);
}

export function EmptyDirRow(
	{ dir, home, marked, onJoinOn, onLeave, onAbout }: {
		dir: DirView;
		home: DirId | null;
		marked: boolean;
		onJoinOn: (dir: DirId) => void;
		onLeave: (dir: DirId) => void;
		onAbout: (dir: DirId) => void;
	},
) {
	const name = directoryName(dir.id, home);
	const said = dir.session === "connected" ? "no rooms yet" : PHASE_SAID[dir.session];
	return (
		<li className="dirrow" data-dir={marked ? dirMark(dir.id, home, dir.slot) : undefined}>
			<button
				type="button"
				className="room-open"
				aria-label={"Join a room on " + name}
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
				aria-label={"About " + name}
				onClick={() => onAbout(dir.id)}
			>
				<span className="rwhere-said">{said}</span>
			</Button>
			<RowClose title="Leave" said={"Leave " + name} onClose={() => onLeave(dir.id)} />
		</li>
	);
}
