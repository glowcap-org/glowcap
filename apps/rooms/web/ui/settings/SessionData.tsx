// The session's data, on a card of its own: a copy out, a copy in, and
// starting over. Three acts with three different weights, so each has a well
// and a title, and the one that cannot be undone asks first.
//
// Rooms and settings are what this card is about. Messages are kept
// separately, under Message history on the tab this card opens from, and the
// lead says so once so nobody exports a file expecting their history in it.

import { useRef, useState } from "react";
import { sessionStateFile } from "../../../lib/text/settings.ts";
import { sessionConfirmKeep } from "../../../lib/text/session.ts";
import {
	sessionDataClearLocalAsk,
	sessionDataClearLocalCommit,
	sessionDataClearLocalHint,
	sessionDataClearLocalLabel,
	sessionDataClearLocalSay,
	sessionDataClearLocalTitle,
	sessionDataClearSharedAsk,
	sessionDataClearSharedCommit,
	sessionDataClearSharedHint,
	sessionDataClearSharedLabel,
	sessionDataClearSharedSay,
	sessionDataClearSharedTitle,
	sessionDataExport,
	sessionDataExportTitle,
	sessionDataImport,
	sessionDataImported,
	sessionDataImportLocalHint,
	sessionDataImportSharedHint,
	sessionDataImportTitle,
	sessionDataIncludeCapabilities,
	sessionDataIncludeCapabilitiesSaid,
	sessionDataLocalLead,
	sessionDataLocalTitle,
	sessionDataMessagesApart,
	sessionDataSharedAdminLead,
	sessionDataSharedLead,
	sessionDataSharedTitle,
} from "../../../lib/text/session_settings.ts";
import { Button } from "../Button.tsx";
import { Checkbox } from "../Checkbox.tsx";
import { Confirm } from "../Confirm.tsx";
import { Field } from "../Field.tsx";
import { FilePick } from "../FilePick.tsx";
import { useRoomsSession } from "../controller/session.ts";
import { Said } from "../Said.tsx";
import { Submodal } from "../Submodal.tsx";
import { useChangeGroup, useCommitments } from "../commitment.tsx";
import { actionRefusal } from "../error_text.ts";

const STATE_FILE = "glowcap-rooms-state.json";

