// Issuing new workspace access under one held control, on a card of its own.
// The control is the row the reader pressed, so the card never asks which.
import { issueLead, managedAccessText as text } from "../../../lib/text/managed_access.ts";
import { useState, useSyncExternalStore } from "react";
import { useManagedSession } from "../session/managed/context.tsx";
import { controlName, editableUnder, type HeldControl, OWN_CONTROL } from "../session/managed/access.ts";
import type { RoomsPermission } from "../../../lib/session_content_data.ts";
import { Button } from "../Button.tsx";
import { Switch } from "../Switch.tsx";
import { CopyField } from "../Copy.tsx";
import { Field } from "../Field.tsx";
import { Said } from "../Said.tsx";
import { Submodal } from "../Submodal.tsx";
import { PermissionFields, permissionRefusal } from "./PermissionFields.tsx";
import { type CeilingAnswer, ceilingOf, CeilingQuestion, NO_CEILING } from "./CeilingQuestion.tsx";
import { refusalText } from "../../../lib/text/failure.ts";
import { useChangeGroup, useCommitments, useCommitSettling } from "../commitment.tsx";

/** You keep the control issuance returns, so by default it can change the new
 * access as far as yours could, and issue nothing beneath it. */
const startingCeilings = (control: HeldControl): { editCeiling: CeilingAnswer; issueCeiling: CeilingAnswer } => ({
	editCeiling: editableUnder(control.powers) == null ? NO_CEILING : { mode: "all", custom: [] },
	issueCeiling: NO_CEILING,
});

