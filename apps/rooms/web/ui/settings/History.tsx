// Where this session's messages are kept.
//
// One switch answers whether anything is kept at all and one sentence under it
// says where. Choosing the archive capability lives under Holdings; policy and
// authority therefore do not masquerade as one setting.
//
// The sentence is written for the state the reader is in, including the state
// where nothing is being kept: a switch that is off under a sentence about
// where messages are kept is a page describing someone else's session.

import { useState } from "react";
import type { ArchiveTargetView } from "../archive_model.ts";
import { Button } from "../Button.tsx";
import { Checkbox } from "../Checkbox.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { locatorRefusal } from "../error_text.ts";
import { useOpenModal } from "../modal.ts";
import { Said } from "../Said.tsx";
import { Switch } from "../Switch.tsx";
import { useRoomsSession } from "../controller/session.ts";
import { Submodal } from "../Submodal.tsx";
import { useChangeGroup, useCommitments, useCommitSettling } from "../commitment.tsx";
import type { ArchiveOwner } from "../archive_model.ts";

/** Where history is written now, said once under the switch. */
function historySaid(
	keepHistory: boolean,
	archiveTarget: ArchiveTargetView,
): string {
	const sharedSession = archiveTarget.owner === "session";
	if (!keepHistory) {
		return sharedSession
			? "Nothing is being kept. Room and direct messages arrive in the windows that are open and are not saved for later."
			: "Nothing is being kept. Room and direct messages arrive in this window and are not saved for later.";
	}
	if (archiveTarget.kind === "owned") {
		return sharedSession
			? "New room and direct messages are kept by this durable Rooms session. Turning this off stops new writes."
			: "New room and direct messages are kept in this browser. Turning this off erases this browser's message archive.";
	}
	if (archiveTarget.status === "connected") {
		return `New room and direct messages are kept by ${archiveTarget.label}. Turning this off stops new writes. It cannot erase the session.`;
	}
	return `The selected ${archiveTarget.label} is unavailable. New messages are not silently copied into this browser.`;
}

export function HistorySettings(
	{ keepHistory, archiveTarget }: {
		keepHistory: boolean;
		archiveTarget: ArchiveTargetView;
	},
) {
	const session = useRoomsSession();
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	const toggle = async () => {
		setBusy(true);
		setWhy("");
		try {
			await session.setKeepHistory(!keepHistory);
		} catch (error) {
			setWhy(error instanceof Error ? error.message : String(error));
		} finally {
			setBusy(false);
		}
	};

	return (
		<>
			<h3 className="well-title overline" id="historyLegend">Message history</h3>
			<div className="group well" role="group" aria-labelledby="historyLegend">
				<div className="switch-row">
					<p className="group-label" id="keepHistoryLegend">Keep message history</p>
					<Switch
						id="keepHistoryToggle"
						checked={keepHistory}
						label="Keep message history"
						busy={busy}
						aria-labelledby="keepHistoryLegend"
						onClick={() => void toggle()}
					/>
				</div>
				<p className="hint" id="historyWhere">{historySaid(keepHistory, archiveTarget)}</p>
				{why !== "" && <Said kind="failure">{why}</Said>}
			</div>
		</>
	);
}

