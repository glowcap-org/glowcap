// Issuing new workspace access under one held control, on a card of its own.
// The control is the row the reader pressed, so the card never asks which.
import { issueLead, managedAccessText as text } from "../../../lib/text/managed_access.ts";
import { useState, useSyncExternalStore } from "react";
import { useManagedSession } from "../session/managed/context.tsx";
import { canTryNow, controlName, type DescribedControl, OWN_CONTROL } from "../session/managed/held_control.ts";
import { cardAction, type PendingIssue, type ShareTerms } from "../session/managed/share_state.ts";
import { editableUnder } from "../session/managed/access_powers.ts";
import type { RoomsPermission } from "../../../lib/session_content_data.ts";
import { Button } from "../Button.tsx";
import { Switch } from "../Switch.tsx";
import { CopyField } from "../Copy.tsx";
import { Field } from "../Field.tsx";
import { Said } from "../Said.tsx";
import { Submodal } from "../Submodal.tsx";
import { PermissionFields, permissionRefusal } from "./PermissionFields.tsx";
import { type CeilingAnswer, ceilingOf, CeilingQuestion, NO_CEILING } from "./CeilingQuestion.tsx";
import { LocalRefusal } from "../../../lib/text/failure.ts";
import { closeFinishes, pressRefused, shareGestures } from "../session/managed/access_card.ts";
import type { PressRefusal } from "../session/managed/press_answer.ts";
import { useChangeGroup, useCommitments } from "../commitment.tsx";
import { Input } from "../Input.tsx";

/** You keep the control issuance returns, so by default it can change the new
 * access as far as yours could, and issue nothing beneath it. */
const startingCeilings = (control: DescribedControl): { editCeiling: CeilingAnswer; issueCeiling: CeilingAnswer } => ({
	editCeiling: editableUnder(control.state.powers) == null ? NO_CEILING : { mode: "all", custom: [] },
	issueCeiling: NO_CEILING,
});
/** A kept limit as the answer that grants exactly it. */
const answerOf = (ceiling: readonly RoomsPermission[] | null): CeilingAnswer =>
	ceiling == null ? NO_CEILING : { mode: "custom", custom: [...ceiling] };
/** What a share under way was prepared with, as its form shows it. */
const shownTerms = (terms: ShareTerms) => ({
	label: terms.label,
	permissions: [...terms.permissions],
	paused: terms.paused,
	depth: terms.depth,
	ceilings: { editCeiling: answerOf(terms.powers.editCeiling), issueCeiling: answerOf(terms.powers.issueCeiling) },
	delegable: terms.powers.delegateControl,
});

/** The waiting text, which names why the card's main button is off. */
const WAITING = "sessionIssueWaiting";

/** Whether closing the card drops work only the card holds: a form it has
 * not sent. A press under way, and any share it starts, is kept by
 * management whether or not the card is up, so closing over one takes
 * effect at once. */
export function holdsUnsent(busy: boolean, issue: PendingIssue | null, changed: boolean): boolean {
	return !busy && issue == null && changed;
}

