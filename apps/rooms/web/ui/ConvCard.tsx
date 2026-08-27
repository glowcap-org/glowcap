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
import type { Conv, DirId, DirView, IrcBridgeRow, RoomConv } from "./types.ts";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsSession } from "./controller/session.ts";
import { useHeldModal, useModalDialog } from "./modal.ts";
import { ModalHead } from "./ModalHead.tsx";
import { Confirm } from "./Confirm.tsx";
import { Said } from "./Said.tsx";
import { Button } from "./Button.tsx";
import { Icon } from "./icons.tsx";
import { Avatar, PresenceAvatar } from "./Avatar.tsx";
import { StandingMenu } from "./Standing.tsx";
import { ConvFacts } from "./ConvFacts.tsx";
import { RoomCapabilities, RoomModeration } from "./RoomModeration.tsx";
import { RoomIrcIdentity } from "./RoomIrcIdentity.tsx";
import { directoryName, roomCalled } from "./text.ts";
import { type TabFace, Tabs } from "./Tabs.tsx";
import type { ArchiveShareView } from "./archive_model.ts";
import { bridgedOrigin } from "./store/dirs.ts";

export function ConvCard(
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
		away,
		open,
		initialPane,
		request,
		administeredBridge,
		retain = false,
		onLayer,
	}: {
		canInteract: boolean;
		conv: Conv | null;
		archiveShares: readonly ArchiveShareView[];
		dir: DirView | null;
		homeDir: DirId | null;
		mark: string | undefined;
		standing: string;
		follows: string;
		online: boolean;
		away: string | null;
		open: boolean;
		initialPane: "about" | "irc";
		request: number;
		administeredBridge: IrcBridgeRow | null;
		retain?: boolean;
		onLayer: (held: boolean) => void;
	},
) {
	type View = {
		conv: Conv;
		archiveShares: readonly ArchiveShareView[];
		dir: DirView | null;
		homeDir: DirId | null;
		mark: string | undefined;
		standing: string;
		follows: string;
		online: boolean;
		away: string | null;
		initialPane: "about" | "irc";
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
			away,
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
			away,
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
	{ conv, dir, directory, named, standing, follows, asking, setAsking, initialPane, administeredBridge, canInteract }:
		{
			conv: RoomConv;
			dir: DirView | null;
			directory: string;
			named: string;
			standing: string;
			follows: string;
			asking: boolean;
			setAsking: (asking: boolean) => void;
			initialPane: "about" | "irc";
			administeredBridge: IrcBridgeRow | null;
			canInteract: boolean;
		},
) {
	const session = useRoomsSession();
	const held = conv.grants.has("steward");
	const roomAvailable = conv.membership === "joined";
	const canModerate = (held && roomAvailable) || administeredBridge !== null;
	const ownIrc = dir === null ? undefined : conv.members.get(dir.nick)?.irc;
	const bridgeOrigin = bridgedOrigin(dir ?? undefined, conv.id);
	const tabs = ROOM_TABS.filter((tab) =>
		(tab.id === "about" || canInteract) &&
		(tab.id !== "irc" || ownIrc !== undefined) && (tab.id !== "moderation" || canModerate)
	);
	const [chosen, setChosen] = useState<RoomPane>(initialPane === "irc" && ownIrc !== undefined ? "irc" : "about");
	const pane = !canInteract
		? "about"
		: chosen === "moderation" && !canModerate
		? "capabilities"
		: chosen === "irc" && ownIrc === undefined
		? "about"
		: chosen;
	return (
		<>
			<Tabs
				id="convcardTabs"
				tabs={tabs}
				selected={pane}
				labelledBy="convcardTitle"
				onSelect={setChosen}
			/>
			{pane === "about" && (
				<div id="convcardAboutPanel" role="tabpanel" aria-labelledby="convcardAboutTab">
					<ConvFacts conv={conv} dir={dir} directory={directory} bridgeOrigin={bridgeOrigin} />
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
								onSay={(said) => session.setRoomStanding(conv.key, said)}
								disabled={!canInteract}
							/>
						</div>
					</div>
					{canInteract && <LeaveControls conv={conv} asking={asking} setAsking={setAsking} />}
				</div>
			)}
			{pane === "capabilities" && (
				<div id="convcardCapabilitiesPanel" role="tabpanel" aria-labelledby="convcardCapabilitiesTab">
					<RoomCapabilities conv={conv} available={roomAvailable} />
				</div>
			)}
			{pane === "irc" && ownIrc !== undefined && (
				<div id="convcardIrcPanel" role="tabpanel" aria-labelledby="convcardIrcTab">
					<RoomIrcIdentity
						conv={conv}
						seat={ownIrc}
						connected={roomAvailable}
						bridgeOrigin={bridgeOrigin}
					/>
				</div>
			)}
			{pane === "moderation" && canModerate && (
				<div id="convcardModerationPanel" role="tabpanel" aria-labelledby="convcardModerationTab">
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
	{ conv, asking, setAsking }: { conv: Conv; asking: boolean; setAsking: (asking: boolean) => void },
) {
	const session = useRoomsSession();
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
				onKeep={() => setAsking(false)}
				onCommit={() => session.endConv()}
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

function DmArchiveHistory(
	{ conv, shares }: { conv: Conv & { type: "dm" }; shares: readonly ArchiveShareView[] },
) {
	const session = useRoomsSession();
	const [sharing, setSharing] = useState(false);
	const [shared, setShared] = useState(false);
	const [why, setWhy] = useState("");
	const share = async () => {
		setSharing(true);
		setShared(false);
		setWhy("");
		const refused = await session.shareArchiveHistory(conv.key);
		setWhy(refused);
		setShared(refused === "");
		setSharing(false);
	};
	return (
		<>
			<h3 className="well-title overline" id="convcardArchiveTitle">Archive history</h3>
			<div className="group well" role="group" aria-labelledby="convcardArchiveTitle">
				<p className="hint">
					Share a read-only account scoped to this direct conversation from the archive selected in Settings.
					It does not grant access to any other conversation.
				</p>
				<div className="actions">
					<Button id="convcardShareArchive" busy={sharing} onClick={() => void share()}>
						{sharing ? "Sharing…" : "Share history"}
					</Button>
				</div>
				{shared && <Said id="convcardArchiveSaid" kind="success">{`Shared with ${conv.id}.`}</Said>}
				{why !== "" && <Said id="convcardArchiveSaid" kind="failure">{why}</Said>}
				{shares.length > 0 && (
					<ul className="entries">
						{shares.map((offered) => (
							<li className="entry archive-share-offer" key={offered.id}>
								<div className="entry-head">
									<span className="entry-name">{offered.from}</span>
									<span className="entry-meta">offered a read-only account</span>
								</div>
								{offered.error !== "" && <Said kind="failure">{offered.error}</Said>}
								<div className="actions">
									<Button
										className="archive-share-drop"
										variant="quiet"
										disabled={offered.status === "reading"}
										onClick={() => session.dropArchiveShare(offered.id)}
									>
										Give back
									</Button>
									<Button
										className="archive-share-read"
										busy={offered.status === "reading"}
										onClick={() => void session.readArchiveShare(offered.id)}
									>
										{offered.status === "reading" ? "Reading…" : "Read shared history"}
									</Button>
								</div>
							</li>
						))}
					</ul>
				)}
			</div>
		</>
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
	}: {
		open: boolean;
		retain: boolean;
		onExited: () => void;
		conv: Conv;
		archiveShares: readonly ArchiveShareView[];
		dir: DirView | null;
		homeDir: DirId | null;
		mark: string | undefined;
		standing: string;
		follows: string;
		online: boolean;
		away: string | null;
		initialPane: "about" | "irc";
		request: number;
		administeredBridge: IrcBridgeRow | null;
		canInteract: boolean;
	},
) {
	const browser = useRoomsBrowser();
	const close = useRef<HTMLButtonElement>(null);
	const dialog = useRef<HTMLDialogElement>(null);
	const [asking, setAsking] = useState(false);
	useEffect(() => {
		if (!open) setAsking(false);
	}, [open]);
	useModalDialog(dialog, () => browser.closeAboutConversation(), close, open, onExited, retain);
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
					onClose={() => browser.closeAboutConversation()}
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
							initialPane={initialPane}
							administeredBridge={administeredBridge}
							canInteract={canInteract}
						/>
					)
					: (
						<>
							<ConvFacts conv={conv} dir={dir} directory={directory} />
							{canInteract && <DmArchiveHistory conv={conv} shares={archiveShares} />}
							{canInteract && <LeaveControls conv={conv} asking={asking} setAsking={setAsking} />}
						</>
					)}
			</div>
		</dialog>
	);
}
