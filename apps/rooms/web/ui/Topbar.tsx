// The header over the conversation: where you are, what kind of line it is, and
// the controls that act on it. Standing on /ops it keeps its shell duties,
// the rail toggle and Settings, and wears the operations title instead of a
// conversation's.
//
// Every word and every pressed-state here is derived from the conversation on
// screen. The old header was written by four functions that each set some of it,
// which is why one of them had to go back and rewrite a label another had left
// describing a wait that was over.

import { memo } from "react";
import type { Conv, DirId } from "./types.ts";
import { awayByPeer, awayOf, membersHere } from "./types.ts";
import { PresenceAvatar } from "./Avatar.tsx";
import { Icon } from "./icons.tsx";
import { roomMarkGlyph } from "./room_mark.tsx";
import { roomPreset } from "../../lib/room/policy.ts";
import { IconButton } from "./IconButton.tsx";
import { SettingsButton } from "./SettingsButton.tsx";
import { StandingMenu } from "./Standing.tsx";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsSession } from "./controller/session.ts";
import { useOpenModal } from "./modal.ts";
import { useRoomsState } from "./hooks.ts";
import { NO_MEMBERS, unreadTotal } from "./store/core.ts";
import { directoryName, roomCalled } from "./text.ts";

const NO_CONVS: ReadonlyMap<string, Conv> = new Map();