export function SessionIssueModal(
	{ control, open, onClose }: { control: DescribedControl; open: boolean; onClose(): void },
) {
	const { management } = useManagedSession();
	useSyncExternalStore(management.subscribe, management.getVersion, management.getVersion);
	const commitments = useCommitments();
	const issue = management.issue;
	const source = issue?.source ?? control;
	const [label, setLabel] = useState("");
	const [permissions, setPermissions] = useState<RoomsPermission[]>(["observeWorkspace"]);
	const [starting] = useState(() => startingCeilings(control));
	const [ceilings, setCeilings] = useState(starting);
	const [paused, setPaused] = useState(false);
	const [depth, setDepth] = useState(0);
	const [busy, setBusy] = useState(false);
	// The last refused press, which the card shows by the rule `pressRefused`
	// keeps. The share from `source` is part of what its view shows.
	const [refusal, setRefusal] = useState<PressRefusal | null>(null);
	const [, redraw] = useState(0);
	const locked = busy || issue != null;
	const action = cardAction(issue, source);
	// A share waiting on a source this page cannot reach goes on once the
	// source's own row reaches it again, and its card says so.
	const waiting = !action.ready;
	// A share with nothing left to do, or one the connection ended, says so
	// here, and closing the card ends it.
	const done = action.kind === "done";
	const link = issue?.phase === "committed" ? issue.link : null;
	const group = "settings-session-issue";
	useChangeGroup(group, {
		dirty: holdsUnsent(
			busy,
			issue,
			label !== "" || paused || depth !== 0 || permissions.length !== 1 ||
				permissions[0] !== "observeWorkspace" || ceilings.editCeiling.mode !== starting.editCeiling.mode ||
				ceilings.issueCeiling.mode !== starting.issueCeiling.mode,
		),
		discard: () => {
			if (busy) throw new LocalRefusal("access-issuance-busy");
			setLabel("");
			setPermissions(["observeWorkspace"]);
			setCeilings(starting);
			setPaused(false);
			setDepth(0);
			setRefusal(null);
		},
	});
	const gestures = shareGestures(management, source);
	/** Run `press` through the owner. Its refusal is the card's answer. */
	const act = async (press: () => Promise<void>) => {
		if (busy) return;
		setBusy(true);
		setRefusal(null);
		try {
			setRefusal(await management.answer(source, press));
		} catch {
			// tolerant: the owner reported the fault, and the card stays usable.
		} finally {
			setBusy(false);
			redraw((value) => value + 1);
		}
	};
	const submit = () =>
		act(() =>
			gestures.goOn(permissions, label, paused, depth, {
				editCeiling: ceilingOf(ceilings.editCeiling, permissions, editableUnder(source.state.powers)),
				issueCeiling: ceilingOf(
					ceilings.issueCeiling,
					permissions,
					source.state.powers.issueCeiling?.permissions,
				),
			})
		);
	// A share under way shows what it was prepared with, the values it sends.
	const shown = issue == null
		? {
			label,
			permissions,
			paused,
			depth,
			ceilings,
			delegable: source.state.powers.delegateControl === true,
		}
		: shownTerms(issue.terms);
	const delegable = shown.delegable;
	// Closing lets go of a share as `closeFinishes` says, and the card closes
	// once that press succeeds or stays to say its answer. Otherwise closing
	// takes effect at once.
	const close = () => {
		if (!closeFinishes(issue, busy)) return onClose();
		void act(async () => {
			await gestures.finish();
			onClose();
		});
	};
	return (
		<Submodal
			title={text.issueTitle}
			titleId="sessionIssueTitle"
			className="session-issue-modal"
			open={open}
			onClose={() => commitments.request(close, { only: [group] })}
		>
			<p className="lead">
				{issueLead(source.id === OWN_CONTROL ? null : controlName(source, text))}
			</p>
			{issue?.phase === "committed"
				? (
					<div className="group well">
						<Said kind="success">{text.committedIssue}</Said>
						{link != null && <CopyField text={link} label={text.copyAccess} />}
						<p className="hint">{link != null ? text.copyAccessOnce : text.issueLinkPending}</p>
						{!done && (
							<div className="actions">
								<Button
									busy={busy}
									disabled={busy || waiting}
									aria-describedby={waiting ? WAITING : undefined}
									onClick={() => void submit()}
								>
									{text.recoverReturned}
								</Button>
							</div>
						)}
					</div>
				)
				: (
					<form
						id="sessionIssueForm"
						className="session-issue-form"
						onSubmit={(event) => {
							event.preventDefault();
							void submit();
						}}
					>
						<div className="group well">
							<ul className="entries option-rows">
								<li className="entry">
									<Field id="sessionAccessLabel" label={text.label}>
										{(wiring) => (
											<Input
												id={wiring.id}
												value={shown.label}
												disabled={locked}
												placeholder={text.labelPlaceholder}
												onChange={(event) => setLabel(event.currentTarget.value)}
											/>
										)}
									</Field>
								</li>
								<li className="entry">
									<div className="switch-row">
										<span className="entry-name" id="sessionIssueActiveLabel">
											{text.activeLabel}
										</span>
										<Switch
											id="sessionIssueActive"
											checked={!shown.paused}
											label={text.activeLabel}
											aria-labelledby="sessionIssueActiveLabel"
											disabled={locked}
											onClick={() => setPaused(!paused)}
										/>
									</div>
									<p className="hint">{shown.paused ? text.issuePausedSaid : text.issueActiveSaid}</p>
								</li>
							</ul>
						</div>
						<h3 className="well-title overline" id="sessionIssuePermissionsTitle">
							{text.permissionsTitle}
						</h3>
						<div className="group well" role="group" aria-labelledby="sessionIssuePermissionsTitle">
							<PermissionFields
								value={shown.permissions}
								ceiling={source.state.powers.issueCeiling?.permissions ?? []}
								disabled={locked}
								onChange={setPermissions}
							/>
						</div>
						{/* Onward sharing and future changes start from safe answers, so they stay folded. */}
						<details className="disclosure" data-align="center">
							<summary>
								{text.powers}
								<span className="disclosure-said">{text.advancedSaid}</span>
							</summary>
							<div className="group well">
								<ul className="entries option-rows">
									<li className="entry">
										<div className="switch-row">
											<label className="entry-name" htmlFor="sessionDelegationDepth">
												{text.depth}
											</label>
											<Input
												id="sessionDelegationDepth"
												className="option-number"
												type="number"
												inputMode="numeric"
												min={0}
												max={65535}
												value={shown.depth}
												disabled={locked}
												aria-describedby="sessionDelegationDepthHint"
												onChange={(event) => setDepth(event.currentTarget.valueAsNumber)}
											/>
										</div>
										<p className="hint" id="sessionDelegationDepthHint">{text.depthSaid}</p>
									</li>
								</ul>
								{delegable && (
									<>
										<CeilingQuestion
											label={text.editPolicy}
											noneSaid={text.editNoneSaid}
											answer={shown.ceilings.editCeiling}
											permissions={shown.permissions}
											available={editableUnder(source.state.powers)}
											disabled={locked}
											onChange={(answer) => setCeilings({ ...ceilings, editCeiling: answer })}
										/>
										<CeilingQuestion
											label={text.issueAccess}
											noneSaid={text.issueNoneSaid}
											answer={shown.ceilings.issueCeiling}
											permissions={shown.permissions}
											available={source.state.powers.issueCeiling?.permissions}
											disabled={locked}
											onChange={(answer) => setCeilings({ ...ceilings, issueCeiling: answer })}
										/>
									</>
								)}
							</div>
						</details>
					</form>
				)}
			{issue == null && (delegable
				? <p className="hint">{text.issuancePolicy}</p>
				: <Said kind="warning">{text.noDelegation}</Said>)}
			{waiting && (
				<Said kind="warning" id={WAITING}>
					{canTryNow(source) ? text.issueSourceUnreached : text.issueSourceGone}
				</Said>
			)}
			{busy && <Said kind="warning">{text.issueAnswerPending}</Said>}
			<IssueReply failure={pressRefused(refusal, management, source) ?? ""} issue={issue} />
			{
				/* Each act is its own element. Done finishes the issuance inside its click,
			    and a reused element would become Create before the click's default
			    action ran, submitting the form a second time. */
			}
			<div className="actions" data-fill>
				{done
					? (
						<Button
							key="done"
							size="large"
							onClick={close}
						>
							{text.done}
						</Button>
					)
					: action.kind === "review"
					? (
						<Button
							key="review"
							size="large"
							busy={busy}
							disabled={busy}
							onClick={() => void act(gestures.review)}
						>
							{text.reviewIssuer}
						</Button>
					)
					: action.kind === "recover"
					? (
						<Button
							key="recover"
							size="large"
							busy={busy}
							disabled={busy || waiting}
							aria-describedby={waiting ? WAITING : undefined}
							onClick={() => void submit()}
						>
							{text.recoverIssue}
						</Button>
					)
					// A share prepared but never sent is sent by the same press.
					: action.kind === "create" && (
						<Button
							key="create"
							type="submit"
							form="sessionIssueForm"
							size="large"
							busy={busy}
							disabled={busy || waiting || permissionRefusal(shown.permissions) !== "" ||
								new TextEncoder().encode(shown.label).length > 120 || !Number.isInteger(shown.depth) ||
								shown.depth < 0}
							aria-describedby={waiting ? WAITING : undefined}
						>
							{text.create}
						</Button>
					)}
			</div>
		</Submodal>
	);
}

/** A failure from the current gesture takes precedence over the held outcome. */
export function IssueReply({ failure, issue }: {
	failure: string;
	issue: Pick<PendingIssue, "phase" | "reason"> | null;
}) {
	const explanation = failure || issue?.reason;
	if (!explanation) return null;
	const warning = failure === "" && (issue?.phase === "uncertain" || issue?.phase === "conflict");
	return <Said kind={warning ? "warning" : "failure"}>{explanation}</Said>;
}
