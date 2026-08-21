// Who is in the room. On a wide screen this is the right-hand column; on a phone
// it is a sheet that slides up over the conversation. Both are this component.
//
// The header's count button reads the same roster, through `rosterOf` below, so
// the number on the button and the list behind it cannot disagree.

import { usePeer } from "./peer.ts";
import { memo } from "react";
import { membersHere, type RoomConv, type Standing } from "./types.ts";
import { IconButton } from "./IconButton.tsx";
import { PresenceAvatar } from "./Avatar.tsx";

export interface Roster {
	/** Members: the reader first, then online, then alphabetical. */
	rows: [string, Standing][];
	online: number;
}

/** The roster in the order it is read, with `you` the name this directory
 * granted this reader.
 *
 * A reader looking for themselves knows exactly one name in the list and has to
 * find it among the rest, which is a scan every time and a longer one the busier
 * the room. First is the one position that never moves. Nothing else about the
 * row changes: the list already says which one is yours, and a second mark
 * saying it again would be answering a question the position has answered. */
export function rosterOf(conv: RoomConv | null, you: string): Roster {
	if (!conv) return { rows: [], online: 0 };
	const mine = (name: string) => Number(name === you);
	const rows = [...conv.members].sort((a, b) =>
		mine(b[0]) - mine(a[0]) ||
		Number(b[1].online) - Number(a[1].online) ||
		a[0].localeCompare(b[0])
	);
	return { rows, online: membersHere(conv.members) };
}

function MemberRow(
	{ name, standing, you, reachable }: {
		name: string;
		standing: Standing;
		you: boolean;
		reachable: boolean;
	},
) {
	// Presence is worn by the member's own chip: the pip over its corner is a
	// filled dot when online and a hollow ring when offline, and it names the
	// state for a screen reader. The button beside it, when there is one,
	// offers a direct line to any member the directory says is reachable,
	// other than yourself. Its glyph is two endpoints with nothing in between:
	// that is the act of opening a line.
	const peer = usePeer();
	// Away is a third thing to be, and it is about somebody who is here rather
	// than a way of being absent: the pip says away, and the reason goes beside
	// the name where it answers the question the pip raises.
	const online = standing.online;
	const away = online && standing.away !== "";
	const said = away ? "away" : online ? "online" : "offline";
	return (
		<li className={said}>
			<PresenceAvatar name={name} state={said} reason={away ? standing.away : undefined} />
			{
				/* The name truncates, so it carries itself. This row is not a control,
			    so unlike the rail's rows there is no label underneath holding the
			    whole of it — a long name would simply have been unreadable. */
			}
			<span className="name-line">
				<span className="name" title={name}>{you ? name + " (you)" : name}</span>
				{
					/* The row's second line: the away reason when one was given, the
				    state said small otherwise. Every row keeps the two-line shape,
				    so a roster reads as a column of people rather than a ragged
				    list that reflows when somebody steps away. */
				}
				{away
					? <span className="away-said" title={standing.away}>{standing.away}</span>
					: <span className="member-said">{said}</span>}
			</span>
			{!you && reachable && (
				<IconButton
					className="dm-btn"
					icon="direct"
					label={"Message " + name + " directly"}
					size="small"
					tone="teal"
					onClick={(e) => {
						e.stopPropagation();
						peer.startDm(name);
					}}
				/>
			)}
		</li>
	);
}

function MembersPane(
	{ conv, roster, nick, dmablePeers }: {
		conv: RoomConv | null;
		roster: Roster;
		nick: string;
		dmablePeers: ReadonlySet<string>;
	},
) {
	// Before the first join there is no room to have a roster, so the pane says
	// what would fill it rather than reporting a wait that is not happening. Once
	// there is a room, this line already says when the list is empty, so no
	// placeholder row under it says the same thing a second time.
	const summary = !conv
		? "Join a room to see who is here."
		: roster.rows.length === 0
		? "Waiting for the room roster."
		: roster.online + " online · " + roster.rows.length + " seen";
	return (
		<aside className="members" id="memberPane" aria-label="Members">
			<h2>Members</h2>
			<p id="presenceSummary">{summary}</p>
			<ul id="members">
				{conv &&
					roster.rows.map(([name, standing]) => (
						<MemberRow
							key={name}
							name={name}
							standing={standing}
							you={name === nick}
							reachable={dmablePeers.has(name.toLowerCase())}
						/>
					))}
			</ul>
		</aside>
	);
}

// Memoised: see `useStore`. None of these props change with a keystroke.
export const Members = memo(MembersPane);
