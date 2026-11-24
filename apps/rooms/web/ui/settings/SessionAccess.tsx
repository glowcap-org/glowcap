// Session access: the management controls this viewer holds, each a row with
// the doors it opens. Issuing access, holding a pasted control, and managing
// one control each take a card of their own.
import { managedAccessText as text, permissionLine } from "../../../lib/text/managed_access.ts";
import { useEffect, useState, useSyncExternalStore } from "react";
import { useManagedSession } from "../session/managed/context.tsx";
import {
	controlName,
	described,
	type HeldControl,
	knownPermissions,
	knownStatus,
	OWN_CONTROL,
	publishesHere,
	saved,
} from "../session/managed/held_control.ts";
import { rowOffers } from "../session/managed/access_row.ts";
import { cardSubject, holdPress, rowPressed, type RowRefusals, rowRefused } from "../session/managed/access_card.ts";
import { sessionTryNow } from "../../../lib/text/page.ts";
import { permissionSummary } from "./PermissionFields.tsx";
import { Button } from "../Button.tsx";
import { Field } from "../Field.tsx";
import { addressField } from "../field.ts";
import { Said } from "../Said.tsx";
import { Submodal } from "../Submodal.tsx";
import { AccessStatusTag } from "./AccessStatusTag.tsx";
import { SessionGrantEditModal } from "./SessionGrantEdit.tsx";
import { SessionIssueModal } from "./SessionIssue.tsx";
import { LocalRefusal } from "../../../lib/text/failure.ts";
import { sturdyrefPlaceholder } from "../../../lib/text/controls.ts";
import { useChangeGroup, useCommitments } from "../commitment.tsx";
import { useOpenModal } from "../modal.ts";
import { useServerGate } from "../hooks.ts";
import { linkNeedsServer } from "../application.ts";
import { serverNeedAddress, serverNeedLink } from "../../../lib/text/session.ts";
import { useAsyncAction } from "../async_action.ts";
import { Input } from "../Input.tsx";

/** The row's one-line account of what its access allows, when this viewer knows. */
const rowSaid = (control: HeldControl): string | null =>
	control.id === OWN_CONTROL
		? text.ownSaid
		: knownStatus(control) === "revoked"
		? text.endedSaid
		: (described(control) && control.state.grant != null) || control.committed?.permissions != null
		? permissionLine(permissionSummary(knownPermissions(control)))
		: null;

/** A card opened on a held access names the access by its row's id, so each
 * draw shows the access the owner holds there now. */
type HeldDoor = { readonly kind: "manage" | "issue"; readonly id: string };
type Door = HeldDoor | { readonly kind: "hold" };
/** What a press opens: a card on the access `control` holds, or the Hold card. */
type Opening = { readonly kind: "manage" | "issue"; readonly control: HeldControl } | { readonly kind: "hold" };
/** A row gesture, run against the control it names. */
type RowAction = { readonly busy: boolean; run(control: HeldControl): Promise<unknown> };

export function SessionAccessModal({ open, onClose }: { open: boolean; onClose(): void }) {
	const { management } = useManagedSession();
	useSyncExternalStore(management.subscribe, management.getVersion, management.getVersion);
	const openModalFrom = useOpenModal();
	const serverGate = useServerGate();
	// Which row the running save or removal belongs to.
	const [acting, setActing] = useState<string | null>(null);
	// Each row's last refused press, which its row shows by the rule
	// `rowRefused` keeps.
	const [refusals, setRefusals] = useState<RowRefusals>(new Map());
	/** Run `press` on `control`'s row through the owner, keeping its answer. A
	 * fault the owner reported ends the row's action, which leaves it usable. */
	const pressOn = async (signal: AbortSignal, control: HeldControl, press: () => Promise<unknown>) => {
		setActing(control.id);
		setRefusals((prior) => rowPressed(prior, management, control, null));
		const refusal = await management.answer(control, press);
		if (!signal.aborted) setRefusals((prior) => rowPressed(prior, management, control, refusal));
	};
	const saveAction = useAsyncAction((signal, control: HeldControl) =>
		pressOn(signal, control, () => management.save(control))
	);
	// A revoked access has nothing left to manage, so its row offers removal
	// in place of the card; removing loses nothing, so it asks nothing.
	const removeAction = useAsyncAction((signal, control: HeldControl) =>
		pressOn(signal, control, () => management.forget(control))
	);
	// An access the page's link could not reach is reached again on request.
	const reachAction = useAsyncAction((signal, control: HeldControl) =>
		pressOn(signal, control, () => management.reachAgain(control))
	);
	const rowBusy = saveAction.busy || removeAction.busy || reachAction.busy;
	// Which card is up, kept apart from whether it is open so a closing card
	// keeps its subject while it leaves. Each opening is a fresh card.
	const [door, setDoor] = useState<Door | null>(null);
	const [doorOpen, setDoorOpen] = useState(false);
	const [opening, setOpening] = useState(0);
	const go = (event: { currentTarget: HTMLElement }, next: Opening) => {
		// A new access that leads here works through this browser's Rooms
		// server, so the server comes first. A pasted management link is
		// judged by its own doors once it is pasted.
		if (next.kind === "issue" && publishesHere(next.control) && serverGate(serverNeedLink) == null) return;
		openModalFrom(event.currentTarget, () => {
			setDoor(next.kind === "hold" ? next : { kind: next.kind, id: next.control.id });
			setOpening((value) => value + 1);
			setDoorOpen(true);
		});
	};
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
						<AccessRow
							key={control.id}
							control={control}
							refused={rowRefused(refusals, management, control)}
							acting={acting === control.id}
							rowBusy={rowBusy}
							reach={reachAction}
							save={saveAction}
							remove={removeAction}
							go={go}
						/>
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
			</div>
			{door != null && door.kind !== "hold" && (
				<HeldCard
					key={opening}
					door={door}
					open={doorOpen}
					onClose={close}
					onGone={() => {
						setDoor(null);
						setDoorOpen(false);
					}}
				/>
			)}
			{door?.kind === "hold" && <HoldControlModal key={opening} open={doorOpen} onClose={close} />}
		</Submodal>
	);
}

