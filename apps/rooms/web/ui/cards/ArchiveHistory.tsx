// Conversation-card archive share controls. Incoming offers draw on the DM
// that carried them. A room card names a member and hands a facet over that DM.

import { useState } from "react";
import { archiveHistoryTitle, archiveShareCopy, archiveShareWith } from "../../../lib/text/controls.ts";
import { archiveNeedsPeerAfter, archiveNeedsPeerLead, archiveNeedsPeerLink } from "../../../lib/text/settings.ts";
import {
	archiveDiscardAsk,
	archiveDiscardCommit,
	archiveDiscardKeep,
	archiveDiscardLabel,
	archiveDiscardSay,
	archiveDmLead,
	archiveDoorHint,
	archiveDoorHintOffered,
	archiveDoorOffered,
	archiveDoorOpen,
	archiveDoorWhat,
	archiveHand,
	archiveHanding,
	archiveLastingKept,
	archiveLastingKeptSaid,
	archiveLastingOnce,
	archiveLastingOnceDm,
	archiveLastingOnceRoom,
	archiveLastingTitle,
	archiveOfferedSaid,
	archivePeerHint,
	archivePeerHintNobody,
	archiveRead,
	archiveReading,
	archiveRoomLead,
	archiveSharedWith,
	archiveWhatLine,
	archiveWhatLineSaid,
	archiveWhatStanding,
	archiveWhatStandingSaid,
	archiveWhatTitle,
} from "../../../lib/text/archive.ts";
import type { Conv, RoomConv } from "../types.ts";
import type { ArchiveShareView } from "../archive_model.ts";
import { useArchiveShareBearer, useConversationMembers, useRoomsState } from "../hooks.ts";
import { useRoomsSession } from "../controller/session.ts";
import { useRoomsBrowser } from "../controller/browser.ts";
import { Button } from "../Button.tsx";
import { Submodal } from "../Submodal.tsx";
import { Icon } from "../icons.tsx";
import { useOpenModal } from "../modal.ts";
import { Confirm } from "../Confirm.tsx";
import { CopyField } from "../Copy.tsx";
import { Said } from "../Said.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import { actionRefusal } from "../error_text.ts";

/** The way in to handing an archive account over. The form behind it is a
 * name, two questions and an act, which is a card's worth of work rather than
 * a row's: the same reason attaching a session opens one from Settings. The
 * sentence here carries whatever is waiting, so an account somebody offered is
 * still noticed without opening anything. */
function ArchiveDoor(
	{ waiting, onOpen }: { waiting: number; onOpen: (from: HTMLElement) => void },
) {
	return (
		<>
			<h3 className="well-title overline" id="convcardArchiveTitle">{archiveHistoryTitle}</h3>
			<div className="group well" role="group" aria-labelledby="convcardArchiveTitle">
				<div className="launch">
					<span className="launch-mark" aria-hidden="true">
						<Icon name="file" size={18} />
					</span>
					<div className="launch-copy">
						<p className="launch-title">
							<span>{archiveDoorWhat}</span>
							{waiting > 0 && <span className="tag">{archiveDoorOffered(waiting)}</span>}
						</p>
						<p className="hint">{waiting > 0 ? archiveDoorHintOffered : archiveDoorHint}</p>
					</div>
					<Button
						id="convcardArchiveOpen"
						variant="quiet"
						onClick={(event) => onOpen(event.currentTarget)}
					>
						{archiveDoorOpen}
					</Button>
				</div>
			</div>
		</>
	);
}

