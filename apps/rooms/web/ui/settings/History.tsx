// Where this session's messages are kept.
//
// One switch answers whether anything is kept at all and one sentence under it
// says where. Choosing the archive capability lives under Holdings. Policy and
// authority therefore do not masquerade as one setting.
//
// The sentence is written for the state the reader is in, including the state
// where nothing is being kept: a switch that is off under a sentence about
// where messages are kept is a page describing someone else's session.

import { useState } from "react";
import {
	historyArchivePeerLabel,
	historyArchivePeerTitle,
	historyBuiltInSession,
	historyKeepLabel,
	historyOffSession,
	historyOnSession,
	historyPeerDurable,
	historyPeerLead,
	historyPeerReconnect,
	historyPeerSaved,
	historyPeerUnavailable,
} from "../../../lib/text/settings.ts";
import {
	historyArchiveTitle,
	historyChangePeerAsk,
	historyKeptBy,
	historyOwnedSession,
	historyPeerCommit,
	historyPeerModalLead,
	historyPeerSessionRetains,
	historyPeerTaken,
	historyPeerUnavailableSaid,
	historyTitle,
	historyUsePeerAsk,
	historyUseSessionArchive,
} from "../../../lib/text/session_settings.ts";
import type { ArchiveTargetView } from "../archive_model.ts";
import { Button } from "../Button.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { actionRefusal, locatorRefusal } from "../error_text.ts";
import { useOpenModal } from "../modal.ts";
import { Said } from "../Said.tsx";
import { Switch } from "../Switch.tsx";
import { useRoomsSession } from "../controller/session.ts";
import { Submodal } from "../Submodal.tsx";
import { useChangeGroup, useCommitments, useCommitSettling } from "../commitment.tsx";
import { refusalText } from "../../../lib/text/failure.ts";
import { sturdyrefPlaceholder } from "../../../lib/text/controls.ts";

/** Where history is written now, said once under the switch. */
function historySaid(
	keepHistory: boolean,
	archiveTarget: ArchiveTargetView,
): string {
	if (!keepHistory) {
		return historyOffSession;
	}
	if (archiveTarget.kind === "owned") {
		return historyOnSession;
	}
	if (archiveTarget.status === "connected") {
		return historyKeptBy(archiveTarget.label);
	}
	return historyPeerUnavailableSaid(archiveTarget.label);
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
			setWhy(refusalText(error));
		} finally {
			setBusy(false);
		}
	};

	return (
		<>
			<h3 className="well-title overline" id="historyLegend">{historyTitle}</h3>
			<div className="group well" role="group" aria-labelledby="historyLegend">
				{why !== "" && <Said kind="failure">{why}</Said>}
				<div className="switch-row">
					<p className="group-label" id="keepHistoryLegend">{historyKeepLabel}</p>
					<Switch
						id="keepHistoryToggle"
						checked={keepHistory}
						label={historyKeepLabel}
						busy={busy}
						aria-labelledby="keepHistoryLegend"
						onClick={() => void toggle()}
					/>
				</div>
				<p className="hint" id="historyWhere">{historySaid(keepHistory, archiveTarget)}</p>
			</div>
		</>
	);
}

export function ArchiveHolding({ archiveTarget }: { archiveTarget: ArchiveTargetView }) {
	const openModalFrom = useOpenModal();
	const session = useRoomsSession();
	const [busy, setBusy] = useState<"own" | "reconnect" | null>(null);
	const [why, setWhy] = useState("");
	const [peerOpen, setPeerOpen] = useState(false);
	const onPeer = archiveTarget.kind === "peer";
	const act = async (which: "own" | "reconnect", request: () => Promise<unknown>) => {
		if (busy !== null) return;
		setBusy(which);
		setWhy("");
		try {
			const answer = await request();
			if (typeof answer === "string" && answer !== "") setWhy(answer);
		} catch (error) {
			setWhy(refusalText(error));
		} finally {
			setBusy(null);
		}
	};
	return (
		<>
			<h3 className="well-title overline" id="archiveHoldingLegend">{historyArchiveTitle}</h3>
			<div className="group well" role="group" aria-labelledby="archiveHoldingLegend">
				<div className="entry-head">
					<span className="entry-name">
						{onPeer ? archiveTarget.label : historyBuiltInSession}
					</span>
					{onPeer && <span className="tag">{historyPeerSaved}</span>}
					{onPeer && archiveTarget.status === "unavailable" && (
						<div className="actions">
							<Button
								type="button"
								variant="quiet"
								busy={busy === "reconnect"}
								disabled={busy !== null}
								onClick={() => void act("reconnect", () => session.retryArchivePeer())}
							>
								{historyPeerReconnect}
							</Button>
						</div>
					)}
				</div>
				<p className="hint">
					{onPeer
						? archiveTarget.status === "unavailable" ? historyPeerUnavailable : historyPeerDurable
						: historyOwnedSession}
				</p>
				<div className="actions">
					{onPeer && (
						<Button
							type="button"
							variant="quiet"
							busy={busy === "own"}
							disabled={busy !== null}
							onClick={() => void act("own", () => session.useOwnedArchive())}
						>
							{historyUseSessionArchive}
						</Button>
					)}
					<Button
						id="archivePeerOpen"
						type="button"
						variant="quiet"
						disabled={busy !== null}
						onClick={(event) => openModalFrom(event.currentTarget, () => setPeerOpen(true))}
					>
						{onPeer ? historyChangePeerAsk : historyUsePeerAsk}
					</Button>
				</div>
				{why !== "" && <Said kind="failure">{why}</Said>}
			</div>
			<ArchivePeerModal
				open={peerOpen}
				onClose={() => setPeerOpen(false)}
			/>
		</>
	);
}

function ArchivePeerModal(
	{ open, onClose }: { open: boolean; onClose(): void },
) {
	const session = useRoomsSession();
	const commitments = useCommitments();
	const [link, setLink] = useState("");
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	const [taken, setTaken] = useState("");
	const commit = useCommitSettling();
	useChangeGroup("settings-archive-peer", {
		dirty: link !== "",
		discard: () => {
			if (busy) throw new Error("Wait for the archive peer change to finish.");
			setLink("");
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
			const refused = locatorRefusal(
				await actionRefusal(() => session.takeArchivePeer(link)),
				"archive peer link",
			);
			setWhy(refused);
			if (refused === "") {
				setLink("");
				setTaken(historyPeerTaken);
			}
		} finally {
			setBusy(false);
			commit.finish();
		}
	};
	return (
		<Submodal
			title={historyArchivePeerTitle}
			titleId="archivePeerTitle"
			className="archive-peer-modal"
			open={open}
			onClose={() => commitments.request(onClose, { only: ["settings-archive-peer"] })}
		>
			<p className="lead">{historyPeerModalLead}</p>
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
					label={historyArchivePeerLabel}
					hint={historyPeerLead}
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
							placeholder={sturdyrefPlaceholder}
						/>
					)}
				</Field>
				<p className="hint">{historyPeerSessionRetains}</p>
				<div className="actions" data-fill>
					<Button type="submit" size="large" busy={busy} disabled={busy || link.trim() === ""}>
						{historyPeerCommit}
					</Button>
				</div>
				{taken !== "" && <Said id="archivePeerTaken" kind="success">{taken}</Said>}
			</form>
		</Submodal>
	);
}
