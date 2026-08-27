// Where this session's messages are kept.
//
// One switch answers whether anything is kept at all, one sentence under it
// says where, and the acts that change where sit at the foot. Choosing an
// archive peer is a pasted bearer capability rather than a press, so it opens
// a card of its own, the same way the session's own data and access do.
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
import { openModalFrom } from "../modal.ts";
import { Said } from "../Said.tsx";
import { Switch } from "../Switch.tsx";
import { useRoomsSession } from "../controller/session.ts";
import { SettingsSubmodal } from "./Submodal.tsx";

/** Where history is written now, said once under the switch. */
function historySaid(
	keepHistory: boolean,
	archiveTarget: ArchiveTargetView,
	sharedSession: boolean,
): string {
	if (!keepHistory) {
		return sharedSession
			? "Nothing is being kept. Room and direct messages arrive in the windows that are open and are not saved for later."
			: "Nothing is being kept. Room and direct messages arrive in this window and are not saved for later.";
	}
	if (archiveTarget.kind === "device") {
		return sharedSession
			? "New room and direct messages are kept by this durable Rooms session. Turning this off stops new writes."
			: "New room and direct messages are kept in this browser. Turning this off erases this browser's message archive.";
	}
	if (archiveTarget.status === "connected") {
		return `New room and direct messages are kept by ${archiveTarget.label}. Turning this off stops new writes; it cannot erase the session.`;
	}
	return `The selected ${archiveTarget.label} is unavailable. New messages are not silently copied into this browser.`;
}

export function HistorySettings(
	{ keepHistory, archiveTarget, sharedSession }: {
		keepHistory: boolean;
		archiveTarget: ArchiveTargetView;
		sharedSession: boolean;
	},
) {
	const session = useRoomsSession();
	const [busy, setBusy] = useState<"keep" | "retry" | "device" | null>(null);
	const [why, setWhy] = useState("");
	const [peerOpen, setPeerOpen] = useState(false);
	const onPeer = archiveTarget.kind === "peer";

	const act = async (which: "keep" | "retry" | "device", request: () => Promise<unknown>) => {
		setBusy(which);
		setWhy("");
		try {
			const answer = await request();
			if (typeof answer === "string" && answer !== "") setWhy(answer);
		} catch (error) {
			setWhy(error instanceof Error ? error.message : String(error));
		} finally {
			setBusy(null);
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
						busy={busy === "keep"}
						aria-labelledby="keepHistoryLegend"
						onClick={() => void act("keep", () => session.setKeepHistory(!keepHistory))}
					/>
				</div>
				<p className="hint" id="historyWhere">{historySaid(keepHistory, archiveTarget, sharedSession)}</p>
				{keepHistory && onPeer && archiveTarget.status !== "unavailable" && (
					<p className="hint">
						{archiveTarget.status === "connecting"
							? `Connecting to ${archiveTarget.label}…`
							: `${archiveTarget.label} is connected${
								archiveTarget.remembered
									? " and will reconnect after reload"
									: " for this page lifetime"
							}.`}
					</p>
				)}
				{keepHistory && (
					<div className="actions" data-stack-narrow>
						{onPeer && (
							<Button
								type="button"
								variant="quiet"
								busy={busy === "device"}
								disabled={busy !== null}
								onClick={() => void act("device", () => session.useDeviceArchive())}
							>
								{sharedSession ? "Use session archive" : "Use this browser"}
							</Button>
						)}
						{onPeer && archiveTarget.status === "unavailable" && (
							<Button
								type="button"
								variant="quiet"
								busy={busy === "retry"}
								disabled={busy !== null}
								onClick={() => void act("retry", () => session.retryArchivePeer())}
							>
								Reconnect
							</Button>
						)}
						<Button
							id="archivePeerOpen"
							type="button"
							onClick={(event) => openModalFrom(event.currentTarget, () => setPeerOpen(true))}
						>
							{onPeer ? "Change archive peer…" : "Use an archive peer…"}
						</Button>
					</div>
				)}
				{why !== "" && <Said kind="failure">{why}</Said>}
			</div>
			<ArchivePeerModal
				open={peerOpen}
				sharedSession={sharedSession}
				onClose={() => setPeerOpen(false)}
			/>
		</>
	);
}

function ArchivePeerModal(
	{ open, sharedSession, onClose }: { open: boolean; sharedSession: boolean; onClose(): void },
) {
	const session = useRoomsSession();
	const [link, setLink] = useState("");
	const [remember, setRemember] = useState(false);
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	const [taken, setTaken] = useState("");
	const take = async () => {
		setBusy(true);
		setWhy("");
		setTaken("");
		try {
			const refused = locatorRefusal(await session.takeArchivePeer(link, remember), "archive peer link");
			setWhy(refused);
			if (refused === "") {
				setLink("");
				setTaken("This archive peer keeps new history now.");
			}
		} finally {
			setBusy(false);
		}
	};
	return (
		<SettingsSubmodal
			title="Archive peer"
			titleId="archivePeerTitle"
			className="archive-peer-modal"
			open={open}
			onClose={onClose}
		>
			<p className="lead">
				An archive peer is a separate pancake peer that keeps your room and direct-message archive. The room and
				the people you message do not receive it.
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
					hint="Its sturdyref is bearer authority to read and write the whole archive. Changing peers does not copy earlier history; new messages are kept by the peer chosen here."
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
				{sharedSession
					? (
						<p className="hint">
							The shared session retains this archive capability for every attached view.
						</p>
					)
					: (
						<label className="check-row">
							<Checkbox
								id="rememberArchivePeer"
								checked={remember}
								onChange={(event) => setRemember(event.currentTarget.checked)}
							/>
							<span>
								<strong>Remember this archive peer in this browser</strong>
								Rooms stores its bearer here and reconnects after reload. Leave this clear to use it
								only until this page closes.
							</span>
						</label>
					)}
				<div className="actions" data-fill>
					<Button type="submit" size="large" busy={busy} disabled={busy || link === ""}>
						Use archive peer
					</Button>
				</div>
				{taken !== "" && <Said id="archivePeerTaken" kind="success">{taken}</Said>}
			</form>
		</SettingsSubmodal>
	);
}
