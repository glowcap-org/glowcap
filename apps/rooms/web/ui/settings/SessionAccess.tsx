// Session access: the management controls this viewer holds, each a row with
// the doors it opens. Issuing access, holding a pasted control, and managing
// one control each take a card of their own.
import { managedAccessText as text, permissionLine } from "../../../lib/text/managed_access.ts";
import { useState, useSyncExternalStore } from "react";
import { useManagedSession } from "../session/managed/context.tsx";
import {
	controlName,
	type HeldControl,
	knownPermissions,
	knownStatus,
	OWN_CONTROL,
} from "../session/managed/access.ts";
import { permissionSummary } from "./PermissionFields.tsx";
import { Button } from "../Button.tsx";
import { Field } from "../Field.tsx";
import { identifierField } from "../field.ts";
import { Said } from "../Said.tsx";
import { Submodal } from "../Submodal.tsx";
import { AccessStatusTag } from "./AccessStatusTag.tsx";
import { SessionGrantEditModal } from "./SessionGrantEdit.tsx";
import { SessionIssueModal } from "./SessionIssue.tsx";
import { refusalText } from "../../../lib/text/failure.ts";
import { sturdyrefPlaceholder } from "../../../lib/text/controls.ts";
import { useChangeGroup, useCommitments } from "../commitment.tsx";
import { useOpenModal } from "../modal.ts";
import { useAsyncAction } from "../async_action.ts";

/** The row's one-line account of what its access allows, when this viewer knows. */
const rowSaid = (control: HeldControl): string | null =>
	control.id === OWN_CONTROL
		? text.ownSaid
		: knownStatus(control) === "revoked"
		? text.endedSaid
		: control.grant != null || control.committed?.permissions != null
		? permissionLine(permissionSummary(knownPermissions(control)))
		: null;

type Door = { kind: "manage" | "issue"; control: HeldControl } | { kind: "hold" };

export function SessionAccessModal({ open, onClose }: { open: boolean; onClose(): void }) {
	const { management } = useManagedSession();
	useSyncExternalStore(management.subscribe, management.getVersion, management.getVersion);
	const openModalFrom = useOpenModal();
	// Which row the running save or removal belongs to.
	const [acting, setActing] = useState<string | null>(null);
	const saveAction = useAsyncAction(async (_signal, control: HeldControl) => {
		setActing(control.id);
		await management.save(control);
	});
	// A revoked access has nothing left to manage, so its row offers removal
	// in place of the card; removing loses nothing, so it asks nothing.
	const removeAction = useAsyncAction(async (_signal, control: HeldControl) => {
		setActing(control.id);
		await management.forget(control);
	});
	const rowBusy = saveAction.busy || removeAction.busy;
	// Which card is up, kept apart from whether it is open so a closing card
	// keeps its subject while it leaves. Each opening is a fresh card.
	const [door, setDoor] = useState<Door | null>(null);
	const [doorOpen, setDoorOpen] = useState(false);
	const [opening, setOpening] = useState(0);
	const pending = management.issue;
	const go = (event: { currentTarget: HTMLElement }, next: Door) =>
		openModalFrom(event.currentTarget, () => {
			setDoor(next);
			setOpening((value) => value + 1);
			setDoorOpen(true);
		});
	const close = () => setDoorOpen(false);
	return (
		<Submodal
			title={text.title}
			titleId="sessionAccessTitle"
			className="session-access-modal"
			open={open}
			onClose={onClose}
		>
			<p className="lead">{text.sharingLead}</p>
			<h3 className="well-title overline" id="sessionControlsTitle">{text.heldTitle}</h3>
			<div className="group well" role="group" aria-labelledby="sessionControlsTitle">
				{management.held.length === 0 && <p className="empty">{text.noControl}</p>}
				<ul className="entries">
					{management.held.map((control) => (
						<li className="entry" key={control.id}>
							<div className="entry-head" data-one-line>
								<span className="entry-name">{controlName(control, text)}</span>
								<AccessStatusTag status={knownStatus(control)} />
								{!control.saved && <span className="tag" data-tone="warn">{text.notSaved}</span>}
								<div className="actions">
									{!control.saved && (
										<Button
											variant="quiet"
											busy={saveAction.busy && acting === control.id}
											disabled={rowBusy}
											onClick={() => void saveAction.run(control)}
										>
											{text.saveControl}
										</Button>
									)}
									{knownStatus(control) === "revoked" && control.id !== OWN_CONTROL
										? (
											<Button
												key="remove"
												variant="quiet"
												busy={removeAction.busy && acting === control.id}
												disabled={rowBusy}
												onClick={() => void removeAction.run(control)}
											>
												{text.remove}
											</Button>
										)
										: (
											<Button
												key="manage"
												variant="quiet"
												onClick={(event) => go(event, { kind: "manage", control })}
											>
												{text.manage}
											</Button>
										)}
									{control.powers.issueCeiling != null && (
										<Button onClick={(event) => go(event, { kind: "issue", control })}>
											{pending?.source === control ? text.issuePendingAsk : text.issueAsk}
										</Button>
									)}
								</div>
							</div>
							{rowSaid(control) != null && <p className="hint">{rowSaid(control)}</p>}
						</li>
					))}
					<li className="entry">
						<div className="entry-head" data-one-line>
							<span className="entry-name">{text.holdRow}</span>
							<div className="actions">
								<Button
									id="sessionHoldOpen"
									variant="quiet"
									onClick={(event) => go(event, { kind: "hold" })}
								>
									{text.holdAsk}
								</Button>
							</div>
						</div>
					</li>
				</ul>
				{saveAction.why && <Said kind="failure">{saveAction.why}</Said>}
				{removeAction.why && <Said kind="failure">{removeAction.why}</Said>}
			</div>
			{door?.kind === "manage" && (
				<SessionGrantEditModal
					key={opening}
					control={door.control}
					open={doorOpen}
					onClose={close}
				/>
			)}
			{door?.kind === "issue" && (
				<SessionIssueModal key={opening} control={door.control} open={doorOpen} onClose={close} />
			)}
			{door?.kind === "hold" && <HoldControlModal key={opening} open={doorOpen} onClose={close} />}
		</Submodal>
	);
}

