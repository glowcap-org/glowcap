// Drafts and retained requests belong to one actual held control. The card
// shows the control's edit as it stands now, whoever moved it last, and offers
// what `access_card.ts` says can work. Every answer it shows derives from the
// access owner's state, and its rows are `SessionGrantRows.tsx`'s.
import { managedAccessText as text } from "../../../lib/text/managed_access.ts";
import { useEffect, useState } from "react";
import type { EditIntent, EditState } from "../session/managed/edit_state.ts";
import {
	controlName,
	type DescribedControl,
	knownLabel,
	knownPermissions,
	OWN_CONTROL,
} from "../session/managed/held_control.ts";
import {
	askListing,
	cardGestures,
	cardOffers,
	listingAgain,
	type ListingAnswer,
	listingAsk,
	pressRefused,
} from "../session/managed/access_card.ts";
import type { PressRefusal } from "../session/managed/press_answer.ts";
import type { GrantView } from "../session/managed/access_powers.ts";
import type { RoomsPermission } from "../../../lib/session_content_data.ts";
import { useManagedSession } from "../session/managed/context.tsx";
import { Button } from "../Button.tsx";
import { Said } from "../Said.tsx";
import { Submodal } from "../Submodal.tsx";
import { PermissionFields, permissionRefusal } from "./PermissionFields.tsx";
import { ShareControl } from "./ShareControl.tsx";
import { LocalRefusal } from "../../../lib/text/failure.ts";
import { useChangeGroup, useCommitments, useCommitSettling } from "../commitment.tsx";
import { useAsyncAction } from "../async_action.ts";
import { sessionTryNow } from "../../../lib/text/page.ts";
import {
	ActiveRow,
	DescendantsSection,
	EditAnswer,
	LabelRow,
	RemoveRow,
	RevokeRow,
	type RowProps,
	type Running,
} from "./SessionGrantRows.tsx";

