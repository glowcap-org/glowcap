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
// The title's close mark asks to leave here, the same question this card
// already asked. `/invite` and `/join` stay commands: they are destinations and offers, not
// facts about this conversation.

import { memo, useEffect, useLayoutEffect, useRef, useState } from "react";
import {
	awayByPeer,
	awayOf,
	type DirId,
	type DirView,
	type IrcBridgeRow,
	type RoomConv,
	type SessionConv,
} from "./types.ts";
import { useConversationMembers, useRoomsState } from "./hooks.ts";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsSession } from "./controller/session.ts";
import { useHeldModal, useModalDialog } from "./modal.ts";
import { ModalHead } from "./ModalHead.tsx";
import { Confirm } from "./Confirm.tsx";
import { Button } from "./Button.tsx";
import { roomMarkGlyph, roomMarkTitle } from "./room_mark.tsx";
import { roomPreset } from "../../lib/room/policy.ts";
import { Avatar, PresenceAvatar } from "./Avatar.tsx";
import { StandingMenu } from "./Standing.tsx";
import { ConvFacts } from "./ConvFacts.tsx";
import { RoomCapabilities } from "./RoomCapabilities.tsx";
import { RoomModeration } from "./RoomModeration.tsx";
import { BridgeIdentityForm } from "./BridgeIdentityForm.tsx";
import { directoryName, roomCalled } from "./text.ts";
import { type TabFace, Tabs } from "./Tabs.tsx";
import type { ArchiveShareView } from "./archive_model.ts";
import { DmArchiveHistory, RoomArchiveHistory } from "./ArchiveHistory.tsx";
import { bridgedOrigin, roomPublication } from "./store/dirs.ts";
import { useCommitments } from "./commitment.tsx";

export const ConvCard = memo(function ConvCard(
	{
		canInteract,
		conv,
		archiveShares,
		dir,
		homeDir,
		mark,
		standing,
		follows,
		online,
		open,
		initialPane,
		request,
		administeredBridge,
		retain = false,
		askingLeave,
		onLayer,
	}: {
		canInteract: boolean;
		conv: SessionConv | null;
		archiveShares: readonly ArchiveShareView[];
		dir: DirView | null;
		homeDir: DirId | null;
		mark: string | undefined;
		standing: string;
		follows: string;
		online: boolean;
		open: boolean;
		initialPane: "about" | "irc" | "capabilities";
		request: number;
		administeredBridge: IrcBridgeRow | null;
		retain?: boolean;
		askingLeave: boolean;
		onLayer: (held: boolean) => void;
	},
) {
	const members = useRoomsState((state) => state.members);
	const convs = useRoomsState((state) => state.convs);
	type View = {
		conv: SessionConv;
		archiveShares: readonly ArchiveShareView[];
		dir: DirView | null;
		homeDir: DirId | null;
		mark: string | undefined;
		standing: string;
		follows: string;
		online: boolean;
		initialPane: "about" | "irc" | "capabilities";
		request: number;
		administeredBridge: IrcBridgeRow | null;
		canInteract: boolean;
	};
	const last = useRef<View | null>(
		conv === null ? null : {
			conv,
			archiveShares,
			dir,
			homeDir,
			mark,
			standing,
			follows,
			online,
			initialPane,
			request,
			administeredBridge,
			canInteract,
		},
	);
	if (conv !== null) {
		last.current = {
			conv,
			archiveShares,
			dir,
			homeDir,
			mark,
			standing,
			follows,
			online,
			initialPane,
			request,
			administeredBridge,
			canInteract,
		};
	}
	const shown = last.current;
	const { held, onExited } = useHeldModal(open, retain);
	useLayoutEffect(() => {
		onLayer(held);
		return () => onLayer(false);
	}, [held, onLayer]);
	if (!held || shown === null) return null;
	const away = shown.conv.type === "dm" ? awayOf(awayByPeer(convs, members), shown.conv.dir, shown.conv.id) : null;
	return (
		<ConvDialog
			open={open}
			retain={retain}
			onExited={onExited}
			{...shown}
			away={away}
			askingLeave={askingLeave}
		/>
	);
});

/** The same mark the title, the rail, and the log wear: a public room is its
 * hash, a private one a lock, a person their chip. */
function ConvMark(
	{ conv, online, away }: { conv: SessionConv; online: boolean; away: string | null },
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
			title={roomMarkTitle(roomPreset(conv.policy))}
		>
			{roomMarkGlyph(roomPreset(conv.policy), 14)}
		</span>
	);
}

function leaveAsk(conv: SessionConv): string {
	return conv.type === "dm" ? "Close this conversation" : "Leave this room";
}