/** A pasted management control, held and saved on a card of its own. */
function HoldControlModal({ open, onClose }: { open: boolean; onClose(): void }) {
	const { management } = useManagedSession();
	const commitments = useCommitments();
	const [uri, setUri] = useState("");
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	const group = "settings-session-hold";
	useChangeGroup(group, {
		dirty: uri !== "",
		discard: () => {
			if (busy) throw new Error("Wait for the control to finish being held.");
			setUri("");
			setWhy("");
		},
	});
	const hold = async () => {
		setBusy(true);
		setWhy("");
		try {
			const held = await management.attach(crypto.randomUUID(), uri);
			await management.save(held);
			setUri("");
			onClose();
		} catch (error) {
			setWhy(refusalText(error));
		} finally {
			setBusy(false);
		}
	};
	return (
		<Submodal
			title={text.holdTitle}
			titleId="sessionHoldTitle"
			className="session-hold-modal"
			open={open}
			onClose={() => commitments.request(onClose, { only: [group] })}
		>
			<p className="lead">{text.holdLead}</p>
			<form
				className="group well"
				onSubmit={(event) => {
					event.preventDefault();
					void hold();
				}}
			>
				<Field id="sessionControlUri" label={text.controlLink} hint={text.controlLinkHint} said={why}>
					{(wiring) => (
						<input
							id={wiring.id}
							className="field"
							type="text"
							{...identifierField}
							value={uri}
							disabled={busy}
							placeholder={sturdyrefPlaceholder}
							aria-describedby={wiring.describedBy}
							aria-invalid={wiring.invalid}
							onChange={(event) => {
								setUri(event.currentTarget.value);
								setWhy("");
							}}
						/>
					)}
				</Field>
				<div className="actions" data-fill>
					<Button type="submit" size="large" busy={busy} disabled={busy || uri.trim() === ""}>
						{text.holdControl}
					</Button>
				</div>
			</form>
		</Submodal>
	);
}
