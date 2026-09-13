// Focused decisions for durable session operations that stopped at a recovery
// boundary. This is application work rather than a setting: the page notice
// opens this card directly, and transient action state stays inside the card.

import { useEffect, useRef, useState } from "react";
import { Button } from "../Button.tsx";
import { Confirm } from "../Confirm.tsx";
import { ModalHead } from "../ModalHead.tsx";
import { Said } from "../Said.tsx";
import { actionRefusal } from "../error_text.ts";
import { useRoomsSession } from "../controller/session.ts";
import { useRoomsState } from "../hooks.ts";
import { useHeldModal, useModalDialog } from "../modal.ts";
import {
	recoveryAbandonAllAsk,
	recoveryAbandonedAllSay,
	recoveryAbandonedSay,
	recoveryCommittedAllSay,
	recoveryCommittedSay,
	recoveryConfirmAllLabel,
	recoveryConfirmLabel,
	recoveryDrop,
	recoveryDropAll,
	recoveryExternalHint,
	recoveryKeep,
	recoveryLead,
	recoveryMarkAllCompletedAsk,
	recoveryMarkAllDone,
	recoveryMarkCompletedAsk,
	recoveryMarkDone,
	recoveryPhaseCompleted,
	recoveryPhaseDefault,
	recoveryPhasePrepared,
	recoveryPhaseUnresolved,
	recoveryPreparedHint,
	recoveryResumeHint,
	recoveryTitle,
} from "../../../lib/text/recovery.ts";

function phaseLabel(phase: "unresolved" | "prepared" | "completed" | "applied"): string {
	if (phase === "unresolved") return recoveryPhaseUnresolved;
	if (phase === "prepared") return recoveryPhasePrepared;
	if (phase === "completed") return recoveryPhaseCompleted;
	return recoveryPhaseDefault;
}

