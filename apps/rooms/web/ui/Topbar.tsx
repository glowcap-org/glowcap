// The header over the conversation: where you are, what kind of line it is, and
// the three controls that act on it.
//
// Every word and every pressed-state here is derived from the conversation on
// screen. The old header was written by four functions that each set some of it,
// which is why one of them had to go back and rewrite a label another had left
// describing a wait that was over.

import { memo } from "react";
import type { Conv } from "./types.ts";
import { Icon } from "./icons.tsx";
import { usePeer } from "./peer.ts";

/** What the title says, and what its mark would do. */
function titleOf(conv: Conv | null): { name: string; said: string } {
	if (!conv) return { name: "No room yet", said: "No room yet" };
	if (conv.type === "room") return { name: conv.id, said: "Leave #" + conv.id };
	return { name: conv.id, said: "Close the direct message with " + conv.id };
}

/** What a direct line's chip says about how the message will travel.
 *
 * A direct line has no roster, so this chip is the whole story, which is why the
 * header carries no second copy of it. A browser DM is redeemed over iroh, so a
 * live direct line is always encrypted and peer to peer. A phone has no room for
 * the full phrase. */
function provenanceOf(conv: Conv, online: boolean, narrow: boolean): string {
	if (!online) return "Offline";
	if (conv.type === "dm" && conv.line !== "live") return "Introducing…";
	return narrow ? "Encrypted" : "Direct · encrypted, peer-to-peer";
}

function TopbarPane(
	{ conv, online, unread, mobile, railShown, rosterShown, memberCount, theme, notifyOn }: {
		conv: Conv | null;
		online: boolean;
		unread: number;
		mobile: boolean;
		railShown: boolean;
		rosterShown: boolean;
		memberCount: number;
		theme: "light" | "dark";
		notifyOn: boolean;
	},
) {
	const peer = usePeer();
	const title = titleOf(conv);
	const isRoom = conv?.type === "room";
	// Past two digits the exact number stops being the thing anyone reads: a room
	// of 143 and a room of 178 are the same room to a reader. The panel behind the
	// button keeps the real figure, as does the label the button answers to.
	const said = "Members, " + memberCount + " online";
	// The sigil in the title says what kind of line this is: a room keeps its
	// hash, and a direct line takes two endpoints with nothing in between, which
	// is what an introduction leaves behind once the room is out of the path.
	const sigil = isRoom ? "#" : conv ? <Icon name="direct" size={17} /> : null;
	return (
		<header className="topbar">
			<button
				type="button"
				id="backBtn"
				className={unread > 0 ? "icon mark-btn has-unread" : "icon mark-btn"}
				title={railShown ? "Hide the rooms list" : "Show the rooms list"}
				aria-label="Rooms and direct messages"
				aria-pressed={railShown}
				onClick={() => peer.showRail(true)}
			/>
			<h1 id="roomTitle">
				<button
					id="leaveBtn"
					className="title-btn"
					type="button"
					disabled={conv === null}
					title={conv ? title.said : undefined}
					aria-label={title.said}
					onClick={peer.endConv}
				>
					<span className={isRoom ? "hash" : "at"} id="roomSigil" hidden={conv === null}>
						{sigil}
					</span>
					<span id="roomName">{title.name}</span>
					<span className="leave-x" aria-hidden="true">
						<Icon name="close" size={14} />
					</span>
				</button>
			</h1>
			<span
				className={conv?.type === "dm"
					? (online ? "provenance show" : "provenance show offline")
					: "provenance"}
				id="provenance"
				role="note"
			>
				<span className="lock" id="provenanceLock">
					<Icon name="lock" size={12} />
				</span>
				<span id="provenanceText">
					{conv?.type === "dm" ? provenanceOf(conv, online, mobile) : ""}
				</span>
			</span>
			<span className="spacer" />
			<button
				type="button"
				id="notifyToggle"
				className={notifyOn ? "icon on" : "icon"}
				title="Notify me when I'm mentioned"
				aria-label="Toggle mention notifications"
				aria-pressed={notifyOn}
				hidden={conv === null}
				onClick={peer.toggleNotify}
			>
				<Icon name={notifyOn ? "bell" : "bellOff"} />
			</button>
			<button
				type="button"
				id="themeToggle"
				className="icon"
				title={theme === "dark" ? "Switch to light" : "Switch to syrup (dark)"}
				aria-label="Toggle light or dark theme"
				onClick={peer.toggleTheme}
			>
				<Icon name={theme === "dark" ? "sun" : "moon"} />
			</button>
			<button
				type="button"
				id="membersToggle"
				className="icon count-btn"
				aria-pressed={rosterShown}
				aria-label={said}
				title={said}
				hidden={!isRoom}
				onClick={() => peer.showRoster(!rosterShown)}
			>
				<span className="count-mark" aria-hidden="true">
					<Icon name="group" />
				</span>
				<span id="memberCount">{memberCount > 99 ? "99+" : memberCount}</span>
			</button>
		</header>
	);
}

// Memoised: see `useStore`. None of these props change with a keystroke.
export const Topbar = memo(TopbarPane);
