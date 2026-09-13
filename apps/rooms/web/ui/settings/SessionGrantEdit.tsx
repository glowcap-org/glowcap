// One access link, on a card of its own.
//
// What a link carries is four separate answers — who it is for, what it may do,
// whether it may read what was said before it arrived, and whether it is paused
// right now — and every one of them can be changed while somebody is holding
// it. That is a card's worth of decisions rather than a row's, and putting them
// in the row buried the list they were being compared in.
//
// Nothing here is saved: each answer is sent as it is given, because the ledger
// is what the link consults and there is no draft of a capability. A refusal
// belongs to the control that asked for it.

import { useState } from "react";
import { sessionGrantNotePlaceholder } from "../../../lib/text/settings.ts";
import {
	sessionAccessCopyLabel,
	sessionAccessLabel,
	sessionAccessSaid,
	sessionGrantAccessTitle,
	sessionGrantHistoryOff,
	sessionGrantHistoryOn,
	sessionGrantKeepWorking,
	sessionGrantLead,
	sessionGrantNowSaid,
	sessionGrantPause,
	sessionGrantPauseAsk,
	sessionGrantPausedNote,
	sessionGrantPausedNow,
	sessionGrantPausedSaid,
	sessionGrantPauseInUse,
	sessionGrantPauseLead,
	sessionGrantPausing,
	sessionGrantResume,
	sessionGrantResumedSaid,
	sessionGrantWhyHint,
	sessionGrantWhyLabel,
	sessionGrantWhyOptional,
	sessionHistoryLabel,
	sessionHistorySaid,
} from "../../../lib/text/session_settings.ts";
import { MAX_SESSION_GRANT_NOTE } from "../limits.ts";
import type { RoomsSessionFacet, RoomsSessionGrantView } from "../../../lib/session/client.ts";
import { Button } from "../Button.tsx";
import { Checkbox } from "../Checkbox.tsx";
import { CopyField } from "../Copy.tsx";
import { Field } from "../Field.tsx";
import { Said } from "../Said.tsx";
import { Submodal } from "../Submodal.tsx";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";
import { actionRefusal } from "../error_text.ts";

export const ACCESS_LEVELS: readonly RoomsSessionFacet[] = ["observe", "interact", "admin"];

/** The three levels are a scale, so the chips that name them are one too. */
export const ACCESS_TONE: Readonly<Record<RoomsSessionFacet, "quiet" | "warn" | undefined>> = {
	observe: "quiet",
	interact: undefined,
	admin: "warn",
};

export function SessionGrantEditModal(
	{ grant, inUse, open, onClose }: {
		grant: RoomsSessionGrantView | null;
		/** Whether this is the link the browser reading this card is attached
		 * through. Pausing it is as much a way out as revoking it, and the list
		 * behind this card already says so about revoking. */
		inUse: boolean;
		open: boolean;
		onClose(): void;
	},
) {
	const browser = useRoomsBrowser();
	const session = useRoomsSession();
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	const [note, setNote] = useState("");
	const [pausing, setPausing] = useState(false);
	if (grant == null) return null;

	const change = async (
		patch: { rights?: RoomsSessionFacet; history?: boolean; suspended?: boolean; note?: string },
		said: string,
	) => {
		setBusy(true);
		setWhy("");
		try {
			const refusal = await actionRefusal(() => session.changeSessionGrant(grant.id, patch));
			setWhy(refusal);
			if (refusal === "") {
				browser.toast("success", said);
				setPausing(false);
				setNote("");
			}
		} finally {
			setBusy(false);
		}
	};

	return (
		<Submodal
			title={grant.label}
			titleId="sessionGrantEditTitle"
			className="session-grant-edit-modal"
			open={open}
			onClose={onClose}
		>
			<p className="lead">{sessionGrantLead}</p>

			<h3 className="well-title overline" id="sessionGrantEditAccess">{sessionGrantAccessTitle}</h3>
			<div className="group well" role="group" aria-labelledby="sessionGrantEditAccess">
				<div className="choices" role="radiogroup" aria-label={sessionGrantAccessTitle}>
					{ACCESS_LEVELS.map((level) => (
						<label className="choice" key={level}>
							<input
								type="radio"
								name="sessionGrantEditRights"
								value={level}
								checked={grant.rights === level}
								disabled={busy}
								onChange={() =>
									void change(
										{ rights: level },
										sessionGrantNowSaid(grant.label, sessionAccessLabel[level].toLowerCase()),
									)}
							/>
							<span>
								<strong>{sessionAccessLabel[level]}</strong>
								{sessionAccessSaid[level]}
							</span>
						</label>
					))}
				</div>
				<label className="check-row">
					<Checkbox
						id="sessionGrantEditHistory"
						checked={grant.history}
						disabled={busy}
						onChange={() =>
							void change(
								{ history: !grant.history },
								grant.history
									? sessionGrantHistoryOff(grant.label)
									: sessionGrantHistoryOn(grant.label),
							)}
					/>
					<span>
						<strong>{sessionHistoryLabel}</strong>
						{sessionHistorySaid}
					</span>
				</label>
			</div>

			<h3 className="well-title overline" id="sessionGrantEditPause">{sessionGrantPausing}</h3>
			<div className="group well" role="group" aria-labelledby="sessionGrantEditPause">
				{grant.suspended
					? (
						<>
							<Said kind="warning">
								{grant.note === "" ? sessionGrantPausedSaid : sessionGrantPausedNote(grant.note)}
							</Said>
							<div className="actions" data-align="start">
								<Button
									id="sessionGrantResume"
									busy={busy}
									onClick={() =>
										void change({ suspended: false }, sessionGrantResumedSaid(grant.label))}
								>
									{sessionGrantResume}
								</Button>
							</div>
						</>
					)
					: pausing
					? (
						<>
							<Field
								id="sessionGrantNote"
								label={sessionGrantWhyLabel}
								optional={sessionGrantWhyOptional}
								hint={sessionGrantWhyHint}
								said={why}
							>
								{(wiring) => (
									<input
										id={wiring.id}
										className="field"
										aria-describedby={wiring.describedBy}
										aria-invalid={wiring.invalid}
										value={note}
										maxLength={MAX_SESSION_GRANT_NOTE}
										disabled={busy}
										onChange={(event) => setNote(event.currentTarget.value)}
										placeholder={sessionGrantNotePlaceholder}
									/>
								)}
							</Field>
							{inUse && <Said kind="warning">{sessionGrantPauseInUse}</Said>}
							<div className="actions" data-align="start">
								<Button
									id="sessionGrantPauseCommit"
									busy={busy}
									onClick={() =>
										void change(
											{ suspended: true, note: note.trim() },
											sessionGrantPausedNow(grant.label),
										)}
								>
									{sessionGrantPause}
								</Button>
								<Button variant="quiet" disabled={busy} onClick={() => setPausing(false)}>
									{sessionGrantKeepWorking}
								</Button>
							</div>
						</>
					)
					: (
						<>
							<p className="lead">{sessionGrantPauseLead}</p>
							<div className="actions" data-align="start">
								<Button id="sessionGrantPause" variant="quiet" onClick={() => setPausing(true)}>
									{sessionGrantPauseAsk}
								</Button>
							</div>
						</>
					)}
			</div>

			{
				/* Every other control on this card refuses here. The note field
				   carries its own, because a refusal about what was typed belongs
				   beside the box it was typed in. */
			}
			{why !== "" && !pausing && <Said kind="failure">{why}</Said>}
			<CopyField text={grant.sturdyref} label={sessionAccessCopyLabel(grant.label)} />
		</Submodal>
	);
}
