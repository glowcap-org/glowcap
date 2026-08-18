// The header over the conversation: where you are, what kind of line it is, and
// the controls that act on it.
//
// Every word and every pressed-state here is derived from the conversation on
// screen. The old header was written by four functions that each set some of it,
// which is why one of them had to go back and rewrite a label another had left
// describing a wait that was over.

import { memo } from "react";
import type { Conv } from "./types.ts";
import { PresenceAvatar } from "./Avatar.tsx";
import { Icon } from "./icons.tsx";
import { IconButton } from "./IconButton.tsx";
import { SettingsButton } from "./SettingsButton.tsx";
import { StandingMenu } from "./Standing.tsx";
import { usePeer } from "./peer.ts";
import { roomCalled } from "./text.ts";

/** What the title says, and what its mark would do. */
function titleOf(conv: Conv | null): { name: string; said: string } {
	if (!conv) return { name: "No room yet", said: "No room yet" };
	if (conv.type === "room") {
		// A held room's leave is one-way — there is no name to walk back in by —
		// and the control is where that has to be said, before it is pressed.
		return {
			name: conv.id,
			said: conv.held
				? `Leave the private room ${conv.id}. You can only return if somebody hands it to you again`
				: "Leave #" + conv.id,
		};
	}
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
	{ conv, online, away, unread, mobile, railShown, rosterShown, memberCount, settingsOpen, standing, follows }: {
		conv: Conv | null;
		online: boolean;
		/** Why a direct peer has stepped away, by the shared rooms' word, or
		 * null while they are here; always null over a room. */
		away: string | null;
		unread: number;
		mobile: boolean;
		railShown: boolean;
		rosterShown: boolean;
		memberCount: number;
		settingsOpen: boolean;
		/** Where the reader stands in this room, whichever level is answering. */
		standing: string;
		/** What this room follows while it has no word of its own, named for a
		 * reader: the directory it is on. */
		follows: string;
	},
) {
	const peer = usePeer();
	const title = titleOf(conv);
	const isRoom = conv?.type === "room";
	// How many people are here now, rather than how many the room has ever seen —
	// the roster behind this button draws the same distinction in words.
	const said = "Members, " + memberCount + " online";
	// The title names the thing you are in. A room is a place, so it wears its
	// hash — or a lock, if it is private, which is the one place a reader can
	// see without leaving that this room is not one anybody can walk into by
	// name. A direct line is a person, so it wears the same chip the rail and
	// the log already use. What kind of path the messages take is the
	// provenance beside the title, not a second mark fighting the face.
	const heldRoom = conv?.type === "room" && conv.held;
	const sigil = heldRoom ? <Icon name="lock" size={15} /> : isRoom ? "#" : conv
		? (
			<PresenceAvatar
				name={conv.id}
				state={online ? (away !== null ? "away" : "online") : "offline"}
				reason={away ?? undefined}
			/>
		)
		: null;
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
					<span
						className={heldRoom ? "hash held-lock" : isRoom ? "hash" : undefined}
						id="roomSigil"
						hidden={conv === null}
						title={heldRoom
							? "A private room: it is not listed, and only people it was handed to are here"
							: undefined}
					>
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
						// Leaving a named room is calm and reversible, so the mark wears
						// the quiet ink. Danger is kept for the one leave that cannot be
						// walked back: a private room, which the label already warns
						// about in the same condition.
						tone={heldRoom ? "danger" : "neutral"}
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
			{
				/* Settings travels with the list: in the rail while it is up, and
				    on this bar when it is away. It sits to the left of standing,
				    not beside members — that end of the bar is already the roster. */
			}
			{!railShown && <SettingsButton id="settingsBtn" mobile={mobile} settingsOpen={settingsOpen} />}
			{
				/* Where the reader stands in this one room. The innermost of the three
			    levels, and the only one that belongs to a conversation rather than
			    to the reader, which is why it is the only one drawn in a header.
			    Not on a phone, where the header holds a back mark, a name, and two
			    controls already; the other two levels are reachable there, from the
			    foot of the rail and from a directory's card. */
			}
			{isRoom && conv !== null && !mobile && (
				<StandingMenu
					id="roomStanding"
					own={conv.type === "room" ? conv.standing : null}
					effective={standing}
					follows={follows}
					about={roomCalled(conv.id, conv.held)}
					onSay={(said) => peer.setRoomStanding(conv.key, said)}
				/>
			)}
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