function ArchiveOfferLink({ id }: { id: string }) {
	const uri = useArchiveShareBearer(id);
	return uri == null ? null : <CopyField id={`archiveShareLink-${id}`} text={uri} label={archiveShareCopy} />;
}
function IncomingShares({ shares }: { shares: readonly ArchiveShareView[] }) {
	const session = useRoomsSession();
	// Discarding drops a capability somebody handed over, and getting it back
	// is theirs to do rather than the reader's. Its two siblings on the room
	// card, the manager and the moderator, both ask before letting one go.
	const [discarding, setDiscarding] = useState<string | null>(null);
	/** Why a read did not happen, by the share it was asked of. The row already
	 * draws a failure the store reports. This is the one the reader's own press
	 * came back with, which had nowhere to go. */
	const [shareWhy, setShareWhy] = useState<Readonly<Record<string, string>>>({});
	const [reading, setReading] = useState<ReadonlySet<string>>(() => new Set());
	if (shares.length === 0) return null;
	return (
		<ul className="entries">
			{shares.map((offered) => (
				<li className="entry archive-share-offer" key={offered.id}>
					<div className="entry-head">
						<span className="entry-name">{offered.from}</span>
						<span className="entry-meta">
							{archiveOfferedSaid(offered.custody, offered.kind, offered.scopeConversation ?? null)}
						</span>
					</div>
					{offered.custody === "durable" && offered.status !== "dropping" && (
						<ArchiveOfferLink id={offered.id} />
					)}
					{offered.error !== "" && <Said kind="failure">{offered.error}</Said>}
					{(shareWhy[offered.id] ?? "") !== "" && <Said kind="failure">{shareWhy[offered.id]}</Said>}
					{discarding === offered.id
						? (
							<Confirm
								label={archiveDiscardLabel(offered.from)}
								say={archiveDiscardSay(offered.from)}
								keep={archiveDiscardKeep}
								commit={archiveDiscardCommit}
								onKeep={() => setDiscarding(null)}
								onCommit={() => {
									setDiscarding(null);
									session.dropArchiveShare(offered.id);
								}}
							/>
						)
						: (
							<div className="actions">
								<Button
									className="archive-share-drop"
									variant="quiet"
									busy={offered.status === "dropping"}
									disabled={reading.has(offered.id) || offered.status === "reading"}
									onClick={() => setDiscarding(offered.id)}
								>
									{archiveDiscardAsk}
								</Button>
								<Button
									className="archive-share-read"
									busy={reading.has(offered.id) || offered.status === "reading"}
									disabled={offered.status === "dropping"}
									busyLabel={archiveReading}
									onClick={() => {
										setShareWhy((prior) => ({ ...prior, [offered.id]: "" }));
										setReading((prior) => new Set([...prior, offered.id]));
										void session.readArchiveShare(offered.id).then((refused) => {
											// The wait was drawn and the refusal was dropped, so a
											// read that could not happen looked exactly like one
											// that finished.
											if (refused !== "") {
												setShareWhy((prior) => ({ ...prior, [offered.id]: refused }));
											}
										}).catch((error) => {
											setShareWhy((prior) => ({
												...prior,
												[offered.id]: refusalText(error),
											}));
										}).finally(() => {
											setReading((prior) => {
												const next = new Set(prior);
												next.delete(offered.id);
												return next;
											});
										});
									}}
								>
									{archiveRead}
								</Button>
							</div>
						)}
				</li>
			))}
		</ul>
	);
}

