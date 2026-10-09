// Drafts and retained requests belong to one actual held control.
import { currentPermissions, managedAccessText as text } from "../../../lib/text/managed_access.ts";
import { useEffect, useState } from "react";
import {
	controlName,
	type EditIntent,
	grantIdentity,
	type GrantView,
	type HeldControl,
	knownLabel,
	knownPermissions,
	OWN_CONTROL,
} from "../session/managed/access.ts";
import type { RoomsPermission } from "../../../lib/session_content_data.ts";
import { useManagedSession } from "../session/managed/context.tsx";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { Field } from "../Field.tsx";
import { Said } from "../Said.tsx";
import { Submodal } from "../Submodal.tsx";
import { Switch } from "../Switch.tsx";
import { PermissionFields, permissionRefusal } from "./PermissionFields.tsx";
import { AccessStatusTag } from "./AccessStatusTag.tsx";
import { ShareControl } from "./ShareControl.tsx";
import { refusalText } from "../../../lib/text/failure.ts";
import { useChangeGroup, useCommitments, useCommitSettling } from "../commitment.tsx";
import { useAsyncAction } from "../async_action.ts";

// Which press is running, so only that control turns busy while the rest of
// the card waits on the one retained edit a control can hold.
type Running = EditIntent["kind"] | "recover" | "reapply" | "discard";