export function SessionGrantEditModal({ control, open, onClose }: {
	control: DescribedControl;
	open: boolean;
	onClose(): void;
}) {
	const { management } = useManagedSession();
	const commitments = useCommitments();
	const commit = useCommitSettling();
	// The edit as the card found it, so one that ends later shows how it ended.
	const [opened, setOpened] = useState<EditState | undefined>(control.edit);
	useEffect(() => {
		if (open) setOpened(control.edit);
	}, [open]);
	const offers = cardOffers(management, control, opened);
	const gestures = cardGestures(management, control);
	const draft = offers.edit?.intent;
	const [permissions, setPermissions] = useState<RoomsPermission[]>(
		draft?.kind === "policy" ? draft.permissions : [...knownPermissions(control)],
	);
	const [label, setLabel] = useState(draft?.kind === "label" ? draft.label : knownLabel(control));
	const [running, setRunning] = useState<Running | null>(null);
	const busy = running != null;
	// The last refused press, which the card shows by the rule `pressRefused`
	// keeps.
	const [refusal, setRefusal] = useState<PressRefusal | null>(null);
	const [revoke, setRevoke] = useState(false);
	const [removing, setRemoving] = useState(false);
	const [removed, setRemoved] = useState(false);
	const [descendants, setDescendants] = useState<{ rows: GrantView[]; cursor: Uint8Array | null } | null>(null);
	const own = control.id === OWN_CONTROL;
	// A control that describes nothing has had its access, or one above it,
	// revoked, and only removing it from the list is left.
	const powers = control.state.powers;
	const ended = !powers.available;
	const status = ended ? "revoked" : powers.status ?? control.state.grant?.status;
	// Measured against what this viewer knows the access to have, which a
	// committed edit updates even when the control cannot inspect.
	const known = knownPermissions(control);
	const permissionsChanged = permissions.length !== known.length ||
		permissions.some((value) => !known.includes(value));
	// How the listing's last ask ended. A refused page shows by the rule
	// `pressRefused` keeps.
	const [listing, setListing] = useState<ListingAnswer | null>(null);
	const inspect = useAsyncAction(async (signal, cursor?: Uint8Array) => {
		setListing(null);
		const answer = await askListing(management, control, cursor);
		if (signal.aborted) return;
		setListing(answer);
		if (answer.kind !== "page") return;
		setDescendants((prior) => ({
			rows: cursor == null ? answer.rows : [...(prior?.rows ?? []), ...answer.rows],
			cursor: answer.cursor,
		}));
	});
	// The first page is asked for when the card opens, and again at each reach
	// of the access before a page lands, as `listingAsk` says.
	const ask = open ? listingAsk(control, offers, descendants != null) : null;
	useEffect(() => {
		if (ask != null) void inspect.run();
	}, [ask]);
	// The card's subject leaves with the row, so a draft has nothing left to
	// save. A refusal is the card's one refused press.
	const remove = useAsyncAction(async (signal) => {
		setRefusal(null);
		const refusal = await management.answer(control, gestures.remove);
		if (signal.aborted) return;
		if (refusal != null) {
			setRefusal(refusal);
			return;
		}
		setRemoved(true);
		onClose();
	});
	const locked = busy || !offers.inputs;
	const group = `session-control-${control.id}`;
	useChangeGroup(group, {
		// A draft counts only while the card takes it. A sent edit waits on the
		// session, so closing the card leaves it to end on its own.
		dirty: !removed &&
			(offers.discard || (offers.inputs && (label !== knownLabel(control) || permissionsChanged))),
		discard: async () => {
			if (busy) throw new LocalRefusal("access-edit-submitting");
			await gestures.close(offers);
			setPermissions([...knownPermissions(control)]);
			setLabel(knownLabel(control));
		},
		settling: commit.current,
	});
	/** Run `gesture` as `on` through the owner. Its outcome lands in the
	 * owner's state, which the card reads, and its refusal is the card's answer. */
	const run = async (on: Running, gesture: () => Promise<unknown>) => {
		if (busy) return;
		setRunning(on);
		setRefusal(null);
		try {
			setRefusal(await management.answer(control, gesture));
		} catch {
			// tolerant: the owner reported the fault, and the card stays usable.
		} finally {
			setRunning(null);
		}
	};
	const press = (intent: EditIntent) =>
		void run(intent.kind, async () => {
			commit.begin();
			try {
				const result = await gestures.press(intent, offers.base);
				if (result.phase !== "ended" || result.outcome !== "committed") return;
				setRevoke(false);
				// A revoked access keeps its record, named and marked revoked, under
				// the access it was created from. Its row here has nothing left to
				// manage, so it leaves the list, and a failed removal leaves the
				// ended card offering Remove.
				if (intent.kind === "revoke" && !own) void remove.run();
			} finally {
				commit.finish();
			}
		});
	const act = {
		discard: () =>
			void run("discard", async () => {
				await gestures.discard();
				setPermissions([...knownPermissions(control)]);
				setLabel(knownLabel(control));
			}),
		reapply: () => void run("reapply", () => gestures.reapply()),
		checkAgain: () => void run("recover", () => gestures.checkAgain()),
	};
	const refused = pressRefused(refusal, management, control);
	const rows: RowProps = { control, offers, running, locked };
	const answer = (on: EditIntent["kind"]) => <EditAnswer {...rows} on={on} act={act} />;
	const answers = (...on: EditIntent["kind"][]) => offers.answer != null && on.includes(offers.answer.kind);
	const powerless = powers.available && !powers.inspect && !powers.pause && !powers.resume && !powers.revoke &&
		powers.editCeiling == null && !powers.delegateControl;
	return (
		<Submodal
			title={controlName(control, text)}
			titleId="sessionGrantEditTitle"
			className="session-grant-edit-modal"
			open={open}
			onClose={() => commitments.request(onClose, { only: [group] })}
		>
			<p className="lead">{own ? text.ownEditLead : ended ? text.endedLead : text.editLead}</p>
			{offers.failure != null && (
				<div className="group session-edit-recovery">
					<Said kind="failure">{offers.failure}</Said>
					{offers.tryNow && (
						<div className="actions">
							<Button
								busy={running === "reach"}
								disabled={busy}
								onClick={() => void run("reach", gestures.tryNow)}
							>
								{sessionTryNow}
							</Button>
						</div>
					)}
				</div>
			)}
			{powerless && <Said kind="warning">{text.powerless}</Said>}
			{!powerless && control.state.grant == null && powers.available && (
				<p className="hint">{text.uninspectable}</p>
			)}
			<div className="group well">
				<ul className="entries option-rows">
					{(!ended || answers("label")) && (
						<LabelRow
							{...rows}
							ended={ended}
							label={label}
							setLabel={setLabel}
							save={() => press({ kind: "label", label })}
							answer={answer("label")}
						/>
					)}
					{!own && (
						<ActiveRow
							{...rows}
							status={status}
							press={press}
							answers={
								<>
									{answer("pause")}
									{answer("resume")}
									{status === "revoked" && answer("revoke")}
								</>
							}
						/>
					)}
					{!own && (powers.revoke || answers("revoke")) && status !== "revoked" && (
						<RevokeRow
							{...rows}
							asking={revoke}
							setAsking={setRevoke}
							press={press}
							answer={answer("revoke")}
						/>
					)}
					{!own && (
						<RemoveRow
							{...rows}
							ended={ended}
							asking={removing}
							setAsking={setRemoving}
							remove={{ busy: remove.busy, run: () => void remove.run() }}
						/>
					)}
				</ul>
				{control.state.grant != null && control.state.grant.status !== control.state.grant.effectiveStatus && (
					<Said kind="warning">{text.ancestor}</Said>
				)}
				{refused != null && <Said kind="failure">{refused}</Said>}
			</div>
			{(control.state.grant != null || answers("policy")) && (
				<form
					className="session-grant-permissions"
					onSubmit={(event) => {
						event.preventDefault();
						press({ kind: "policy", permissions });
					}}
				>
					<h3 className="well-title overline" id="sessionGrantPermissionsTitle">{text.permissionsTitle}</h3>
					<div className="group well" role="group" aria-labelledby="sessionGrantPermissionsTitle">
						<PermissionFields
							value={permissions}
							ceiling={powers.editCeiling?.permissions ?? []}
							disabled={locked || powers.editCeiling == null}
							onChange={setPermissions}
						/>
						{answer("policy")}
						<div className="actions">
							<Button
								type="submit"
								busy={running === "policy"}
								disabled={locked || powers.editCeiling == null || !permissionsChanged ||
									permissionRefusal(permissions) !== ""}
							>
								{text.savePermissions}
							</Button>
						</div>
					</div>
				</form>
			)}
			{offers.inspect && (
				<DescendantsSection
					descendants={descendants}
					inspect={{
						busy: inspect.busy,
						refused: pressRefused(
							listing?.kind === "refused" ? listing.refusal : null,
							management,
							control,
						),
						again: listingAgain(offers, descendants != null, listing),
						run: (cursor) => void inspect.run(cursor),
					}}
				/>
			)}
			{offers.share && (
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
