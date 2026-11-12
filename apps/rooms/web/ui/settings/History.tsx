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
	historyOnSessionOff,
	historyPeerDurable,
	historyPeerLead,
	historyPeerSaved,
	historyPeerUnavailable,
} from "../../../lib/text/settings.ts";
import {
	historyArchiveTitle,
	historyChangePeerAsk,
	historyKeptBy,
	historyKeptByOff,
	historyOwnedSession,
	historyPeerCommit,
	historyPeerModalLead,
	historyPeerSessionRetains,
	historyPeerTaken,
	historyPeerUnavailableSaid,
	historyReadAgain,
	historyTitle,
	historyUsePeerAsk,
	historyUseSessionArchive,
} from "../../../lib/text/session_settings.ts";
import type { ArchiveTargetView } from "../archive_model.ts";
import { Button } from "../Button.tsx";
import { Field } from "../Field.tsx";
import { addressField } from "../field.ts";
import { actionRefusal } from "../error_text.ts";
import { useOpenModal } from "../modal.ts";
import { useServerGate } from "../hooks.ts";
import { linkNeedsServer } from "../application.ts";
import { serverNeedAddress } from "../../../lib/text/session.ts";
import { Said } from "../Said.tsx";
import { Switch } from "../Switch.tsx";
import { useRoomsSession } from "../controller/session.ts";
import { Submodal } from "../Submodal.tsx";
import { useChangeGroup, useCommitments, useCommitSettling } from "../commitment.tsx";
import { LocalRefusal, refusalText } from "../../../lib/text/failure.ts";
import { sturdyrefPlaceholder } from "../../../lib/text/controls.ts";
import { Input } from "../Input.tsx";

/** Where history is written now, said once. What the switch would change is
 * said only to a reader who is shown the switch. */
function historySaid(
	keepHistory: boolean,
	archiveTarget: ArchiveTargetView,
	canConfigure: boolean,
): string {
	if (!keepHistory) {
		return historyOffSession;
	}
	if (archiveTarget.kind === "owned") {
		return canConfigure ? `${historyOnSession} ${historyOnSessionOff}` : historyOnSession;
	}
	// What this access may read does not change who keeps the messages.
	if (archiveTarget.status === "connected" || archiveTarget.status === "denied") {
		const kept = historyKeptBy(archiveTarget.label);
		return canConfigure ? `${kept} ${historyKeptByOff}` : kept;
	}
	return historyPeerUnavailableSaid(archiveTarget.label);
}

/** What a press answered. A retry's reply is given under the archive status
 * it answered. The switch's reply is about no read, so it has none. */
export type PressReply = { readonly text: string; readonly under: ArchiveTargetView["status"] | null };

/** A retry's reply stands only while the status it was given under holds,
 * because a read that settled since says more. Any other reply stands until
 * the next press. */
export function standingReply(reply: PressReply, status: ArchiveTargetView["status"]): string {
	return reply.under == null || reply.under === status ? reply.text : "";
}

export function HistorySettings(
	{ keepHistory, archiveTarget, canConfigure, canRead }: {
		canConfigure: boolean;
		canRead: boolean;
		keepHistory: boolean;
		archiveTarget: ArchiveTargetView;
	},
) {
	const session = useRoomsSession();
	const [busy, setBusy] = useState(false);
	const [reply, setReply] = useState<PressReply>({ text: "", under: null });
	const failure = standingReply(reply, archiveTarget.status) || archiveTarget.error;
	const toggle = async () => {
		setBusy(true);
		setReply({ text: "", under: null });
		try {
			await session.setKeepHistory(!keepHistory);
		} catch (error) {
			setReply({ text: refusalText(error), under: null });
		} finally {
			setBusy(false);
		}
	};

	const retry = async () => {
		setBusy(true);
		const under = archiveTarget.status;
		setReply({ text: "", under });
		try {
			setReply({ text: await session.retryHistory(), under });
		} catch (error) {
			setReply({ text: refusalText(error), under });
		} finally {
			setBusy(false);
		}
	};

	return (
		<>
			<h3 className="well-title overline" id="historyLegend">{historyTitle}</h3>
			<div className="group well" role="group" aria-labelledby="historyLegend">
				{failure !== "" && <Said kind="failure">{failure}</Said>}
				{canConfigure && (
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
				)}
				<p className="hint" id="historyWhere">{historySaid(keepHistory, archiveTarget, canConfigure)}</p>
				{canRead && archiveTarget.status === "unavailable" && (
					<div className="actions">
						<Button
							id="historyReadAgain"
							busy={busy}
							disabled={busy}
							onClick={() => void retry()}
						>
							{historyReadAgain}
						</Button>
					</div>
				)}
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
	const useOwn = async () => {
		if (busy) return;
		setBusy(true);
		setWhy("");
		try {
			await session.useOwnedArchive();
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
						{onPeer ? archiveTarget.label : historyBuiltInSession}
					</span>
					{onPeer && <span className="tag">{historyPeerSaved}</span>}
				</div>
				<p className="hint">
					{onPeer
						? archiveTarget.status === "unavailable"
							? historyPeerUnavailable
							: archiveTarget.status === "denied"
							? archiveTarget.error
							: historyPeerDurable
						: historyOwnedSession}
				</p>
				<div className="actions">
					{onPeer && (
						<Button
							type="button"
							variant="quiet"
							busy={busy}
							disabled={busy}
							onClick={() => void useOwn()}
						>
							{historyUseSessionArchive}
						</Button>
					)}
					<Button
						id="archivePeerOpen"
						type="button"
						variant="quiet"
						disabled={busy}
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
	const serverGate = useServerGate();
	const commitments = useCommitments();
	const [link, setLink] = useState("");
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	const [taken, setTaken] = useState("");
	const commit = useCommitSettling();
	useChangeGroup("settings-archive-peer", {
		dirty: link !== "",
		discard: () => {
			if (busy) throw new LocalRefusal("settings-archive-peer-changing");
			setLink("");
			setWhy("");
			setTaken("");
		},
		settling: commit.current,
	});
	const take = async () => {
		// An archive peer is reached at the address its capability names, so
		// one this browser cannot open on its own needs the Rooms server first.
		if (linkNeedsServer(link.trim()) && serverGate(serverNeedAddress) == null) return;
		commit.begin();
		setBusy(true);
		setWhy("");
		setTaken("");
		try {
			const refused = await actionRefusal(() => session.takeArchivePeer(link));
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
						<Input
							id={wiring.id}
							{...addressField}
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
