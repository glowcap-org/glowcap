// What is known about the conversation on screen, on its own surface.
//
// The title is the way in: a name is something you can ask about, and this is
// the answer. `/details` opens the same card. It is not the directory's card —
// that one stays the rail caption's — and it is not Operations. It is the
// facts this tab already holds about this room or this line: how it is
// reached, where the session stands, and the rest a reader would open the
// name to check. The directory's name is the door to that card, the way the
// rail caption is. Standing and leave live here too, because a name you can
// ask about is also a name you can stand in and a name you can give back.
// `/invite` and `/join` stay commands: they are destinations and offers, not
// facts about this conversation.

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { Conv, DirId, DirView } from "./types.ts";
import { usePeer } from "./peer.ts";
import { useHeldModal, useModalDialog } from "./modal.ts";
import { IconButton } from "./IconButton.tsx";
import { Button } from "./Button.tsx";
import { Icon } from "./icons.tsx";
import { Avatar, PresenceAvatar } from "./Avatar.tsx";
import { StandingMenu } from "./Standing.tsx";
import { ConvFacts } from "./ConvFacts.tsx";
import { directoryName, roomCalled } from "./text.ts";

export function ConvCard(
	{ conv, dir, homeDir, mark, standing, follows, online, away, open, retain = false, onLayer }: {
		conv: Conv | null;
		dir: DirView | null;
		homeDir: DirId | null;
		mark: string | undefined;
		standing: string;
		follows: string;
		online: boolean;
		away: string | null;
		open: boolean;
		retain?: boolean;
		onLayer: (held: boolean) => void;
	},
) {
	type View = {
		conv: Conv;
		dir: DirView | null;
		homeDir: DirId | null;
		mark: string | undefined;
		standing: string;
		follows: string;
		online: boolean;
		away: string | null;
	};
	const last = useRef<View | null>(
		conv === null ? null : { conv, dir, homeDir, mark, standing, follows, online, away },
	);
	if (conv !== null) last.current = { conv, dir, homeDir, mark, standing, follows, online, away };
	const shown = last.current;
	const { held, onExited } = useHeldModal(open, retain);
	useLayoutEffect(() => {
		onLayer(held);
		return () => onLayer(false);
	}, [held, onLayer]);
	if (!held || shown === null) return null;
	return (
		<ConvDialog
			open={open}
			retain={retain}
			onExited={onExited}
			{...shown}
		/>
	);
}

/** The same mark the title, the rail, and the log wear: a public room is its
 * hash, a private one a lock, a person their chip. */
function ConvMark(
	{ conv, online, away }: { conv: Conv; online: boolean; away: string | null },
) {
	if (conv.type === "dm") {
		if (conv.line === "closed") return <Avatar name={conv.id} />;
		return (
			<PresenceAvatar
				name={conv.id}
				state={online ? (away !== null ? "away" : "online") : "offline"}
				reason={away ?? undefined}
			/>
		);
	}
	return (
		<span
			className={conv.held ? "hash held-lock" : "hash"}
			aria-hidden="true"
			title={conv.held
				? "A private room: it is not listed, and only people it was handed to are here"
				: undefined}
		>
			{conv.held ? <Icon name="lock" size={14} /> : "#"}
		</span>
	);
}

function leaveAsk(conv: Conv): string {
	return conv.type === "dm" ? "Close this conversation" : "Leave this room";
}

function leaveCommit(conv: Conv): string {
	return conv.type === "dm" ? "Close" : "Leave";
}

function leaveSaid(conv: Conv): string {
	if (conv.type === "dm") {
		return "Close the conversation with " + conv.id +
			"? The messages on this line go with it. You can start a new one from the room.";
	}
	if (conv.held) {
		return "Leave " + conv.id + "? You can only return if somebody hands it to you again.";
	}
	return "Leave " + roomCalled(conv.id, false) + "? You can come back by its name.";
}

function ConvDialog(
	{ open, retain, onExited, conv, dir, homeDir, mark, standing, follows, online, away }: {
		open: boolean;
		retain: boolean;
		onExited: () => void;
		conv: Conv;
		dir: DirView | null;
		homeDir: DirId | null;
		mark: string | undefined;
		standing: string;
		follows: string;
		online: boolean;
		away: string | null;
	},
) {
	const peer = usePeer();
	const close = useRef<HTMLButtonElement>(null);
	const dialog = useRef<HTMLDialogElement>(null);
	const [asking, setAsking] = useState(false);
	useEffect(() => {
		if (!open) setAsking(false);
	}, [open]);
	useModalDialog(dialog, () => peer.closeAboutConversation(), close, open, onExited, retain);
	const directory = dir === null ? "this directory" : directoryName(dir.id, homeDir);
	const named = conv.type === "room" ? roomCalled(conv.id, conv.held) : conv.id;
	return (
		<dialog ref={dialog} className="modal" aria-labelledby="convcardTitle">
			{
				/* The card wears the directory's mark the way the topbar stripe
				    does: arriving from a coloured conversation to find nothing
				    coloured makes a reader check they opened the right one. */
			}
			<div className="modal-card card-plane" data-dir={mark}>
				<div className="settings-head-row">
					<h2 id="convcardTitle">
						<ConvMark conv={conv} online={online} away={away} />
						{conv.id}
					</h2>
					<IconButton
						ref={close}
						id="convcardClose"
						icon="close"
						label="Close"
						size="small"
						variant="ghost"
						onClick={() => peer.closeAboutConversation()}
					/>
				</div>
				<ConvFacts conv={conv} dir={dir} directory={directory} />
				{conv.type === "room" && (
					<div className="group well">
						<div className="dircard-standing">
							<span>Where you are here</span>
							<StandingMenu
								id="convcardStanding"
								own={conv.standing}
								effective={standing}
								follows={follows}
								about={named}
								up
								onSay={(said) => peer.setRoomStanding(conv.key, said)}
							/>
						</div>
					</div>
				)}
				{asking
					? (
						<>
							<p className="hint" id="convcardLeaveSaid">{leaveSaid(conv)}</p>
							<Button
								id="convcardLeave"
								aria-describedby="convcardLeaveSaid"
								onClick={() => peer.endConv()}
							>
								{leaveCommit(conv)}
							</Button>
							<Button id="convcardLeaveStay" variant="quiet" onClick={() => setAsking(false)}>
								Stay
							</Button>
						</>
					)
					: (
						<Button id="convcardLeaveAsk" variant="quiet" onClick={() => setAsking(true)}>
							{leaveAsk(conv)}
						</Button>
					)}
			</div>
		</dialog>
	);
}