export function ArchiveHolding({ archiveTarget }: { archiveTarget: ArchiveTargetView }) {
	const openModalFrom = useOpenModal();
	const session = useRoomsSession();
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	const [peerOpen, setPeerOpen] = useState(false);
	const onPeer = archiveTarget.kind === "peer";
	const act = async (request: () => Promise<unknown>) => {
		setBusy(true);
		setWhy("");
		try {
			const answer = await request();
			if (typeof answer === "string" && answer !== "") setWhy(answer);
		} catch (error) {
			setWhy(error instanceof Error ? error.message : String(error));
		} finally {
			setBusy(false);
		}
	};
	return (
		<>
			<h3 className="well-title overline" id="archiveHoldingLegend">Archive capability</h3>
			<div className="group well" role="group" aria-labelledby="archiveHoldingLegend">
				<div className="entry-head">
					<span className="entry-name">
						{onPeer
							? archiveTarget.label
							: archiveTarget.owner === "session"
							? "Built-in session archive"
							: "Built-in browser archive"}
					</span>
					{onPeer && <span className="tag">{archiveTarget.remembered ? "Saved" : "Live"}</span>}
				</div>
				<p className="hint">
					{onPeer
						? archiveTarget.status === "unavailable"
							? "The selected archive peer is unavailable."
							: archiveTarget.remembered
							? "Connected. Its saved bearer lets this session reconnect."
							: "Connected for this session only."
						: archiveTarget.owner === "session"
						? "Keeps this shared session's message history."
						: "Keeps message history in this browser."}
				</p>
				<div className="actions" data-stack-narrow>
					{onPeer && (
						<Button
							type="button"
							variant="quiet"
							busy={busy}
							disabled={busy}
							onClick={() => void act(() => session.useOwnedArchive())}
						>
							{archiveTarget.owner === "session" ? "Use session archive" : "Use this browser"}
						</Button>
					)}
					{onPeer && archiveTarget.status === "unavailable" && (
						<Button
							type="button"
							variant="quiet"
							busy={busy}
							disabled={busy}
							onClick={() => void act(() => session.retryArchivePeer())}
						>
							Reconnect
						</Button>
					)}
					<Button
						id="archivePeerOpen"
						type="button"
						variant="quiet"
						onClick={(event) => openModalFrom(event.currentTarget, () => setPeerOpen(true))}
					>
						{onPeer ? "Change archive peer…" : "Use an archive peer…"}
					</Button>
				</div>
				{why !== "" && <Said kind="failure">{why}</Said>}
			</div>
			<ArchivePeerModal
				open={peerOpen}
				owner={archiveTarget.owner}
				onClose={() => setPeerOpen(false)}
			/>
		</>
	);
}

function ArchivePeerModal(
	{ open, owner, onClose }: { open: boolean; owner: ArchiveOwner; onClose(): void },
) {
	const session = useRoomsSession();
	const commitments = useCommitments();
	const [link, setLink] = useState("");
	const [remember, setRemember] = useState(false);
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	const [taken, setTaken] = useState("");
	const commit = useCommitSettling();
	useChangeGroup("settings-archive-peer", {
		dirty: link !== "" || remember,
		discard: () => {
			if (busy) throw new Error("Wait for the archive peer change to finish.");
			setLink("");
			setRemember(false);
			setWhy("");
			setTaken("");
		},
		settling: commit.current,
	});
	const take = async () => {
		commit.begin();
		setBusy(true);
		setWhy("");
		setTaken("");
		try {
			const refused = locatorRefusal(await session.takeArchivePeer(link, remember), "archive peer link");
			setWhy(refused);
			if (refused === "") {
				setLink("");
				setRemember(false);
				setTaken("This archive peer keeps new history now.");
			}
		} finally {
			setBusy(false);
			commit.finish();
		}
	};
	return (
		<Submodal
			title="Archive peer"
			titleId="archivePeerTitle"
			className="archive-peer-modal"
			open={open}
			onClose={() => commitments.request(onClose, { only: ["settings-archive-peer"] })}
		>
			<p className="lead">
				A separate pancake peer keeps your history. Rooms and message recipients never receive it.
			</p>
			<form
				id="archivePeerForm"
				className="group well"
				onSubmit={(event) => {
					event.preventDefault();
					void take();
				}}
			>
				<Field
					id="archivePeerLink"
					label="Archive peer capability"
					hint="Bearer authority to read and write the archive. A new peer keeps future messages. It does not copy old history."
					said={why}
				>
					{(wiring) => (
						<input
							id={wiring.id}
							className="field"
							type="password"
							{...identifierField}
							aria-describedby={wiring.describedBy}
							aria-invalid={wiring.invalid}
							value={link}
							disabled={busy}
							onChange={(event) => {
								setLink(event.currentTarget.value);
								setWhy("");
								setTaken("");
							}}
							placeholder="ocapn://…/s/…"
						/>
					)}
				</Field>
				{owner === "session"
					? <p className="hint">The shared session retains this for every attached view.</p>
					: (
						<label className="check-row">
							<Checkbox
								id="rememberArchivePeer"
								checked={remember}
								onChange={(event) => setRemember(event.currentTarget.checked)}
							/>
							<span>
								<strong>Remember in this browser</strong>
								Stores its bearer and reconnects after reload. Clear means this page only.
							</span>
						</label>
					)}
				<div className="actions" data-fill>
					<Button type="submit" size="large" busy={busy} disabled={busy || link.trim() === ""}>
						Use archive peer
					</Button>
				</div>
				{taken !== "" && <Said id="archivePeerTaken" kind="success">{taken}</Said>}
			</form>
		</Submodal>
	);
}
