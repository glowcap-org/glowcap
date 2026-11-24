// The rows of a held control's Manage card. Each reads what the card offers
// and the edit's answer from `access_card.ts`, and presses through the card.
import type { ReactNode } from "react";
import { currentLabel, currentPermissions, managedAccessText as text } from "../../../lib/text/managed_access.ts";
import type { CardOffers } from "../session/managed/access_card.ts";
import { grantIdentity, type GrantView } from "../session/managed/access_powers.ts";
import type { EditIntent } from "../session/managed/edit_state.ts";
import { type DescribedControl, knownLabel, knownPermissions, OWN_CONTROL } from "../session/managed/held_control.ts";
import { LocalRefusal, refusalText } from "../../../lib/text/failure.ts";
import { sessionTryNow } from "../../../lib/text/page.ts";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { Field } from "../Field.tsx";
import { Input } from "../Input.tsx";
import { Said } from "../Said.tsx";
import { Switch } from "../Switch.tsx";
import { AccessStatusTag } from "./AccessStatusTag.tsx";
import { permissionSummary } from "./PermissionFields.tsx";

/** Which press is running, so only that control turns busy while the rest of
 * the card waits on the one edit a control can hold. */
export type Running = EditIntent["kind"] | "recover" | "reapply" | "discard" | "reach";
/** What every row reads of the card. */
export interface RowProps {
	readonly control: DescribedControl;
	readonly offers: CardOffers;
	readonly running: Running | null;
	/** Whether the card takes no new change now. */
	readonly locked: boolean;
}

/** What the card says of the edit to `on`, beside that setting, with the way
 * on while the edit waits. */
export function EditAnswer({ control, offers, running, on, act }: RowProps & {
	on: EditIntent["kind"];
	act: { discard(): void; reapply(): void; checkAgain(): void };
}) {
	const answer = offers.answer;
	if (answer?.kind !== on) return null;
	if (!answer.open) return <Said kind={answer.tone}>{answer.said}</Said>;
	const conflict = offers.edit?.phase === "conflict" && control.state.grant != null;
	const busy = running != null;
	return (
		<div className="group session-edit-recovery">
			<Said kind="warning">{answer.said}</Said>
			{conflict && on === "label" && <p className="hint">{currentLabel(knownLabel(control))}</p>}
			{conflict && on === "policy" && (
				<p className="hint">{currentPermissions(permissionSummary(knownPermissions(control)))}</p>
			)}
			<div className="actions">
				{offers.discard && (
					<Button busy={running === "discard"} disabled={busy} variant="quiet" onClick={act.discard}>
						{text.discard}
					</Button>
				)}
				{offers.reapply && (
					<Button busy={running === "reapply"} disabled={busy} onClick={act.reapply}>{text.reapply}</Button>
				)}
				{offers.checkAgain && (
					<Button busy={running === "recover"} disabled={busy} onClick={act.checkAgain}>
						{text.recoverEdit}
					</Button>
				)}
			</div>
		</div>
	);
}

export function LabelRow({ control, running, locked, ended, label, setLabel, save, answer }: RowProps & {
	ended: boolean;
	label: string;
	setLabel(label: string): void;
	save(): void;
	answer: ReactNode;
}) {
	const editable = control.state.powers.editCeiling != null;
	return (
		<li className="entry">
			{ended ? <span className="entry-name">{text.label}</span> : (
				<form
					className="field-row"
					onSubmit={(event) => {
						event.preventDefault();
						save();
					}}
				>
					<Field id="sessionGrantLabel" label={text.label}>
						{(wiring) => (
							<Input
								id={wiring.id}
								value={label}
								maxLength={120}
								placeholder={control.id === OWN_CONTROL ? text.ownControl : text.labelPlaceholder}
								disabled={locked || !editable}
								onChange={(event) => setLabel(event.currentTarget.value)}
							/>
						)}
					</Field>
					<Button
						type="submit"
						variant="quiet"
						size="large"
						busy={running === "label"}
						disabled={locked || !editable || label === knownLabel(control)}
					>
						{text.saveLabel}
					</Button>
				</form>
			)}
			{answer}
		</li>
	);
}

