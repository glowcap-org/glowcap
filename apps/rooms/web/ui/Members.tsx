// Who is in the room. On a wide screen this is the right-hand column; on a phone
// it is a sheet that slides up over the conversation. Both are this component.
//
// The header's count button reads the same roster, through `rosterOf` below, so
// the number on the button and the list behind it cannot disagree.

import { usePeer } from "./peer.ts";
import { memo } from "react";
import type { RoomConv } from "./types.ts";
import { Icon } from "./icons.tsx";

export interface Roster {
	/** Members, online first and then alphabetical. */
	rows: [string, boolean][];
	online: number;
}

export function rosterOf(conv: RoomConv | null): Roster {
	if (!conv) return { rows: [], online: 0 };
	const rows = [...conv.members].sort((a, b) =>
		Number(b[1]) - Number(a[1]) || a[0].localeCompare(b[0])
	);
	let online = 0;
	for (const [, isOnline] of rows) if (isOnline) online++;
	return { rows, online };
}

function MemberRow(
	{ name, online, you, reachable }: {
		name: string;
		online: boolean;
		you: boolean;
		reachable: boolean;
	},
) {
	// Presence is not carried by colour alone: the pip is a filled dot when
	// online and a hollow ring when offline, and it names the state for a screen
	// reader. The button beside it, when there is one, offers a direct line to
	// any member the directory says is reachable, other than yourself; its glyph
	// is the one a direct conversation already wears in its title, two endpoints
	// with nothing in between.
	const peer = usePeer();
	const said = online ? "online" : "offline";
	return (
		<li className={said}>
			<span className="pip" role="img" aria-label={said} title={said} />
			<span className="name">{you ? name + " (you)" : name}</span>
			{!you && reachable && (
				<button
					type="button"
					className="dm-btn"
					title={"Message " + name + " directly"}
					aria-label={"Message " + name + " directly"}
					onClick={(e) => {
						e.stopPropagation();
						peer.startDm(name);
					}}
				>
					<Icon name="direct" size={15} />
				</button>
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
					roster.rows.map(([name, online]) => (
						<MemberRow
							key={name}
							name={name}
							online={online}
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