function leaveCommit(conv: SessionConv): string {
	return conv.type === "dm" ? "Close" : "Leave";
}

function leaveSaid(conv: SessionConv): string {
	if (conv.type === "dm") {
		return "Close the conversation with " + conv.id +
			"? The messages on this line go with it. You can start a new one from the room.";
	}
	if (conv.held) {
		return "Leave " + conv.id + "? You can only return if somebody hands it to you again.";
	}
	return "Leave " + roomCalled(conv.id, false) + "? You can come back by its name.";
}

type RoomPane = "about" | "irc" | "capabilities" | "moderation";

const ROOM_TABS: readonly TabFace<RoomPane>[] = [
	{ id: "about", domId: "convcardAboutTab", label: "About", panelId: "convcardAboutPanel" },
	{
		id: "irc",
		domId: "convcardIrcTab",
		label: "IRC",
		panelId: "convcardIrcPanel",
	},
	{
		id: "capabilities",
		domId: "convcardCapabilitiesTab",
		label: "Capabilities",
		panelId: "convcardCapabilitiesPanel",
	},
	{
		id: "moderation",
		domId: "convcardModerationTab",
		label: "Moderation",
		panelId: "convcardModerationPanel",
	},
];

function RoomCardBody(
	{
		conv,
		dir,
		directory,
		named,
		standing,
		follows,
		asking,
		setAsking,
		askingLeave,
		initialPane,
		administeredBridge,
		canInteract,
	}: {
		conv: RoomConv;
		dir: DirView | null;
		directory: string;
		named: string;
		standing: string;
		follows: string;
		asking: boolean;
		setAsking: (asking: boolean) => void;
		askingLeave: boolean;
		initialPane: "about" | "irc" | "capabilities";
		administeredBridge: IrcBridgeRow | null;
		canInteract: boolean;
	},
) {
	const session = useRoomsSession();
	const roster = useConversationMembers(conv.key);
	const held = conv.grants.has("steward");
	const roomAvailable = conv.membership === "joined";
	const canModerate = (held && roomAvailable) || administeredBridge !== null;
	const ownIrc = dir === null ? undefined : roster.get(dir.nick)?.seat;
	const bridgeOrigin = bridgedOrigin(dir ?? undefined, conv.publicationId);
	const publication = roomPublication(dir ?? undefined, conv.publicationId);
	const authoritySource = conv.publicationId === undefined ? "local" : publication?.kind ?? "unknown";
	const tabs = ROOM_TABS.filter((tab) =>
		(tab.id === "about" || canInteract) &&
		(tab.id !== "irc" || ownIrc !== undefined) && (tab.id !== "moderation" || canModerate)
	);
	const [chosen, setChosen] = useState<RoomPane>(
		initialPane === "irc" && ownIrc !== undefined
			? "irc"
			: initialPane === "capabilities" && canInteract
			? "capabilities"
			: "about",
	);
	const pane = !canInteract
		? "about"
		: chosen === "moderation" && !canModerate
		? "capabilities"
		: chosen === "irc" && ownIrc === undefined
		? "about"
		: chosen;
	const tabbed = tabs.length > 1;
	return (
		<>
			{tabbed && (
				<Tabs
					id="convcardTabs"
					tabs={tabs}
					selected={pane}
					labelledBy="convcardTitle"
					onSelect={setChosen}
				/>
			)}
			<div
				id="convcardAboutPanel"
				hidden={pane !== "about"}
				role={tabbed ? "tabpanel" : undefined}
				aria-labelledby={tabbed ? "convcardAboutTab" : undefined}
			>
				<ConvFacts conv={conv} dir={dir} directory={directory} bridgeOrigin={bridgeOrigin} />
				<div className="group well">
					<div className="dircard-standing">
						<span>You are</span>
						<StandingMenu
							id="convcardStanding"
							own={conv.standing}
							effective={standing}
							follows={follows}
							about={named}
							up
							onSay={(said) => session.setRoomStanding(conv.key, said)}
							disabled={!canInteract}
						/>
					</div>
				</div>
				{canInteract && <RoomArchiveHistory conv={conv} you={dir?.nick ?? ""} />}
				{canInteract && (
					<LeaveControls conv={conv} asking={asking} setAsking={setAsking} askingLeave={askingLeave} />
				)}
			</div>
			{canInteract && (
				<div
					id="convcardCapabilitiesPanel"
					hidden={pane !== "capabilities"}
					role="tabpanel"
					aria-labelledby="convcardCapabilitiesTab"
				>
					<RoomCapabilities conv={conv} available={roomAvailable} authoritySource={authoritySource} />
				</div>
			)}
			{ownIrc !== undefined && (
				<div id="convcardIrcPanel" hidden={pane !== "irc"} role="tabpanel" aria-labelledby="convcardIrcTab">
					<BridgeIdentityForm
						conv={conv}
						connected={roomAvailable}
						stateKey={`${ownIrc.state}\u0000${ownIrc.nick}`}
					/>
				</div>
			)}
			{canModerate && (
				<div
					id="convcardModerationPanel"
					hidden={pane !== "moderation"}
					role="tabpanel"
					aria-labelledby="convcardModerationTab"
				>
					<RoomModeration
						conv={conv}
						you={dir?.nick ?? ""}
						available={roomAvailable}
						administeredBridge={administeredBridge}
					/>
				</div>
			)}
		</>
	);
}