/** What the title says, and what its mark would do. */
function titleOf(conv: Conv | null, home: DirId | null): { name: string; said: string } {
	if (!conv) return { name: "No room yet", said: "No room yet" };
	if (conv.type === "directory") {
		const name = directoryName(conv.dir, home);
		return { name, said: "Leave " + name };
	}
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
 * Noise-relay direct lines, so a live one is always encrypted peer to session. A
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
	{
		canInteract,
		conv,
		ops,
		online,
		mobile,
		railShown,
		rosterShown,
		settingsOpen,
		standing,
		follows,
		aboutConv,
		aboutDir,
	}: {
		canInteract: boolean;
		conv: Conv | null;
		/** Standing on /ops: the bar keeps its shell controls and wears the
		 * operations title. */
		ops: boolean;
		online: boolean;
		mobile: boolean;
		railShown: boolean;
		rosterShown: boolean;
		settingsOpen: boolean;
		/** Where the reader stands in this room, whichever level is answering. */
		standing: string;
		/** What this room follows while it has no word of its own, named for a
		 * reader: the directory it is on. */
		follows: string;
		/** Whether the card about this conversation is up. */
		aboutConv: boolean;
		/** Whether the card about this directory is up. */
		aboutDir: boolean;
	},
) {
	const openModalFrom = useOpenModal();
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const members = useRoomsState((state) => state.members);
	const homeDir = useRoomsState((state) => state.homeDir);
	const unread = useRoomsState(unreadTotal);
	const convs = useRoomsState((state) => conv?.type === "dm" ? state.convs : NO_CONVS);
	const memberCount = conv?.type === "room" ? membersHere(members.get(conv.key) ?? NO_MEMBERS) : 0;
	const away = conv?.type === "dm" ? awayOf(awayByPeer(convs, members), conv.dir, conv.id) : null;
	// The rail toggle is the bar's one constant, whatever the cell shows.
	const railToggle = (
		<IconButton
			id="backBtn"
			className={unread > 0 ? "mark-btn has-unread" : "mark-btn"}
			icon="mark"
			label="Rooms and direct messages"
			size={mobile ? "large" : "normal"}
			title={railShown ? "Hide the rooms list" : "Show the rooms list"}
			aria-pressed={railShown}
			onClick={() => browser.showRail(true)}
		/>
	);
	if (ops) {
		return (
			<header className="topbar">
				{railToggle}
				{
					/* The plain word, in the conversation title's own chip: a
				    conversation title carries no product logo, and the rail
				    toggle beside this already wears the mark. */
				}
				<h1 id="roomTitle">
					<span className="title-chip">
						<span id="operationsTitle">Operations</span>
					</span>
				</h1>
				<span className="spacer" />
				{!railShown && <SettingsButton id="settingsBtn" mobile={mobile} settingsOpen={settingsOpen} />}
			</header>
		);
	}
	const title = titleOf(conv, homeDir);
	const isRoom = conv?.type === "room";
	const isDirectory = conv?.type === "directory";
	// How many people are here now, rather than how many the room has ever seen —
	// the roster behind this button draws the same distinction in words.
	const said = "Members, " + memberCount + " here";
	// The title names the thing you are in. A room is a place, so it wears its
	// hash — or a lock, if it is private, which is the one place a reader can
	// see without leaving that this room is not one anybody can walk into by
	// name. A directory wears the same glyph the rail already uses for one. A
	// direct line is a person, so it wears the same chip the rail and the log
	// already use. What kind of path the messages take is the provenance beside
	// the title, not a second mark fighting the face.
	const heldRoom = conv?.type === "room" && conv.held;
	const roomStanding = conv?.type === "room" ? roomPreset(conv.policy) : null;
	const sigil = roomStanding !== null
		? roomMarkGlyph(roomStanding, 15)
		: isDirectory
		? <Icon name="directory" size={15} />
		: conv
		? (
			<PresenceAvatar
				name={conv.id}
				state={online ? (away !== null ? "away" : "online") : "offline"}
				reason={away ?? undefined}
			/>
		)
		: null;
	const aboutOpen = isDirectory ? aboutDir : aboutConv;
	const aboutControls = isDirectory ? "dircardTitle" : "convcardTitle";
	const about = conv === null
		? undefined
		: conv.type === "directory"
		? "About " + directoryName(conv.dir, homeDir)
		: conv.type === "room"
		? "About " + roomCalled(conv.id, conv.held)
		: "About the direct message with " + conv.id;
	const openAbout = (event: { currentTarget: HTMLElement }) =>
		openModalFrom(event.currentTarget, () => {
			if (conv?.type === "directory") browser.aboutDirectory(conv.dir);
			else browser.aboutConversation();
		});
	return (
		<header className="topbar">
			{railToggle}
			<h1 id="roomTitle">
				<span className="title-chip">
					{conv === null
						? (
							<>
								<span
									className={heldRoom ? "hash held-lock" : isRoom ? "hash" : undefined}
									id="roomSigil"
									hidden
								>
									{sigil}
								</span>
								<span id="roomName">{title.name}</span>
							</>
						)
						: (
							<button
								type="button"
								id="roomAbout"
								className="title-about"
								aria-haspopup="dialog"
								aria-expanded={aboutOpen}
								aria-controls={aboutOpen ? aboutControls : undefined}
								aria-label={about}
								title={about}
								onClick={openAbout}
							>
								<span
									className={heldRoom ? "hash held-lock" : isRoom || isDirectory ? "hash" : undefined}
									id="roomSigil"
									title={heldRoom
										? "A private room: it is not listed, and only people it was handed to are here"
										: undefined}
								>
									{sigil}
								</span>
								<span id="roomName">{title.name}</span>
							</button>
						)}
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
						// about in the same condition. The mark asks first in every
						// conversation's own card; the question wears the danger colour.
						tone={heldRoom ? "danger" : "neutral"}
						hidden={conv === null || !canInteract}
						onClick={(event) => {
							if (conv == null) return;
							openModalFrom(event.currentTarget, () => {
								if (conv.type === "directory") browser.aboutDirectory(conv.dir, true);
								else browser.aboutConversation("about", true);
							});
						}}
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
					onSay={(said) => session.setRoomStanding(conv.key, said)}
					disabled={!canInteract}
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
				onClick={() => browser.showRoster(!rosterShown)}
			/>
		</header>
	);
}

// Memoised: see `useRoomsState`. None of these props change with a keystroke.
export const Topbar = memo(TopbarPane);
