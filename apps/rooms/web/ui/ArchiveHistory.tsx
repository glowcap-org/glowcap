// Conversation-card archive share controls. Incoming offers draw on the DM
// that carried them; a room card names a member and hands a facet over that DM.

import { useState } from "react";
import type { Conv, RoomConv } from "./types.ts";
import type { ArchiveShareView } from "./archive_model.ts";
import { useConversationMembers, useRoomsState } from "./hooks.ts";
import { useRoomsSession } from "./controller/session.ts";
import { Button } from "./Button.tsx";
import { Submodal } from "./Submodal.tsx";
import { Icon } from "./icons.tsx";
import { useOpenModal } from "./modal.ts";
import { Confirm } from "./Confirm.tsx";
import { CopyField } from "./Copy.tsx";
import { Said } from "./Said.tsx";
import { Field } from "./Field.tsx";
import { identifierField } from "./field.ts";

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
			<h3 className="well-title overline" id="convcardArchiveTitle">Archive history</h3>
			<div className="group well" role="group" aria-labelledby="convcardArchiveTitle">
				<div className="launch">
					<span className="launch-mark" aria-hidden="true">
						<Icon name="file" size={18} />
					</span>
					<div className="launch-copy">
						<p className="launch-title">
							<span>What you kept</span>
							{waiting > 0 && (
								<span className="tag">{waiting === 1 ? "1 offered" : `${waiting} offered`}</span>
							)}
						</p>
						<p className="hint">
							{waiting > 0
								? "Somebody has offered you a read-only account, and you can hand one over too."
								: "Hand one member a read-only copy of what your archive kept."}
						</p>
					</div>
					<Button
						id="convcardArchiveOpen"
						variant="quiet"
						onClick={(event) => onOpen(event.currentTarget)}
					>
						Archive history…
					</Button>
				</div>
			</div>
		</>
	);
}