export function SessionDataModal(
	{ open, onClose, sharedSession, canAdminister }: {
		open: boolean;
		onClose(): void;
		sharedSession: boolean;
		canAdminister: boolean;
	},
) {
	const session = useRoomsSession();
	const commitments = useCommitments();
	const [includeCapabilities, setIncludeCapabilities] = useState(false);
	const [file, setFile] = useState<{ name: string; text: string } | null>(null);
	const [busy, setBusy] = useState<"export" | "import" | "clear" | null>(null);
	const [exported, setExported] = useState("");
	const [exportError, setExportError] = useState("");
	const [importError, setImportError] = useState("");
	const [imported, setImported] = useState("");
	const [clearError, setClearError] = useState("");
	const [confirming, setConfirming] = useState(false);
	const selection = useRef(0);
	// One data operation at a time: an export taken during an import or a
	// clear would save a state that is in the middle of changing.
	const operation = useRef<"export" | "import" | "clear" | null>(null);
	const dataLabel = sharedSession ? sessionDataSharedTitle : sessionDataLocalTitle;
	useChangeGroup("settings-session-data", {
		dirty: file !== null,
		discard: () => {
			if (operation.current !== null) throw new Error("Wait for the session data operation to finish.");
			selection.current += 1;
			setFile(null);
			setImportError("");
			setConfirming(false);
		},
	});
	const close = () => {
		selection.current += 1;
		onClose();
	};

	const download = async () => {
		if (operation.current !== null) return;
		operation.current = "export";
		setBusy("export");
		setExportError("");
		setExported("");
		try {
			const blob = new Blob([await session.exportRoomsState(includeCapabilities)], {
				type: "application/json",
			});
			const url = URL.createObjectURL(blob);
			const link = document.createElement("a");
			link.href = url;
			link.download = STATE_FILE;
			link.click();
			URL.revokeObjectURL(url);
			setExported(`Saved ${STATE_FILE}.`);
		} catch (cause) {
			setExportError(cause instanceof Error ? cause.message : String(cause));
		} finally {
			operation.current = null;
			setBusy(null);
		}
	};
	const choose = (chosen: File | null) => {
		const generation = ++selection.current;
		setImportError("");
		setImported("");
		setFile(null);
		if (chosen === null) {
			return;
		}
		void chosen.text().then(
			(text) => {
				if (selection.current === generation) setFile({ name: chosen.name, text });
			},
			(cause) => {
				if (selection.current === generation) {
					setImportError(cause instanceof Error ? cause.message : String(cause));
				}
			},
		);
	};
	const load = async () => {
		if (file === null || operation.current !== null) return;
		operation.current = "import";
		setBusy("import");
		setImportError("");
		setImported("");
		try {
			const refusal = await actionRefusal(() => session.importRoomsState(file.text));
			setImportError(refusal);
			if (refusal === "") {
				selection.current += 1;
				setFile(null);
				setImported(sessionDataImported(file.name));
			}
		} finally {
			operation.current = null;
			setBusy(null);
		}
	};
	const clear = async () => {
		if (operation.current !== null) return;
		operation.current = "clear";
		setBusy("clear");
		setClearError("");
		try {
			setClearError(await actionRefusal(() => session.clearRoomsState()));
		} finally {
			operation.current = null;
			setBusy(null);
		}
	};

	return (
		<Submodal
			title={dataLabel}
			titleId="sessionDataTitle"
			className="session-data-modal"
			open={open}
			onClose={() => commitments.request(close, { only: ["settings-session-data"] })}
		>
			<p className="lead">
				{sharedSession
					? canAdminister ? sessionDataSharedAdminLead : sessionDataSharedLead
					: sessionDataLocalLead} {sessionDataMessagesApart}
			</p>
			<h3 className="well-title overline" id="stateExportLegend">{sessionDataExportTitle}</h3>
			<div
				className="group well"
				role="group"
				aria-labelledby="stateExportLegend"
			>
				{canAdminister && (
					<label className="check-row">
						<Checkbox
							id="stateIncludeCapabilities"
							checked={includeCapabilities}
							onChange={(event) => {
								setIncludeCapabilities(event.currentTarget.checked);
								setExported("");
							}}
						/>
						<span>
							<strong>{sessionDataIncludeCapabilities}</strong>
							{sessionDataIncludeCapabilitiesSaid(sharedSession)}
						</span>
					</label>
				)}
				<div className="actions">
					<Button
						id="stateDownload"
						type="button"
						busy={busy === "export"}
						disabled={busy !== null}
						onClick={() => void download()}
					>
						{sessionDataExport}
					</Button>
				</div>
				{exported !== "" && <Said id="stateExported" kind="success">{exported}</Said>}
				{exportError !== "" && <Said kind="failure">{exportError}</Said>}
			</div>
			{canAdminister && (
				<>
					<h3 className="well-title overline" id="stateImportLegend">{sessionDataImportTitle}</h3>
					<form
						className="group well"
						role="group"
						aria-labelledby="stateImportLegend"
						onSubmit={(event) => {
							event.preventDefault();
							commitments.request(load, { except: ["settings-session-data"] });
						}}
					>
						<Field
							id="stateImport"
							label={sessionStateFile}
							hint={sharedSession ? sessionDataImportSharedHint : sessionDataImportLocalHint}
							said={importError}
						>
							{(wiring) => (
								<FilePick
									id={wiring.id}
									accept="application/json,.json"
									describedBy={wiring.describedBy}
									invalid={wiring.invalid}
									disabled={busy !== null}
									name={file?.name ?? null}
									onChoose={choose}
								/>
							)}
						</Field>
						<div className="actions">
							<Button
								id="stateImportGo"
								type="submit"
								busy={busy === "import"}
								disabled={file === null || busy !== null}
							>
								{sessionDataImport}
							</Button>
						</div>
						{imported !== "" && <Said id="stateImported" kind="success">{imported}</Said>}
					</form>
					<h3 className="well-title overline" id="stateClearLegend">
						{sharedSession ? sessionDataClearSharedTitle : sessionDataClearLocalTitle}
					</h3>
					<div
						className="group well"
						role="group"
						aria-labelledby="stateClearLegend"
					>
						<p className="hint">
							{sharedSession ? sessionDataClearSharedHint : sessionDataClearLocalHint}
						</p>
						{confirming
							? (
								<Confirm
									label={sharedSession ? sessionDataClearSharedLabel : sessionDataClearLocalLabel}
									say={sharedSession ? sessionDataClearSharedSay : sessionDataClearLocalSay}
									keep={sessionConfirmKeep}
									commit={sharedSession ? sessionDataClearSharedCommit : sessionDataClearLocalCommit}
									busy={busy === "clear"}
									keepId="stateClearKeep"
									commitId="stateClear"
									onKeep={() => setConfirming(false)}
									onCommit={() => commitments.request(clear)}
								/>
							)
							: (
								<div className="actions">
									<Button
										id="stateClearAsk"
										type="button"
										variant="quiet"
										disabled={busy !== null}
										onClick={() => setConfirming(true)}
									>
										{sharedSession ? sessionDataClearSharedAsk : sessionDataClearLocalAsk}
									</Button>
								</div>
							)}
						{clearError !== "" && <Said kind="failure">{clearError}</Said>}
					</div>
				</>
			)}
		</Submodal>
	);
}