/** The card `door` opened, over the access `cardSubject` finds held under its
 * id at this draw. One the owner let go of, or that no longer describes its
 * access, draws nothing and closes its door. */
export function HeldCard({ door, open, onClose, onGone }: {
	door: HeldDoor;
	open: boolean;
	onClose(): void;
	/** Closes the door once its access is gone. */
	onGone(): void;
}) {
	const { management } = useManagedSession();
	const control = cardSubject(management, door.id);
	const gone = control == null;
	useEffect(() => {
		if (gone) onGone();
	}, [gone]);
	if (control == null) return null;
	return door.kind === "manage"
		? <SessionGrantEditModal control={control} open={open} onClose={onClose} />
		: <SessionIssueModal control={control} open={open} onClose={onClose} />;
}

/** One held control and the buttons that can work on it now. */
function AccessRow({ control, refused, acting, rowBusy, reach, save, remove, go }: {
	control: HeldControl;
	/** The answer to a press on this row that was refused. */
	refused: string | null;
	/** Whether the row gesture under way is this row's. */
	acting: boolean;
	rowBusy: boolean;
	reach: RowAction;
	save: RowAction;
	remove: RowAction;
	go(event: { currentTarget: HTMLElement }, opening: Opening): void;
}) {
	const { management } = useManagedSession();
	const offers = rowOffers(management, control);
	const { manage, share } = offers;
	const hint = rowSaid(control);
	return (
		<li className="entry">
			<div className="entry-head" data-one-line>
				<span className="entry-name">{controlName(control, text)}</span>
				<AccessStatusTag status={knownStatus(control)} />
				{!saved(control) && <span className="tag" data-tone="warn">{text.notSaved}</span>}
				<div className="actions">
					{offers.tryNow && (
						<Button
							variant="quiet"
							busy={reach.busy && acting}
							disabled={rowBusy}
							onClick={() => void reach.run(control)}
						>
							{sessionTryNow}
						</Button>
					)}
					{offers.save && (
						<Button
							variant="quiet"
							busy={save.busy && acting}
							disabled={rowBusy}
							onClick={() => void save.run(control)}
						>
							{text.saveControl}
						</Button>
					)}
					{manage != null
						? (
							<Button
								key="manage"
								variant="quiet"
								onClick={(event) => go(event, { kind: "manage", control: manage })}
							>
								{text.manage}
							</Button>
						)
						: offers.remove && (
							<Button
								key="remove"
								variant="quiet"
								busy={remove.busy && acting}
								disabled={rowBusy}
								onClick={() => void remove.run(control)}
							>
								{text.remove}
							</Button>
						)}
					{share != null && (
						<Button onClick={(event) => go(event, { kind: "issue", control: share.control })}>
							{share.kind === "resume" ? text.issuePendingAsk : text.issueAsk}
						</Button>
					)}
				</div>
			</div>
			{offers.failure != null && <Said kind="failure">{offers.failure}</Said>}
			{refused != null && <Said kind="failure">{refused}</Said>}
			{hint != null && <p className="hint">{hint}</p>}
		</li>
	);
}

/** A pasted management control, held and saved on a card of its own. */
function HoldControlModal({ open, onClose }: { open: boolean; onClose(): void }) {
	const { management } = useManagedSession();
	const serverGate = useServerGate();
	const commitments = useCommitments();
	const [uri, setUri] = useState("");
	const [busy, setBusy] = useState(false);
	const [why, setWhy] = useState("");
	const group = "settings-session-hold";
	useChangeGroup(group, {
		dirty: uri !== "",
		discard: () => {
			if (busy) throw new LocalRefusal("settings-access-holding");
			setUri("");
			setWhy("");
		},
	});
	const hold = async () => {
		// The control is reached at the address its link names, so one this
		// browser cannot open on its own needs the Rooms server first.
		if (linkNeedsServer(uri.trim()) && serverGate(serverNeedAddress) == null) return;
		setBusy(true);
		setWhy("");
		try {
			// The answer stands until the person edits the link it answered.
			const failure = await holdPress(management, crypto.randomUUID(), uri);
			if (failure != null) {
				setWhy(failure);
				return;
			}
			setUri("");
			onClose();
		} catch {
			// tolerant: the owner reported the fault, and the card stays usable.
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
						<Input
							id={wiring.id}
							{...addressField}
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