export function SessionRecoveryModal({ open, onClose }: { open: boolean; onClose(): void }) {
	const session = useRoomsSession();
	const effects = useRoomsState((state) => state.sessionEffects);
	const dialog = useRef<HTMLDialogElement>(null);
	const close = useRef<HTMLButtonElement>(null);
	const [busy, setBusy] = useState<string | null>(null);
	const [why, setWhy] = useState<Readonly<Record<string, string>>>({});
	const [confirming, setConfirming] = useState<
		{
			id: string;
			operationIds: readonly string[];
			outcome: "committed" | "abandoned";
		} | null
	>(null);
	const { held, onExited } = useHeldModal(open);
	useModalDialog(dialog, onClose, close, open, onExited);
	useEffect(() => {
		if (open && effects.length === 0) onClose();
	}, [effects.length, onClose, open]);
	useEffect(() => {
		if (open || busy !== null) return;
		setConfirming(null);
		setWhy({});
	}, [busy, open]);

	if (!held) return null;
	const act = async (id: string, request: () => Promise<string>) => {
		setBusy(id);
		setWhy((prior) => ({ ...prior, [id]: "" }));
		try {
			const refused = await actionRefusal(request);
			if (refused !== "") setWhy((prior) => ({ ...prior, [id]: refused }));
			else setConfirming(null);
		} finally {
			setBusy(null);
		}
	};
	const abandonable = effects.filter((effect) => effect.kind === "external" || effect.phase === "prepared");
	const completable = effects.filter((effect) => effect.kind === "external");
	const bulk = async (operationIds: readonly string[], outcome: "committed" | "abandoned") => {
		setBusy("bulk");
		setWhy((prior) => ({ ...prior, bulk: "" }));
		try {
			for (const operationId of operationIds) {
				const refused = await actionRefusal(() => session.resolveSessionEffect(operationId, outcome));
				if (refused !== "") {
					setWhy((prior) => ({ ...prior, bulk: refused }));
					return;
				}
			}
			setConfirming(null);
		} finally {
			setBusy(null);
		}
	};
	const title = recoveryTitle(effects.length);
	return (
		<dialog ref={dialog} className="modal" aria-labelledby="sessionRecoveryTitle">
			<div className="modal-card card-plane session-recovery-modal">
				<div className="modal-body">
					<ModalHead
						titleId="sessionRecoveryTitle"
						title={title}
						closeRef={close}
						onClose={onClose}
					/>
					<p className="lead">
						{recoveryLead(effects.length)}
					</p>
					{effects.length > 2 &&
						(abandonable.length === effects.length || completable.length === effects.length) && (
						<div className="group well session-recovery-bulk">
							{confirming?.id === "bulk"
								? (
									<Confirm
										label={recoveryConfirmAllLabel}
										tone={confirming.outcome === "committed" ? "primary" : "danger"}
										say={confirming.outcome === "committed"
											? recoveryCommittedAllSay
											: recoveryAbandonedAllSay}
										keep={recoveryKeep}
										commit={confirming.outcome === "committed"
											? recoveryMarkAllDone
											: recoveryDropAll}
										busy={busy === "bulk"}
										onKeep={() => setConfirming(null)}
										onCommit={() => void bulk(confirming.operationIds, confirming.outcome)}
									/>
								)
								: (
									<div className="actions">
										{abandonable.length === effects.length && (
											<Button
												variant="quiet"
												disabled={busy !== null}
												onClick={() =>
													setConfirming({
														id: "bulk",
														operationIds: abandonable.map((effect) => effect.id),
														outcome: "abandoned",
													})}
											>
												{recoveryAbandonAllAsk}
											</Button>
										)}
										{completable.length === effects.length && (
											<Button
												disabled={busy !== null}
												onClick={() =>
													setConfirming({
														id: "bulk",
														operationIds: completable.map((effect) => effect.id),
														outcome: "committed",
													})}
											>
												{recoveryMarkAllCompletedAsk}
											</Button>
										)}
									</div>
								)}
							{why.bulk !== "" && why.bulk != null && <Said kind="failure">{why.bulk}</Said>}
						</div>
					)}
					<div className="group well">
						<ul className="entries" id="sessionRecoveryList">
							{effects.map((effect) => (
								<li className="entry" key={effect.id} data-phase={effect.phase}>
									<div className="entry-head">
										<span className="entry-name">{effect.subject}</span>
										<span className="entry-meta">{phaseLabel(effect.phase)}</span>
									</div>
									<p className="hint">
										{effect.kind === "external"
											? recoveryExternalHint
											: effect.phase === "prepared"
											? recoveryPreparedHint
											: recoveryResumeHint}
									</p>
									{confirming?.id === effect.id
										? (
											<Confirm
												label={recoveryConfirmLabel}
												tone={confirming.outcome === "committed" ? "primary" : "danger"}
												say={confirming.outcome === "committed"
													? recoveryCommittedSay
													: recoveryAbandonedSay}
												keep={recoveryKeep}
												commit={confirming.outcome === "committed"
													? recoveryMarkDone
													: recoveryDrop}
												busy={busy === effect.id}
												onKeep={() => setConfirming(null)}
												onCommit={() =>
													void act(
														effect.id,
														() =>
															session.resolveSessionEffect(effect.id, confirming.outcome),
													)}
											/>
										)
										: (
											<div className="actions">
												{(effect.kind === "external" || effect.phase === "prepared") && (
													<Button
														variant="quiet"
														disabled={busy !== null}
														onClick={() =>
															setConfirming({
																id: effect.id,
																operationIds: [effect.id],
																outcome: "abandoned",
															})}
													>
														Abandon…
													</Button>
												)}
												{effect.kind === "external" && (
													<Button
														disabled={busy !== null}
														onClick={() =>
															setConfirming({
																id: effect.id,
																operationIds: [effect.id],
																outcome: "committed",
															})}
													>
														{recoveryMarkCompletedAsk}
													</Button>
												)}
												{effect.kind !== "external" && (
													<Button
														busy={busy === effect.id}
														disabled={busy !== null}
														onClick={() =>
															void act(
																effect.id,
																() => session.resumeSessionEffect(effect.id),
															)}
													>
														Resume
													</Button>
												)}
											</div>
										)}
									{why[effect.id] !== "" && why[effect.id] != null && (
										<Said kind="failure">{why[effect.id]}</Said>
									)}
								</li>
							))}
						</ul>
					</div>
				</div>
			</div>
		</dialog>
	);
}
