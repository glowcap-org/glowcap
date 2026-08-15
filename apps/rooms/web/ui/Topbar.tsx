// The header over the conversation: where you are, what kind of line it is, and
// the controls that act on it.
//
// Every word and every pressed-state here is derived from the conversation on
// screen. The old header was written by four functions that each set some of it,
// which is why one of them had to go back and rewrite a label another had left
// describing a wait that was over.

import { memo } from "react";
import type { Conv } from "./types.ts";
import { Icon } from "./icons.tsx";
import { IconButton } from "./IconButton.tsx";
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
 * header carries no second copy of it. The browser offers only WebRTC and
 * Noise-relay direct lines, so a live one is always encrypted peer to peer. A
 * phone has no room for the full phrase. */
function provenanceOf(conv: Conv, online: boolean, narrow: boolean): string {
	if (!online) return "Offline";
	// Not "Introducing…", which claims something is happening: the line opens on
	// the first message, so before one is sent nothing has started, and after one
	// has failed nothing is still running. This says the state a reader can act
	// on, and it stays true through the moment in between.
	if (conv.type === "dm" && conv.line !== "live") return "Not open yet";
	return narrow ? "Encrypted" : "Direct · encrypted, peer-to-peer";
}

function TopbarPane(
	{ conv, online, unread, mobile, railShown, rosterShown, memberCount, settingsOpen }: {
		conv: Conv | null;
		online: boolean;
		unread: number;
		mobile: boolean;
		railShown: boolean;
		rosterShown: boolean;
		memberCount: number;
		settingsOpen: boolean;
	},
) {
	const peer = usePeer();
	const title = titleOf(conv);
	const isRoom = conv?.type === "room";
	// How many people are here now, rather than how many the room has ever seen —
	// the roster behind this button draws the same distinction in words.
	const said = "Members, " + memberCount + " online";
	// The sigil in the title says what kind of line this is: a room keeps its
	// hash, and a direct line takes two endpoints with nothing in between, which
	// is what an introduction leaves behind once the room is out of the path.
	const sigil = isRoom ? "#" : conv ? <Icon name="direct" size={17} /> : null;
	return (
		<header className="topbar">
			<IconButton
				id="backBtn"
				className={unread > 0 ? "mark-btn has-unread" : "mark-btn"}
				icon="mark"
				label="Rooms and direct messages"
				size={mobile ? "large" : "normal"}
				title={railShown ? "Hide the rooms list" : "Show the rooms list"}
				aria-pressed={railShown}
				onClick={() => peer.showRail(true)}
			/>
			<h1 id="roomTitle">
				<span className="title-chip">
					<span className={isRoom ? "hash" : "at"} id="roomSigil" hidden={conv === null}>
						{sigil}
					</span>
					<span id="roomName">{title.name}</span>
					<IconButton
						id="leaveBtn"
						className="leave-x"
						icon="close"
						label={title.said}
						size="small"
						variant="ghost"
						tone="danger"
						hidden={conv === null}
						onClick={peer.endConv}
					/>
				</span>
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
			<IconButton
				id="settingsBtn"
				icon="gear"
				label="Settings"
				size={mobile ? "large" : "normal"}
				aria-pressed={settingsOpen}
				onClick={() => settingsOpen ? peer.closeSettings() : peer.openSettings()}
			/>
			<IconButton
				id="membersToggle"
				icon="group"
				label={said}
				size={mobile ? "large" : "normal"}
				badge={memberCount > 99 ? "99+" : memberCount}
				// Past two digits the exact number stops being what anyone reads: a
				// room of 143 and a room of 178 are the same room to a reader. The
				// roster behind the button keeps the real figure, as does the label
				// the button answers to.
				aria-pressed={rosterShown}
				hidden={!isRoom}
				onClick={() => peer.showRoster(!rosterShown)}
			/>
		</header>
	);
}

// Memoised: see `useStore`. None of these props change with a keystroke.
export const Topbar = memo(TopbarPane);