export function SessionGrantEditModal({ control, open, onClose }: {
	control: HeldControl;
	open: boolean;
	onClose(): void;
}) {
	const { management } = useManagedSession();
	const commitments = useCommitments();
	const commit = useCommitSettling();
	const original = control.pending;
	const [base, setBase] = useState(original?.base ?? control.powers.revision ?? "");
	const [permissions, setPermissions] = useState<RoomsPermission[]>(
		original?.intent.kind === "policy" ? original.intent.permissions : [...knownPermissions(control)],
	);
	const [label, setLabel] = useState(
		original?.intent.kind === "label" ? original.intent.label : knownLabel(control),
	);
	const [running, setRunning] = useState<Running | null>(null);
	const busy = running != null;
	// What the last act said, kept with the act so its answer appears beside the
	// control that asked rather than at the foot of the card.
	const [outcome, setOutcome] = useState<{ on: Running; said: string; saved: boolean } | null>(
		original?.reason ? { on: original.intent.kind, said: original.reason, saved: false } : null,
	);
	const said = (on: Running) => outcome?.on === on ? outcome : null;
	const [, redraw] = useState(0);
	const [revoke, setRevoke] = useState(false);
	const [removing, setRemoving] = useState(false);
	const [removed, setRemoved] = useState(false);
	const [descendants, setDescendants] = useState<{ rows: GrantView[]; cursor: Uint8Array | null } | null>(null);
	// A control that describes nothing has had its access, or one above it,
	// revoked; only removing it from the list is left.
	const ended = !control.powers.available;
	const status = ended ? "revoked" : control.powers.status ?? control.grant?.status;
	// Measured against what this viewer knows the access to have, which a
	// committed edit updates even when the control cannot inspect.
	const known = knownPermissions(control);
	const labelChanged = label !== knownLabel(control);
	const permissionsChanged = permissions.length !== known.length ||
		permissions.some((value) => !known.includes(value));
	const inspect = useAsyncAction(async (signal, cursor?: Uint8Array) => {
		const page = await management.inventory(control, cursor);
		if (signal.aborted) return;
		setDescendants((prior) => ({
			rows: cursor == null ? page.rows : [...(prior?.rows ?? []), ...page.rows],
			cursor: page.cursor,
		}));
	});
	useEffect(() => {
		if (open && control.powers.inspect) void inspect.run();
	}, [open]);
	// The card's subject leaves with the row, so a draft has nothing left to save.
	const remove = useAsyncAction(async (signal) => {
		await management.forget(control);
		if (signal.aborted) return;
		setRemoved(true);
		onClose();
	});
	const pending = control.pending;
	const locked = busy || pending != null;
	const group = `session-control-${control.id}`;
	useChangeGroup(group, {
		// An ended access takes no edit, so only a retained request is at stake.
		dirty: !removed && (pending != null || (!ended && (labelChanged || permissionsChanged))),
		discard: () => {
			if (busy || (pending != null && pending.phase !== "conflict")) {
				throw new Error("Recover the original edit before discarding its draft.");
			}
			management.finish(control);
			setPermissions([...knownPermissions(control)]);
			setLabel(knownLabel(control));
		},
		settling: commit.current,
	});
	const refresh = async () => {
		await management.refresh(control);
		redraw((value) => value + 1);
	};
	const submit = async (intent?: EditIntent, reapply = false) => {
		if (busy) return;
		commit.begin();
		const on: Running = reapply ? "reapply" : intent?.kind ?? "recover";
		const kind: Running = intent?.kind ?? control.pending?.intent.kind ?? on;
		setRunning(on);
		setOutcome(null);
		try {
			if (reapply) await management.reapply(control);
			else if (intent != null) await management.prepare(control, intent, base);
			const result = await management.submit(control);
			setOutcome({ on: kind, said: result.reason, saved: result.phase === "committed" });
			if (result.phase === "committed") {
				management.finish(control);
				await refresh();
				setBase(control.powers.revision ?? "");
				setRevoke(false);
				// A revoked access keeps its record, named and marked revoked,
				// under the access it was created from. Its row here has nothing
				// left to manage, so it leaves the list; a failed removal leaves
				// the ended card offering Remove.
				if (kind === "revoke" && !own) void remove.run();
			} else if (result.phase === "conflict") await refresh();
		} catch (error) {
			setOutcome({ on: kind, said: refusalText(error), saved: false });
		} finally {
			setRunning(null);
			commit.finish();
			redraw((value) => value + 1);
		}
	};
	const discard = async () => {
		if (busy) return;
		setRunning("discard");
		try {
			management.finish(control);
			await refresh();
			setPermissions([...knownPermissions(control)]);
			setLabel(knownLabel(control));
			setBase(control.powers.revision ?? "");
			setOutcome(null);
		} catch (error) {
			setOutcome({ on: "discard", said: refusalText(error), saved: false });
		} finally {
			setRunning(null);
		}
	};
	const editable = control.powers.editCeiling != null;
	const powers = control.powers;
	const own = control.id === OWN_CONTROL;
	const answer = (on: Running) => {
		const row = said(on);
		// A committed revoke answers through the card's lead and status tag.
		if (row == null || (on === "revoke" && row.saved && row.said === "")) return null;
		if (row.said !== "") return <Said kind={row.saved ? "warning" : "failure"}>{row.said}</Said>;
		return row.saved ? <Said kind="success">{text.committedEdit}</Said> : null;
	};
	const powerless = powers.available && !powers.inspect && !powers.pause && !powers.resume && !powers.revoke &&
		!editable && !powers.delegateControl;
	return (
		<Submodal
			title={controlName(control, text)}
			titleId="sessionGrantEditTitle"
			className="session-grant-edit-modal"
			open={open}
			onClose={() => commitments.request(onClose, { only: [group] })}
		>
			<p className="lead">{own ? text.ownEditLead : ended ? text.endedLead : text.editLead}</p>
			{powerless && <Said kind="warning">{text.powerless}</Said>}
			{!powerless && control.grant == null && powers.available && <p className="hint">{text.uninspectable}</p>}
			<div className="group well">
				<ul className="entries option-rows">
					{/* An ended access takes no rename; the card title still names it. */}
					{!ended && (
						<li className="entry">
							<form
								className="field-row"
								onSubmit={(event) => {
									event.preventDefault();
									void submit({ kind: "label", label });
								}}
							>
								<Field id="sessionGrantLabel" label={text.label}>
									{(wiring) => (
										<input
											id={wiring.id}
											className="field"
											value={label}
											maxLength={120}
											placeholder={own ? text.ownControl : text.labelPlaceholder}
											disabled={locked || !editable}
											onChange={(event) => {
												setLabel(event.currentTarget.value);
												if (said("label") != null) setOutcome(null);
											}}
										/>
									)}
								</Field>
								<Button
									type="submit"
									variant="quiet"
									size="large"
									busy={running === "label"}
									disabled={locked || !editable || !labelChanged}
								>
									{text.saveLabel}
								</Button>
							</form>
							{answer("label")}
						</li>
					)}
					{own ? null : status === "revoked"
						? (
							<li className="entry">
								<div className="entry-head" data-one-line>
									<span className="entry-name">{text.statusLabel}</span>
									<AccessStatusTag status="revoked" />
								</div>
								{answer("revoke")}
							</li>
						)
						: (
							<li className="entry">
								<div className="switch-row">
									<span className="entry-name" id="sessionGrantActiveLabel">{text.activeLabel}</span>
									<Switch
										id="sessionGrantActive"
										checked={status === "active"}
										label={text.activeLabel}
										aria-labelledby="sessionGrantActiveLabel"
										busy={running === "pause" || running === "resume"}
										disabled={locked ||
											!(status === "active" ? control.powers.pause : control.powers.resume)}
										onClick={() => void submit({ kind: status === "active" ? "pause" : "resume" })}
									/>
								</div>
								<p className="hint">{status === "active" ? text.activeSaid : text.pausedNowSaid}</p>
								{answer("pause") ?? answer("resume")}
							</li>
						)}
					{!own && control.powers.revoke && status !== "revoked" && (
						<li className="entry">
							{revoke
								? (
									<Confirm
										label={text.revokeConfirm}
										say={text.revokeSaid}
										keep={text.keep}
										commit={text.revoke}
										busy={running === "revoke"}
										onKeep={() => setRevoke(false)}
										onCommit={() => void submit({ kind: "revoke" })}
									/>
								)
								: (
									<>
										<div className="entry-head" data-one-line>
											<span className="entry-name">{text.revokeRow}</span>
											<div className="actions">
												<Button
													variant="quiet"
													disabled={locked}
													onClick={() => setRevoke(true)}
												>
													{text.revokeAsk}
												</Button>
											</div>
										</div>
										<p className="hint">{text.revokeRowSaid}</p>
										{answer("revoke")}
									</>
								)}
						</li>
					)}
					{!own && (
						<li className="entry">
							{removing && !ended
								? (
									<Confirm
										label={text.removeConfirm}
										say={text.removeSaid}
										keep={text.keep}
										commit={text.remove}
										busy={remove.busy}
										onKeep={() => setRemoving(false)}
										onCommit={() => void remove.run()}
									/>
								)
								: (
									<>
										<div className="entry-head" data-one-line>
											<span className="entry-name">{text.removeRow}</span>
											<div className="actions">
												<Button
													key={ended ? "remove" : "ask"}
													variant="quiet"
													busy={remove.busy}
													disabled={locked || remove.busy}
													onClick={() => ended ? void remove.run() : setRemoving(true)}
												>
													{ended ? text.remove : text.removeAsk}
												</Button>
											</div>
										</div>
										<p className="hint">{ended ? text.endedSaid : text.removeRowSaid}</p>
									</>
								)}
							{remove.why !== "" && <Said kind="failure">{remove.why}</Said>}
						</li>
					)}
				</ul>
				{control.grant != null && control.grant.status !== control.grant.effectiveStatus && (
					<Said kind="warning">{text.ancestor}</Said>
				)}
			</div>
			{control.grant != null && (
				<form
					className="session-grant-permissions"
					onSubmit={(event) => {
						event.preventDefault();
						void submit({ kind: "policy", permissions });
					}}
				>
					<h3 className="well-title overline" id="sessionGrantPermissionsTitle">{text.permissionsTitle}</h3>
					<div className="group well" role="group" aria-labelledby="sessionGrantPermissionsTitle">
						<PermissionFields
							value={permissions}
							ceiling={control.powers.editCeiling?.permissions ?? []}
							disabled={locked || !editable}
							onChange={setPermissions}
						/>
						{answer("policy")}
						<div className="actions">
							<Button
								type="submit"
								busy={running === "policy"}
								disabled={locked || !editable || !permissionsChanged ||
									permissionRefusal(permissions) !== ""}
							>
								{text.savePermissions}
							</Button>
						</div>
					</div>
				</form>
			)}
			{pending?.phase === "conflict" && (
				<div className="group well">
					<Said kind="warning">{text.staleEdit}</Said>
					<p className="hint">{currentPermissions(control.grant?.configured.permissions ?? [])}</p>
					<div className="actions">
						<Button
							busy={running === "discard"}
							disabled={busy}
							variant="quiet"
							onClick={() => void discard()}
						>
							{text.discard}
						</Button>
						<Button
							busy={running === "reapply"}
							disabled={busy}
							onClick={() => void submit(undefined, true)}
						>
							{text.reapply}
						</Button>
					</div>
				</div>
			)}
			{pending?.phase === "uncertain" && (
				<div className="group well">
					<Said kind="warning">{text.missingEdit}</Said>
					<div className="actions">
						<Button busy={running === "recover"} disabled={busy} onClick={() => void submit()}>
							{text.recoverEdit}
						</Button>
					</div>
				</div>
			)}
			{answer("discard")}
			{/* An empty list has nothing to manage, so the section appears once it has rows. */}
			{control.powers.inspect && (descendants == null || descendants.rows.length !== 0) && (
				<>
					<h3 className="well-title overline" id="sessionGrantDescendantsTitle">{text.descendantsTitle}</h3>
					<div className="group well" role="group" aria-labelledby="sessionGrantDescendantsTitle">
						{descendants == null
							? inspect.why === "" && <p className="empty">{text.loadingDescendants}</p>
							: (
								<ul className="entries">
									{descendants.rows.map((row) => (
										<li className="entry" key={grantIdentity(row)}>
											<div className="entry-head" data-one-line>
												<span className="entry-name">{row.label || text.unlabelled}</span>
												<AccessStatusTag status={row.effectiveStatus} />
											</div>
										</li>
									))}
								</ul>
							)}
						{descendants != null && <p className="hint">{text.descriptive}</p>}
						{descendants?.cursor != null && (
							<div className="actions">
								<Button
									variant="quiet"
									busy={inspect.busy}
									disabled={inspect.busy}
									onClick={() => void inspect.run(descendants.cursor!)}
								>
									{text.more}
								</Button>
							</div>
						)}
						{inspect.why !== "" && <Said kind="failure">{inspect.why}</Said>}
					</div>
				</>
			)}
			{control.powers.delegateControl && (
				<>
					<h3 className="well-title overline" id="sessionGrantShareTitle">{text.shareTitle}</h3>
					<div className="group well" role="group" aria-labelledby="sessionGrantShareTitle">
						<ShareControl control={control} />
					</div>
				</>
			)}
		</Submodal>
	);
}
