// The session's data, on a card of its own: a copy out, a copy in, and
// starting over. Three acts with three different weights, so each has a well
// and a title, and the one that cannot be undone asks first.
//
// Rooms and settings are what this card is about. Messages are kept
// separately, under Message history on the tab this card opens from, and the
// lead says so once so nobody exports a file expecting their history in it.

import { useState } from "react";
import { Button } from "../Button.tsx";
import { Checkbox } from "../Checkbox.tsx";
import { Confirm } from "../Confirm.tsx";
import { Field } from "../Field.tsx";
import { FilePick } from "../FilePick.tsx";
import { useRoomsSession } from "../controller/session.ts";
import { Said } from "../Said.tsx";
import { SettingsSubmodal } from "./Submodal.tsx";

const STATE_FILE = "pancake-rooms-state.json";

export function SessionDataModal(
	{ open, onClose, sharedSession, canAdminister }: {
		open: boolean;
		onClose(): void;
		sharedSession: boolean;
		canAdminister: boolean;
	},
) {
	const session = useRoomsSession();
	const [includeCapabilities, setIncludeCapabilities] = useState(false);
	const [file, setFile] = useState<{ name: string; text: string } | null>(null);
	const [busy, setBusy] = useState<"import" | "clear" | null>(null);
	const [exported, setExported] = useState("");
	const [exportError, setExportError] = useState("");
	const [importError, setImportError] = useState("");
	const [clearError, setClearError] = useState("");
	const [confirming, setConfirming] = useState(false);
	const dataLabel = sharedSession ? "Shared session data" : "Local session data";

	const download = () => {
		setExportError("");
		setExported("");
		try {
			const blob = new Blob([session.exportRoomsState(includeCapabilities)], {
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
		}
	};
	const choose = (chosen: File | null) => {
		setImportError("");
		if (chosen === null) {
			setFile(null);
			return;
		}
		void chosen.text().then(
			(text) => setFile({ name: chosen.name, text }),
			(cause) => setImportError(cause instanceof Error ? cause.message : String(cause)),
		);
	};
	const load = async () => {
		if (file === null) return;
		setBusy("import");
		setImportError("");
		try {
			setImportError(await session.importRoomsState(file.text));
		} finally {
			setBusy(null);
		}
	};
	const clear = async () => {
		setBusy("clear");
		setClearError("");
		try {
			setClearError(await session.clearRoomsState());
		} finally {
			setBusy(null);
		}
	};

	return (
		<SettingsSubmodal
			title={dataLabel}
			titleId="sessionDataTitle"
			className="session-data-modal"
			open={open}
			onClose={onClose}
		>
			<p className="lead">
				{sharedSession
					? canAdminister
						? "The rooms and settings everyone attached to this session shares, plus this browser's own view preferences."
						: "The rooms and settings this capability can see, plus this browser's own view preferences. It cannot replace or reset them."
					: "The rooms, settings, and view preferences this browser keeps."}{" "}
				Messages are kept separately, under Message history.
			</p>
			<h3 className="well-title overline" id="stateExportLegend">
				Export a copy
			</h3>
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
							<strong>Include remembered capabilities</strong>
							The file will also hold the links that grant access to rooms, operations, moderation, and
							any archive. Anyone with the file could use them.
						</span>
					</label>
				)}
				<div className="actions">
					<Button id="stateDownload" type="button" onClick={download}>
						Export state
					</Button>
				</div>
				{exported !== "" && <Said id="stateExported" kind="success">{exported}</Said>}
				{exportError !== "" && <Said kind="failure">{exportError}</Said>}
			</div>
			{canAdminister && (
				<>
					<h3 className="well-title overline" id="stateImportLegend">
						Replace from a file
					</h3>
					<form
						className="group well"
						role="group"
						aria-labelledby="stateImportLegend"
						onSubmit={(event) => {
							event.preventDefault();
							void load();
						}}
					>
						<Field
							id="stateImport"
							label="State file"
							hint={sharedSession
								? "Importing replaces the shared session's rooms and settings once the file checks out, and this browser stays attached. A file that carries capabilities grants every one of them."
								: "Importing replaces this browser's rooms and settings once the file checks out. A file that carries capabilities grants every one of them."}
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
								Import and reload
							</Button>
						</div>
					</form>
					<h3 className="well-title overline" id="stateClearLegend">
						{sharedSession ? "Start the session over" : "Start over"}
					</h3>
					<div
						className="group well"
						role="group"
						aria-labelledby="stateClearLegend"
					>
						<p className="hint">
							{sharedSession
								? "Everyone attached starts again from no rooms and no settings. The session itself stays, and message archives are not erased."
								: "This browser forgets its rooms, settings, and remembered capabilities, then goes back to choosing a session. Rooms on servers and archives elsewhere are not erased."}
						</p>
						{confirming
							? (
								<Confirm
									label={sharedSession ? "Reset the shared session" : "Delete this browser's session"}
									say={sharedSession
										? "Every attached browser sees an empty session the moment this goes through."
										: "This browser's message archive goes with it."}
									keep="Keep it"
									commit={sharedSession ? "Reset shared session" : "Delete local session"}
									busy={busy === "clear"}
									keepId="stateClearKeep"
									commitId="stateClear"
									onKeep={() => setConfirming(false)}
									onCommit={() => void clear()}
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
										{sharedSession ? "Reset shared session…" : "Delete local session…"}
									</Button>
								</div>
							)}
						{clearError !== "" && <Said kind="failure">{clearError}</Said>}
					</div>
				</>
			)}
		</SettingsSubmodal>
	);
}