function LeaveControls(
	{ conv, asking, setAsking, askingLeave }: {
		conv: SessionConv;
		asking: boolean;
		setAsking: (asking: boolean) => void;
		askingLeave: boolean;
	},
) {
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const commitments = useCommitments();
	return asking
		? (
			<Confirm
				id="convcardLeaveSaid"
				label={leaveAsk(conv)}
				say={leaveSaid(conv)}
				keep="Stay"
				commit={leaveCommit(conv)}
				keepId="convcardLeaveStay"
				commitId="convcardLeave"
				onKeep={() => {
					setAsking(false);
					if (askingLeave) browser.aboutConversation();
				}}
				onCommit={() => commitments.request(() => session.endConv())}
			/>
		)
		: (
			<div className="actions">
				<Button id="convcardLeaveAsk" variant="quiet" onClick={() => setAsking(true)}>
					{leaveAsk(conv)}…
				</Button>
			</div>
		);
}

function ConvDialog(
	{
		open,
		retain,
		onExited,
		conv,
		archiveShares,
		dir,
		homeDir,
		mark,
		standing,
		follows,
		online,
		away,
		initialPane,
		request,
		administeredBridge,
		canInteract,
		askingLeave,
	}: {
		open: boolean;
		retain: boolean;
		onExited: () => void;
		conv: SessionConv;
		archiveShares: readonly ArchiveShareView[];
		dir: DirView | null;
		homeDir: DirId | null;
		mark: string | undefined;
		standing: string;
		follows: string;
		online: boolean;
		away: string | null;
		initialPane: "about" | "irc" | "capabilities";
		request: number;
		administeredBridge: IrcBridgeRow | null;
		canInteract: boolean;
		askingLeave: boolean;
	},
) {
	const browser = useRoomsBrowser();
	const commitments = useCommitments();
	const close = useRef<HTMLButtonElement>(null);
	const dialog = useRef<HTMLDialogElement>(null);
	const [asking, setAsking] = useState(askingLeave);
	useEffect(() => {
		if (askingLeave) setAsking(true);
		else if (open) setAsking(false);
	}, [askingLeave, open]);
	const requestClose = () => commitments.request(() => browser.closeAboutConversation());
	useModalDialog(dialog, requestClose, close, open, onExited, retain);
	const directory = dir === null ? "this directory" : directoryName(dir.id, homeDir);
	const named = conv.type === "room" ? roomCalled(conv.id, conv.held) : conv.id;
	return (
		<dialog ref={dialog} className="modal" aria-labelledby="convcardTitle">
			{
				/* The card wears the directory's mark the way the topbar stripe
				    does: arriving from a coloured conversation to find nothing
				    coloured makes a reader check they opened the right one. */
			}
			<div className="modal-card card-plane conversation-card" data-dir={mark}>
				<div className="modal-body">
					<ModalHead
						titleId="convcardTitle"
						title={
							<>
								<ConvMark conv={conv} online={online} away={away} />
								{conv.id}
							</>
						}
						closeId="convcardClose"
						closeRef={close}
						onClose={requestClose}
					/>
					{conv.type === "room"
						? (
							<RoomCardBody
								key={`${conv.key}:${request}`}
								conv={conv}
								dir={dir}
								directory={directory}
								named={named}
								standing={standing}
								follows={follows}
								asking={asking}
								setAsking={setAsking}
								askingLeave={askingLeave}
								initialPane={initialPane}
								administeredBridge={administeredBridge}
								canInteract={canInteract}
							/>
						)
						: (
							<>
								<ConvFacts conv={conv} dir={dir} directory={directory} />
								{canInteract && conv.type === "dm" && (
									<DmArchiveHistory conv={conv} shares={archiveShares} />
								)}
								{canInteract && (
									<LeaveControls
										conv={conv}
										asking={asking}
										setAsking={setAsking}
										askingLeave={askingLeave}
									/>
								)}
							</>
						)}
				</div>
			</div>
		</dialog>
	);
}