export function SessionIssueModal(
	{ control, open, onClose }: { control: HeldControl; open: boolean; onClose(): void },
) {
	const { management } = useManagedSession();
	useSyncExternalStore(management.subscribe, management.getVersion, management.getVersion);
	const commitments = useCommitments();
	const commit = useCommitSettling();
	const issue = management.issue;
	const source = issue?.source ?? control;
	const [label, setLabel] = useState("");
	const [permissions, setPermissions] = useState<RoomsPermission[]>(["observeWorkspace"]);
	const [starting] = useState(() => startingCeilings(control));
	const [ceilings, setCeilings] = useState(starting);
	const [paused, setPaused] = useState(false);
	const [depth, setDepth] = useState(0);
	const [busy, setBusy] = useState(false);
	const [reason, setReason] = useState("");
	const [link, setLink] = useState("");
	const [, redraw] = useState(0);
	const locked = busy || issue != null;
	const done = issue?.phase === "committed" && issue.control?.saved === true && link !== "";
	const group = "settings-session-issue";
	useChangeGroup(group, {
		// A finished issuance has nothing left to lose; closing completes it.
		dirty: !done && (label !== "" || issue != null || paused || depth !== 0 ||
			permissions.length !== 1 || permissions[0] !== "observeWorkspace" ||
			ceilings.editCeiling.mode !== starting.editCeiling.mode ||
			ceilings.issueCeiling.mode !== starting.issueCeiling.mode),
		discard: () => {
			if (busy || (issue != null && issue.phase !== "conflict")) {
				throw new Error("Recover and save the original issuance before discarding this form.");
			}
			management.finishIssue();
			setLabel("");
			setPermissions(["observeWorkspace"]);
			setCeilings(starting);
			setPaused(false);
			setDepth(0);
			setReason("");
		},
		settling: commit.current,
	});
	const act = async (action: () => Promise<void>) => {
		if (busy) return;
		commit.begin();
		setBusy(true);
		setReason("");
		try {
			await action();
		} catch (error) {
			setReason(refusalText(error));
		} finally {
			setBusy(false);
			commit.finish();
			redraw((value) => value + 1);
		}
	};
	const submit = () =>
		act(async () => {
			if (management.issue == null) {
				await management.prepareIssue(source, permissions, label, paused, depth, {
					editCeiling: ceilingOf(ceilings.editCeiling, permissions, editableUnder(source.powers)),
					issueCeiling: ceilingOf(
						ceilings.issueCeiling,
						permissions,
						source.powers.issueCeiling?.permissions,
					),
				});
			}
			const outcome = await management.submitIssue();
			setReason(outcome.reason);
			if (outcome.phase === "committed" && outcome.control != null) {
				await management.save(outcome.control);
				setLink(await outcome.access!.publish());
			}
		});
	const delegable = source.powers.delegateControl === true;
	const close = () => {
		if (done) management.finishIssue();
		onClose();
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
						{link && <CopyField text={link} label={text.copyAccess} />}
						{link && <p className="hint">{text.copyAccessOnce}</p>}
						{!done && (
							<div className="actions">
								<Button busy={busy} disabled={busy} onClick={() => void submit()}>
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
											<input
												id={wiring.id}
												className="field"
												value={label}
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
											checked={!paused}
											label={text.activeLabel}
											aria-labelledby="sessionIssueActiveLabel"
											disabled={locked}
											onClick={() => setPaused(!paused)}
										/>
									</div>
									<p className="hint">{paused ? text.issuePausedSaid : text.issueActiveSaid}</p>
								</li>
							</ul>
						</div>
						<h3 className="well-title overline" id="sessionIssuePermissionsTitle">
							{text.permissionsTitle}
						</h3>
						<div className="group well" role="group" aria-labelledby="sessionIssuePermissionsTitle">
							<PermissionFields
								value={permissions}
								ceiling={source.powers.issueCeiling?.permissions ?? []}
								disabled={locked}
								onChange={setPermissions}
							/>
						</div>
						{/* Onward sharing and future changes start from safe answers, so they stay folded. */}
						<details className="disclosure">
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
											<input
												id="sessionDelegationDepth"
												className="field option-number"
												type="number"
												inputMode="numeric"
												min={0}
												max={65535}
												value={depth}
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
											answer={ceilings.editCeiling}
											permissions={permissions}
											available={editableUnder(source.powers)}
											disabled={locked}
											onChange={(answer) => setCeilings({ ...ceilings, editCeiling: answer })}
										/>
										<CeilingQuestion
											label={text.issueAccess}
											noneSaid={text.issueNoneSaid}
											answer={ceilings.issueCeiling}
											permissions={permissions}
											available={source.powers.issueCeiling?.permissions}
											disabled={locked}
											onChange={(answer) => setCeilings({ ...ceilings, issueCeiling: answer })}
										/>
									</>
								)}
							</div>
						</details>
					</form>
				)}
			{issue?.phase === "uncertain" && <Said kind="warning">{text.missingIssue}</Said>}
			{issue?.phase === "conflict" && <Said kind="warning">{text.conflictIssue}</Said>}
			{issue == null && (delegable
				? <p className="hint">{text.issuancePolicy}</p>
				: <Said kind="warning">{text.noDelegation}</Said>)}
			{reason && <Said kind="failure">{reason}</Said>}
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
					: issue?.phase === "conflict"
					? (
						<Button
							key="review"
							size="large"
							busy={busy}
							disabled={busy}
							onClick={() =>
								void act(async () => {
									management.finishIssue();
									await management.refresh(source);
								})}
						>
							{text.reviewIssuer}
						</Button>
					)
					: issue?.phase === "uncertain"
					? (
						<Button
							key="recover"
							size="large"
							busy={busy}
							disabled={busy}
							onClick={() => void submit()}
						>
							{text.recoverIssue}
						</Button>
					)
					: issue == null && (
						<Button
							key="create"
							type="submit"
							form="sessionIssueForm"
							size="large"
							busy={busy}
							disabled={busy || permissionRefusal(permissions) !== "" ||
								new TextEncoder().encode(label).length > 120 || !Number.isInteger(depth) || depth < 0}
						>
							{text.create}
						</Button>
					)}
			</div>
		</Submodal>
	);
}