export function DmArchiveHistory(
	{ conv, shares }: { conv: Conv & { type: "dm" }; shares: readonly ArchiveShareView[] },
) {
	const session = useRoomsSession();
	const browser = useRoomsBrowser();
	const openModalFrom = useOpenModal();
	const archive = useRoomsState((state) => state.archiveTarget);
	const [open, setOpen] = useState(false);
	const [lasting, setLasting] = useState<"once" | "kept">("once");
	const [working, setWorking] = useState(false);
	const [shared, setShared] = useState(false);
	const [why, setWhy] = useState("");
	// The same closed answer as a room's, for the same reason: only an archive
	// peer can mint a link somebody else keeps.
	const canKeep = archive.kind === "peer" && archive.status === "connected";
	const keeping = canKeep && lasting === "kept";
	const hand = async () => {
		if (working) return;
		setWorking(true);
		setShared(false);
		setWhy("");
		try {
			const refused = await actionRefusal(() =>
				keeping ? session.offerDurableArchive(conv.key) : session.shareArchiveHistory(conv.key)
			);
			setWhy(refused);
			setShared(refused === "");
		} finally {
			setWorking(false);
		}
	};
	return (
		<>
			<ArchiveDoor waiting={shares.length} onOpen={(from) => openModalFrom(from, () => setOpen(true))} />
			<Submodal
				title={archiveHistoryTitle}
				titleId="convcardArchiveCardTitle"
				className="archive-history-modal"
				open={open}
				onClose={() => setOpen(false)}
			>
				<p className="lead">{archiveDmLead(conv.id)}</p>
				<div className="question">
					<p className="group-label" id="convcardArchiveDmLasting">{archiveLastingTitle}</p>
					<div className="choices" role="radiogroup" aria-labelledby="convcardArchiveDmLasting">
						<label className="choice">
							<input
								type="radio"
								name="convcardArchiveDmLasting"
								value="once"
								checked={!keeping}
								disabled={working}
								onChange={() => setLasting("once")}
							/>
							<span>
								<strong>{archiveLastingOnce}</strong>
								{archiveLastingOnceDm}
							</span>
						</label>
						<label className="choice">
							<input
								type="radio"
								name="convcardArchiveDmLasting"
								value="kept"
								checked={keeping}
								disabled={working || !canKeep}
								onChange={() => setLasting("kept")}
							/>
							<span>
								<strong>{archiveLastingKept}</strong>
								{canKeep ? archiveLastingKeptSaid : (
									<>
										{archiveNeedsPeerLead} {
											/* Settings will not open over this card (`settingsBlocked`
										    in App says why), so the card goes first. */
										}
										<Button
											variant="link"
											onClick={() => {
												browser.closeAboutConversation();
												browser.setSettingsTab("session");
												browser.openSettings();
											}}
										>
											{archiveNeedsPeerLink}
										</Button>
										{archiveNeedsPeerAfter}
									</>
								)}
							</span>
						</label>
					</div>
				</div>
				<div className="actions">
					<Button
						id="convcardShareArchive"
						busy={working}
						busyLabel={archiveHanding}
						disabled={working}
						onClick={() => void hand()}
					>
						{archiveHand}
					</Button>
				</div>
				{shared && <Said id="convcardArchiveSaid" kind="success">{archiveSharedWith(conv.id)}</Said>}
				{why !== "" && <Said id="convcardArchiveSaid" kind="failure">{why}</Said>}
				<IncomingShares shares={shares} />
			</Submodal>
		</>
	);
}

