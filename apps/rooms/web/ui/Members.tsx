// Who is in the room. On a wide screen this is the right-hand column; on a phone
// it is a sheet that slides up over the conversation. Both are this component.
//
// The header's count button reads the same roster, through `rosterOf` below, so
// the number on the button and the list behind it cannot disagree.

import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsSession } from "./controller/session.ts";
import { memo, useMemo } from "react";
import { type BridgeFacts, membersHere, type RoomConv, type Standing } from "./types.ts";
import { useConversationMembers, useSessionPaused } from "./hooks.ts";
import { memberDetail, memberIdentity } from "./member_identity.ts";
import { nothingWhilePaused } from "./text.ts";
import { useOpenModal } from "./modal.ts";
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
export function rosterOf(members: ReadonlyMap<string, Standing>, you: string): Roster {
	const mine = (name: string) => Number(name === you);
	const rows = [...members].sort((a, b) =>
		mine(b[0]) - mine(a[0]) ||
		Number(b[1].online) - Number(a[1].online) ||
		a[0].localeCompare(b[0])
	);
	return { rows, online: membersHere(members) };
}

function MemberRow(
	{ conv, bridge, name, standing, you, reachable, canInteract }: {
		/** The room this roster belongs to, which the member card needs to say
		 * where its reading came from. */
		conv: string;
		/** What the bridge behind this room calls its own, or undefined in an
		 * ordinary room. */
		bridge: BridgeFacts | undefined;
		name: string;
		standing: Standing;
		you: boolean;
		reachable: boolean;
		canInteract: boolean;
	},
) {
	// Presence is worn by the member's own chip: the pip over its corner is a
	// filled dot when online and a hollow ring when offline, and it names the
	// state for a screen reader. The button beside it, when there is one,
	// offers a direct line to any member the directory says is reachable,
	// other than yourself. Its glyph is two endpoints with nothing in between:
	// that is the act of opening a line.
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const openModalFrom = useOpenModal();
	// Away is a third thing to be, and it is about somebody who is here rather
	// than a way of being absent: the pip says away, and the reason goes beside
	// the name where it answers the question the pip raises.
	const online = standing.online;
	const away = online && standing.away !== "";
	const said = away ? "away" : online ? "online" : "offline";
	const identity = memberIdentity(name, standing, bridge);
	const detail = memberDetail(identity, standing);
	return (
		<li className={said} data-network={identity.network}>
			{
				/* The lockup is the press: pointing at a person opens what is known
				    about them, the same act the other rail's rows carry, so two lists
				    a reader sees side by side behave alike. The chip and the two lines
				    of text go inside it together, because a name and the face beside
				    it are one thing to aim at. The direct-line mark stays outside as
				    its own act, so opening a card and opening a line never share a
				    target. */
			}
			<button
				type="button"
				className="member-face"
				title={"About " + identity.name}
				onClick={(event) => openModalFrom(event.currentTarget, () => browser.aboutMember({ conv, name }))}
			>
				<PresenceAvatar name={identity.name} state={said} reason={away ? standing.away : undefined} />
				{
					/* The name truncates, so it carries itself. A long name would
				    simply have been unreadable spelled out under the row. */
				}
				<span className="name-line">
					{
						/* The mark sits beside the name rather than inside it. Inside,
						    it shared the name's box, so a name long enough to need an
						    ellipsis took the mark away with it — and a bridged member
						    is exactly who carries a long name, so the mark went missing
						    where it was most worth having. Out here the name is the
						    only part that gives way. */
					}
					<span className="name-row">
						<span className="name" title={identity.name}>
							{identity.name}
							{you && " (you)"}
						</span>
						{identity.mark !== null && (
							<span className="bridge-chip" data-network={identity.network}>{identity.mark}</span>
						)}
					</span>
					{
						/* The row's second line: an away reason, a network, or being
				    gone. It is empty for a plain member who is here, because the
				    pip has already said that, but it is always drawn and always
				    holds one line's height. A roster is a live list, and rows that
				    grew when somebody stepped away would move every other row
				    under the reader's pointer to say it. */
					}
					<span className={away ? "away-said" : "member-said"} title={away ? standing.away : undefined}>
						{detail}
					</span>
				</span>
			</button>
			{canInteract && you && standing.seat !== undefined
				? (
					<IconButton
						className="dm-btn"
						icon="gear"
						label={`Manage your ${bridge?.badge ?? "bridge"} identity`}
						size="small"
						tone="teal"
						onClick={(event) => {
							event.stopPropagation();
							browser.manageBridgeIdentity();
						}}
					/>
				)
				: canInteract && !you && reachable && (
					<IconButton
						className="dm-btn"
						icon="direct"
						label={"Message " + identity.name + " directly"}
						size="small"
						tone="teal"
						onClick={(e) => {
							e.stopPropagation();
							session.startDm(name);
						}}
					/>
				)}
		</li>
	);
}

function MembersPane(
	{ conv, nick, dmablePeers, canInteract }: {
		conv: RoomConv | null;
		nick: string;
		dmablePeers: ReadonlySet<string>;
		canInteract: boolean;
	},
) {
	const members = useConversationMembers(conv?.key ?? null);
	const roster = useMemo(() => rosterOf(members, nick), [members, nick]);
	const paused = useSessionPaused();
	// Before the first join there is no room to have a roster, so the pane says
	// what would fill it rather than reporting a wait that is not happening. Once
	// there is a room, this line already says when the list is empty, so no
	// placeholder row under it says the same thing a second time.
	const summary = !conv
		// A paused link is answered with no session, so it has no room and never
		// will while it is paused: telling this reader to join one names an act
		// that is closed to them, and the invitation reads as an explanation.
		? paused ? nothingWhilePaused : "Join a room to see who is here."
		: roster.rows.length === 0
		? "Waiting for the room roster."
		// "Seen" is a read receipt everywhere else a person has used a chat, so
		// "4 seen" invites "four people have read it". The distinction is worth
		// drawing — who is here now against everyone the room knows — and "here"
		// is the word this app already uses for it, on the topbar and under a
		// name in the rail. When everybody known is here there is no second
		// number to give.
		: roster.online === roster.rows.length
		? roster.online + " here"
		: roster.online + " of " + roster.rows.length + " here";
	return (
		<aside className="members" id="memberPane" aria-label="Members">
			<div className="members-body">
				<h2 className="overline">Members</h2>
				<p id="presenceSummary">{summary}</p>
				<ul id="members">
					{conv &&
						roster.rows.map(([name, standing]) => (
							<MemberRow
								key={name}
								conv={conv.key}
								bridge={conv.bridge}
								name={name}
								standing={standing}
								you={name === nick}
								reachable={dmablePeers.has(name.toLowerCase())}
								canInteract={canInteract}
							/>
						))}
				</ul>
			</div>
		</aside>
	);
}

// Memoised: see `useRoomsState`. None of these props change with a keystroke.
export const Members = memo(MembersPane);
