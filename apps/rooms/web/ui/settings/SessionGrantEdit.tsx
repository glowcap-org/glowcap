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
import { MAX_SESSION_GRANT_NOTE } from "../../../lib/limits.ts";
import type { RoomsSessionFacet, RoomsSessionGrantView } from "../../../lib/session/client.ts";
import { Button } from "../Button.tsx";
import { Checkbox } from "../Checkbox.tsx";
import { CopyField } from "../Copy.tsx";
import { Field } from "../Field.tsx";
import { Said } from "../Said.tsx";
import { Submodal } from "../Submodal.tsx";
import { useRoomsBrowser } from "../controller/browser.ts";
import { useRoomsSession } from "../controller/session.ts";

export const ACCESS_LABEL: Readonly<Record<RoomsSessionFacet, string>> = {
	observe: "Read only",
	interact: "Can interact",
	admin: "Can administer",
};

export const ACCESS_DESCRIPTION: Readonly<Record<RoomsSessionFacet, string>> = {
	observe: "Can follow rooms and messages, but cannot type or change the workspace.",
	interact: "Can join, post, and update their own activity, but cannot manage the session.",
	admin: "Full workspace control, including session data, access links, and saved capabilities.",
};

export const ACCESS_LEVELS: readonly RoomsSessionFacet[] = ["observe", "interact", "admin"];

/** The three levels are a scale, so the chips that name them are one too. */
export const ACCESS_TONE: Readonly<Record<RoomsSessionFacet, "quiet" | "warn" | undefined>> = {
	observe: "quiet",
	interact: undefined,
	admin: "warn",
};

/** What a link may read of what was said before it arrived. Its own answer
 * rather than a rung on the access scale, because reading the past and
 * administering the session are different authorities. */
export const HISTORY_LABEL = "Can read earlier messages";
export const HISTORY_SAID =
	"Everything this session has recorded, not only what is said from the moment the link is used.";

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
			const refusal = await session.changeSessionGrant(grant.id, patch);
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
			<p className="lead">Changes reach whoever is holding this link. The link itself never changes.</p>

			<h3 className="well-title overline" id="sessionGrantEditAccess">Access</h3>
			<div className="group well" role="group" aria-labelledby="sessionGrantEditAccess">
				<div className="choices" role="radiogroup" aria-label="Access">
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
										`${grant.label} is now ${ACCESS_LABEL[level].toLowerCase()}.`,
									)}
							/>
							<span>
								<strong>{ACCESS_LABEL[level]}</strong>
								{ACCESS_DESCRIPTION[level]}
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
									? `${grant.label} can no longer read earlier messages.`
									: `${grant.label} can read earlier messages.`,
							)}
					/>
					<span>
						<strong>{HISTORY_LABEL}</strong>
						{HISTORY_SAID}
					</span>
				</label>
			</div>

			<h3 className="well-title overline" id="sessionGrantEditPause">Pausing</h3>
			<div className="group well" role="group" aria-labelledby="sessionGrantEditPause">
				{grant.suspended
					? (
						<>
							<Said kind="warning">
								{grant.note === ""
									? "This link is paused. Whoever holds it can reach nothing until it is let back in."
									: `This link is paused: ${grant.note}`}
							</Said>
							<div className="actions" data-align="start">
								<Button
									id="sessionGrantResume"
									busy={busy}
									onClick={() => void change({ suspended: false }, `${grant.label} works again.`)}
								>
									Let it back in
								</Button>
							</div>
						</>
					)
					: pausing
					? (
						<>
							<Field
								id="sessionGrantNote"
								label="Why"
								optional="Optional"
								hint="Said to whoever holds this link, in place of the session."
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
										placeholder="Back on Monday"
									/>
								)}
							</Field>
							{inUse && (
								<Said kind="warning">
									This is the link this browser is using. Pausing it stops this browser too, and
									letting it back in has to be done from somewhere else.
								</Said>
							)}
							<div className="actions" data-align="start">
								<Button
									id="sessionGrantPauseCommit"
									busy={busy}
									onClick={() =>
										void change(
											{ suspended: true, note: note.trim() },
											`${grant.label} is paused.`,
										)}
								>
									Pause it
								</Button>
								<Button variant="quiet" disabled={busy} onClick={() => setPausing(false)}>
									Keep it working
								</Button>
							</div>
						</>
					)
					: (
						<>
							<p className="lead">
								A paused link reaches nothing and keeps the access it was issued with, so letting it
								back in restores that.
							</p>
							<div className="actions" data-align="start">
								<Button id="sessionGrantPause" variant="quiet" onClick={() => setPausing(true)}>
									Pause access…
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
			<CopyField text={grant.sturdyref} label={`Copy session access for ${grant.label}`} />
		</Submodal>
	);
}