/** Whether the access is on, and the switch that pauses or resumes it. */
export function ActiveRow({ control, running, locked, status, press, answers }: RowProps & {
	status: GrantView["status"] | undefined;
	press(intent: EditIntent): void;
	answers: ReactNode;
}) {
	const powers = control.state.powers;
	if (status === "revoked") {
		return (
			<li className="entry">
				<div className="entry-head" data-one-line>
					<span className="entry-name">{text.statusLabel}</span>
					<AccessStatusTag status="revoked" />
				</div>
				{answers}
			</li>
		);
	}
	const active = status === "active";
	return (
		<li className="entry">
			<div className="switch-row">
				<span className="entry-name" id="sessionGrantActiveLabel">{text.activeLabel}</span>
				<Switch
					id="sessionGrantActive"
					checked={active}
					label={text.activeLabel}
					aria-labelledby="sessionGrantActiveLabel"
					busy={running === "pause" || running === "resume"}
					disabled={locked || !(active ? powers.pause : powers.resume)}
					onClick={() => press({ kind: active ? "pause" : "resume" })}
				/>
			</div>
			<p className="hint">{active ? text.activeSaid : text.pausedNowSaid}</p>
			{answers}
		</li>
	);
}

export function RevokeRow({ running, locked, asking, setAsking, press, answer }: RowProps & {
	asking: boolean;
	setAsking(asking: boolean): void;
	press(intent: EditIntent): void;
	answer: ReactNode;
}) {
	return (
		<li className="entry">
			{asking
				? (
					<Confirm
						label={text.revokeConfirm}
						say={text.revokeSaid}
						keep={text.keep}
						commit={text.revoke}
						busy={running === "revoke"}
						onKeep={() => setAsking(false)}
						onCommit={() => press({ kind: "revoke" })}
					/>
				)
				: (
					<>
						<div className="entry-head" data-one-line>
							<span className="entry-name">{text.revokeRow}</span>
							<div className="actions">
								<Button variant="quiet" disabled={locked} onClick={() => setAsking(true)}>
									{text.revokeAsk}
								</Button>
							</div>
						</div>
						<p className="hint">{text.revokeRowSaid}</p>
					</>
				)}
			{answer}
		</li>
	);
}

/** Removing the access from this browser's list. One with nothing left to
 * manage goes at once, and any other asks first. One whose last change was
 * sent and never answered says that removing stops checking it. */
export function RemoveRow({ offers, running, ended, asking, setAsking, remove }: RowProps & {
	ended: boolean;
	asking: boolean;
	setAsking(asking: boolean): void;
	remove: { busy: boolean; run(): void };
}) {
	const removal = offers.removal;
	const say = offers.removeUnconfirmed ? `${text.removeUnconfirmedSaid} ${text.removeSaid}` : text.removeSaid;
	return (
		<li className="entry">
			{asking && !ended
				? (
					<Confirm
						label={text.removeConfirm}
						say={say}
						keep={text.keep}
						commit={text.remove}
						busy={remove.busy}
						onKeep={() => setAsking(false)}
						onCommit={remove.run}
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
									disabled={running != null || remove.busy || !offers.remove}
									aria-describedby={removal != null ? "sessionGrantRemoval" : undefined}
									onClick={() => ended ? remove.run() : setAsking(true)}
								>
									{ended ? text.remove : text.removeAsk}
								</Button>
							</div>
						</div>
						{removal != null
							? <p className="hint" id="sessionGrantRemoval">{refusalText(new LocalRefusal(removal))}</p>
							: <p className="hint">{ended ? text.endedSaid : text.removeRowSaid}</p>}
					</>
				)}
		</li>
	);
}

/** The accesses made from this one, a page at a time. An empty list has
 * nothing to manage, so the section appears once it has rows. A first page
 * that did not land offers Try now (`listingAgain`). */
export function DescendantsSection({ descendants, inspect }: {
	descendants: { rows: GrantView[]; cursor: Uint8Array | null } | null;
	inspect: { busy: boolean; refused: string | null; again: boolean; run(cursor?: Uint8Array): void };
}) {
	if (descendants != null && descendants.rows.length === 0) return null;
	const more = descendants?.cursor ?? null;
	return (
		<>
			<h3 className="well-title overline" id="sessionGrantDescendantsTitle">{text.descendantsTitle}</h3>
			<div className="group well" role="group" aria-labelledby="sessionGrantDescendantsTitle">
				{descendants == null
					? inspect.busy && <p className="empty">{text.loadingDescendants}</p>
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
				{more != null && (
					<div className="actions">
						<Button
							variant="quiet"
							busy={inspect.busy}
							disabled={inspect.busy}
							onClick={() => inspect.run(more)}
						>
							{text.more}
						</Button>
					</div>
				)}
				{inspect.refused != null && <Said kind="failure">{inspect.refused}</Said>}
				{inspect.again && (
					<div className="actions">
						<Button
							variant="quiet"
							busy={inspect.busy}
							disabled={inspect.busy}
							onClick={() => inspect.run()}
						>
							{sessionTryNow}
						</Button>
					</div>
				)}
			</div>
		</>
	);
}