export function RoomArchiveHistory({ conv, you }: { conv: RoomConv; you: string }) {
	const session = useRoomsSession();
	const browser = useRoomsBrowser();
	const openModalFrom = useOpenModal();
	const roster = useConversationMembers(conv.key);
	const archive = useRoomsState((state) => state.archiveTarget);
	const [open, setOpen] = useState(false);
	const [peer, setPeer] = useState("");
	const [records, setRecords] = useState<"line" | "standing">("line");
	const [lasting, setLasting] = useState<"once" | "kept">("once");
	const [working, setWorking] = useState(false);
	const [shared, setShared] = useState("");
	const [why, setWhy] = useState("");
	// The account travels over a direct message, so the names worth suggesting
	// are the ones in this room that can receive one. Offering the whole roster
	// suggested people the send would refuse.
	const dmable = useRoomsState((state) => state.dirs.get(conv.dir)?.dmablePeers);
	const members = [...roster.keys()].filter((name) => name !== you && dmable?.has(name.toLowerCase()) === true);
	// A link somebody keeps is a publication the archive peer mints and can
	// take back on its own. The archive built into this browser has nobody to
	// mint one, so that answer is closed rather than offered and refused.
	const canKeep = archive.kind === "peer" && archive.status === "connected";
	const keeping = canKeep && lasting === "kept";
	const hand = async () => {
		if (working) return;
		setWorking(true);
		setShared("");
		setWhy("");
		try {
			const refused = await actionRefusal(() =>
				keeping
					? session.offerDurableArchive(conv.key, peer, records)
					: session.shareArchiveHistory(conv.key, peer, records)
			);
			setWhy(refused);
			setShared(refused === "" ? peer.trim() : "");
		} finally {
			setWorking(false);
		}
	};
	return (
		<>
			<ArchiveDoor waiting={0} onOpen={(from) => openModalFrom(from, () => setOpen(true))} />
			<Submodal
				title={archiveHistoryTitle}
				titleId="convcardRoomArchiveCardTitle"
				className="archive-history-modal"
				open={open}
				onClose={() => setOpen(false)}
			>
				<p className="lead">{archiveRoomLead}</p>
				<Field
					id="convcardArchivePeer"
					label={archiveShareWith}
					hint={members.length === 0 ? archivePeerHintNobody : archivePeerHint}
				>
					{(wiring) => (
						<input
							id={wiring.id}
							className="field"
							{...identifierField}
							list="convcardArchivePeerList"
							placeholder={members[0] ?? "alice"}
							value={peer}
							onChange={(event) => setPeer(event.currentTarget.value)}
							aria-describedby={wiring.describedBy}
							aria-invalid={wiring.invalid}
						/>
					)}
				</Field>
				<datalist id="convcardArchivePeerList">
					{members.map((name) => <option key={name} value={name} />)}
				</datalist>
				<div className="question">
					<p className="group-label" id="convcardArchiveWhat">{archiveWhatTitle}</p>
					<div className="choices" role="radiogroup" aria-labelledby="convcardArchiveWhat">
						<label className="choice">
							<input
								type="radio"
								name="convcardArchiveWhat"
								value="line"
								checked={records === "line"}
								disabled={working}
								onChange={() => setRecords("line")}
							/>
							<span>
								<strong>{archiveWhatLine}</strong>
								{archiveWhatLineSaid}
							</span>
						</label>
						<label className="choice">
							<input
								type="radio"
								name="convcardArchiveWhat"
								value="standing"
								checked={records === "standing"}
								disabled={working}
								onChange={() => setRecords("standing")}
							/>
							<span>
								<strong>{archiveWhatStanding}</strong>
								{archiveWhatStandingSaid}
							</span>
						</label>
					</div>
				</div>
				<div className="question">
					<p className="group-label" id="convcardArchiveLasting">{archiveLastingTitle}</p>
					<div className="choices" role="radiogroup" aria-labelledby="convcardArchiveLasting">
						<label className="choice">
							<input
								type="radio"
								name="convcardArchiveLasting"
								value="once"
								checked={!keeping}
								disabled={working}
								onChange={() => setLasting("once")}
							/>
							<span>
								<strong>{archiveLastingOnce}</strong>
								{archiveLastingOnceRoom}
							</span>
						</label>
						<label className="choice">
							<input
								type="radio"
								name="convcardArchiveLasting"
								value="kept"
								checked={keeping}
								disabled={working || !canKeep}
								onChange={() => setLasting("kept")}
							/>
							<span>
								<strong>{archiveLastingKept}</strong>
								{canKeep ? archiveLastingKeptSaid : (
									<>
										{archiveNeedsPeerLead} {
											/* Settings will not open over this card (`settingsBlocked`
										    in App says why), so the card goes first. */
										}
										<Button
											variant="link"
											onClick={() => {
												browser.closeAboutConversation();
												browser.setSettingsTab("session");
												browser.openSettings();
											}}
										>
											{archiveNeedsPeerLink}
										</Button>
										{archiveNeedsPeerAfter}
									</>
								)}
							</span>
						</label>
					</div>
				</div>
				<div className="actions">
					<Button
						id="convcardShareArchive"
						busy={working}
						disabled={working || peer.trim() === ""}
						onClick={() => void hand()}
					>
						{archiveHand}
					</Button>
				</div>
				{shared !== "" && why === "" && (
					<Said id="convcardArchiveSaid" kind="success">{archiveSharedWith(shared)}</Said>
				)}
				{why !== "" && <Said id="convcardArchiveSaid" kind="failure">{why}</Said>}
			</Submodal>
		</>
	);
}
