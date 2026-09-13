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
import {
	historyArchivePeerLabel,
	historyArchivePeerTitle,
	historyBuiltInBrowser,
	historyBuiltInSession,
	historyKeepLabel,
	historyOffLocal,
	historyOffShared,
	historyOnLocal,
	historyOnShared,
	historyPeerDurable,
	historyPeerLead,
	historyPeerLive,
	historyPeerReconnect,
	historyPeerSaved,
	historyPeerSession,
	historyPeerUnavailable,
} from "../../../lib/text/settings.ts";
import {
	historyArchiveTitle,
	historyChangePeerAsk,
	historyKeptBy,
	historyOwnedBrowser,
	historyOwnedSession,
	historyPeerCommit,
	historyPeerModalLead,
	historyPeerRemember,
	historyPeerRememberSaid,
	historyPeerSessionRetains,
	historyPeerTaken,
	historyPeerUnavailableSaid,
	historyTitle,
	historyUseBrowser,
	historyUsePeerAsk,
	historyUseSessionArchive,
} from "../../../lib/text/session_settings.ts";
import type { ArchiveTargetView } from "../archive_model.ts";
import { Button } from "../Button.tsx";
import { Checkbox } from "../Checkbox.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { actionRefusal, locatorRefusal } from "../error_text.ts";
import { useOpenModal } from "../modal.ts";
import { Said } from "../Said.tsx";
import { Switch } from "../Switch.tsx";
import { useRoomsSession } from "../controller/session.ts";
import { Submodal } from "../Submodal.tsx";
import { useChangeGroup, useCommitments, useCommitSettling } from "../commitment.tsx";
import type { ArchiveOwner } from "../archive_model.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import { sturdyrefPlaceholder } from "../../../lib/text/controls.ts";

/** Where history is written now, said once under the switch. */
function historySaid(
	keepHistory: boolean,
	archiveTarget: ArchiveTargetView,
): string {
	const sharedSession = archiveTarget.owner === "session";
	if (!keepHistory) {
		return sharedSession ? historyOffShared : historyOffLocal;
	}
	if (archiveTarget.kind === "owned") {
		return sharedSession ? historyOnShared : historyOnLocal;
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
			setWhy(refusalText(error));
		} finally {
			setBusy(false);
		}
	};
	return (
		<>
			<h3 className="well-title overline" id="archiveHoldingLegend">{historyArchiveTitle}</h3>
			<div className="group well" role="group" aria-labelledby="archiveHoldingLegend">
				<div className="entry-head">
					<span className="entry-name">
						{onPeer
							? archiveTarget.label
							: archiveTarget.owner === "session"
							? historyBuiltInSession
							: historyBuiltInBrowser}
					</span>
					{onPeer && (
						<span className="tag">{archiveTarget.remembered ? historyPeerSaved : historyPeerLive}</span>
					)}
				</div>
				<p className="hint">
					{onPeer
						? archiveTarget.status === "unavailable"
							? historyPeerUnavailable
							: archiveTarget.remembered
							? historyPeerDurable
							: historyPeerSession
						: archiveTarget.owner === "session"
						? historyOwnedSession
						: historyOwnedBrowser}
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
							{archiveTarget.owner === "session" ? historyUseSessionArchive : historyUseBrowser}
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
							{historyPeerReconnect}
						</Button>
					)}
					<Button
						id="archivePeerOpen"
						type="button"
						variant="quiet"
						onClick={(event) => openModalFrom(event.currentTarget, () => setPeerOpen(true))}
					>
						{onPeer ? historyChangePeerAsk : historyUsePeerAsk}
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
			const refused = locatorRefusal(
				await actionRefusal(() => session.takeArchivePeer(link, remember)),
				"archive peer link",
			);
			setWhy(refused);
			if (refused === "") {
				setLink("");
				setRemember(false);
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
				{owner === "session"
					? <p className="hint">{historyPeerSessionRetains}</p>
					: (
						<label className="check-row">
							<Checkbox
								id="rememberArchivePeer"
								checked={remember}
								onChange={(event) => setRemember(event.currentTarget.checked)}
							/>
							<span>
								<strong>{historyPeerRemember}</strong>
								{historyPeerRememberSaid}
							</span>
						</label>
					)}
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