function IncomingShares({ shares }: { shares: readonly ArchiveShareView[] }) {
	const session = useRoomsSession();
	// Discarding drops a capability somebody handed over, and getting it back
	// is theirs to do rather than the reader's. Its two siblings on the room
	// card, the manager and the moderator, both ask before letting one go.
	const [discarding, setDiscarding] = useState<string | null>(null);
	/** Why a read did not happen, by the share it was asked of. The row already
	 * draws a failure the store reports; this is the one the reader's own press
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
							{offered.custody === "durable"
								? offered.kind === "standing"
									? "offered a durable standing"
									: offered.kind === "room"
									? `offered a durable account of ${offered.scopeConversation ?? "a room"}`
									: "offered a durable account"
								: offered.kind === "standing"
								? "offered a read-only standing"
								: offered.kind === "room"
								? `offered a read-only account of ${offered.scopeConversation ?? "a room"}`
								: "offered a read-only account"}
						</span>
					</div>
					{offered.custody === "durable" && offered.sturdyref !== "" && (
						<CopyField
							id={`archiveShareLink-${offered.id}`}
							text={offered.sturdyref}
							label="Copy the durable archive share"
						/>
					)}
					{offered.error !== "" && <Said kind="failure">{offered.error}</Said>}
					{(shareWhy[offered.id] ?? "") !== "" && <Said kind="failure">{shareWhy[offered.id]}</Said>}
					{discarding === offered.id
						? (
							<Confirm
								label={`Discard the account ${offered.from} offered`}
								say={`This lets go of what ${offered.from} handed over. Offering it again is theirs to do.`}
								keep="Keep it"
								commit="Discard"
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
									disabled={reading.has(offered.id)}
									onClick={() => setDiscarding(offered.id)}
								>
									Discard…
								</Button>
								<Button
									className="archive-share-read"
									busy={reading.has(offered.id)}
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
												[offered.id]: error instanceof Error ? error.message : String(error),
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
									{reading.has(offered.id) ? "Reading…" : "Read shared history"}
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
		const refused = keeping
			? await session.offerDurableArchive(conv.key)
			: await session.shareArchiveHistory(conv.key);
		setWhy(refused);
		setShared(refused === "");
		setWorking(false);
	};
	return (
		<>
			<ArchiveDoor waiting={shares.length} onOpen={(from) => openModalFrom(from, () => setOpen(true))} />
			<Submodal
				title="Archive history"
				titleId="convcardArchiveCardTitle"
				className="archive-history-modal"
				open={open}
				onClose={() => setOpen(false)}
			>
				<p className="lead">
					Hand {conv.id}{" "}
					a read-only copy of what your archive kept of this conversation. It reaches nothing else you have.
				</p>
				<div className="question">
					<p className="group-label" id="convcardArchiveDmLasting">How long they have it</p>
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
								<strong>This once</strong>
								They read it over this conversation, and it goes when that closes.
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
								<strong>A link they keep</strong>
								{canKeep
									? "They can come back to it later, and you can take it back at any time."
									: "Needs an archive peer to hold it. The archive built into this browser has nobody to mint one. Settings is where you choose a peer."}
							</span>
						</label>
					</div>
				</div>
				<div className="actions">
					<Button id="convcardShareArchive" busy={working} disabled={working} onClick={() => void hand()}>
						{working ? "Handing over…" : "Hand it over"}
					</Button>
				</div>
				{shared && <Said id="convcardArchiveSaid" kind="success">{`Shared with ${conv.id}.`}</Said>}
				{why !== "" && <Said id="convcardArchiveSaid" kind="failure">{why}</Said>}
				<IncomingShares shares={shares} />
			</Submodal>
		</>
	);
}

export function RoomArchiveHistory({ conv, you }: { conv: RoomConv; you: string }) {
	const session = useRoomsSession();
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
		const refused = keeping
			? await session.offerDurableArchive(conv.key, peer, records)
			: await session.shareArchiveHistory(conv.key, peer, records);
		setWhy(refused);
		setShared(refused === "" ? peer.trim() : "");
		setWorking(false);
	};
	return (
		<>
			<ArchiveDoor waiting={0} onOpen={(from) => openModalFrom(from, () => setOpen(true))} />
			<Submodal
				title="Archive history"
				titleId="convcardRoomArchiveCardTitle"
				className="archive-history-modal"
				open={open}
				onClose={() => setOpen(false)}
			>
				<p className="lead">
					A room keeps no past of its own. What you have of this one is yours, and you can hand a read-only
					copy of it to one member over a direct line. It does not put them in the room.
				</p>
				<Field
					id="convcardArchivePeer"
					label="Share with"
					hint={members.length === 0
						? "Nobody in this room can receive one yet. It travels over a direct message, and that needs a member who has registered for them here."
						: "A member's nickname. It travels over a direct message, so it goes to one person and reaches nothing else of yours."}
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
					<p className="group-label" id="convcardArchiveWhat">What to hand over</p>
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
								<strong>What was said here</strong>
								The messages from this room that your archive kept.
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
								<strong>Where you stood</strong>
								When you were here and when you were away, and nothing that was said.
							</span>
						</label>
					</div>
				</div>
				<div className="question">
					<p className="group-label" id="convcardArchiveLasting">How long they have it</p>
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
								<strong>This once</strong>
								They read it over the line you hand it on, and it goes when that closes.
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
								<strong>A link they keep</strong>
								{canKeep
									? "They can come back to it later, and you can take it back at any time."
									: "Needs an archive peer to hold it. The archive built into this browser has nobody to mint one. Settings is where you choose a peer."}
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
						{working ? "Handing over…" : "Hand it over"}
					</Button>
				</div>
				{shared !== "" && why === "" && (
					<Said id="convcardArchiveSaid" kind="success">{`Shared with ${shared}.`}</Said>
				)}
				{why !== "" && <Said id="convcardArchiveSaid" kind="failure">{why}</Said>}
			</Submodal>
		</>
	);
}
