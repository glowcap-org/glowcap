// Focused decisions for durable session operations that stopped at a recovery
// boundary. This is application work rather than a setting: the page notice
// opens this card directly, and transient action state stays inside the card.

import { useEffect, useRef, useState } from "react";
import { Button } from "./Button.tsx";
import { Confirm } from "./Confirm.tsx";
import { ModalHead } from "./ModalHead.tsx";
import { Said } from "./Said.tsx";
import { useRoomsSession } from "./controller/session.ts";
import { useRoomsState } from "./hooks.ts";
import { useHeldModal, useModalDialog } from "./modal.ts";

function phaseLabel(phase: "unresolved" | "prepared" | "completed" | "applied"): string {
	if (phase === "unresolved") return "Needs confirmation";
	if (phase === "prepared") return "Ready to resume";
	if (phase === "completed") return "Result recorded";
	return "Ready to finish";
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
			const refused = await request();
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
				const refused = await session.resolveSessionEffect(operationId, outcome);
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
	const title = effects.length === 1 ? "Review session operation" : "Review session operations";
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
						{effects.length === 1
							? "This durable change stopped before the session knew its final outcome."
							: "These durable changes stopped before the session knew their final outcomes."}
					</p>
					{effects.length > 2 &&
						(abandonable.length === effects.length || completable.length === effects.length) && (
						<div className="group well session-recovery-bulk">
							{confirming?.id === "bulk"
								? (
									<Confirm
										label="Resolve all session operations"
										tone={confirming.outcome === "committed" ? "primary" : "danger"}
										say={confirming.outcome === "committed"
											? `Mark all ${confirming.operationIds.length} outside operations completed? The session will not perform them again.`
											: `Abandon all ${confirming.operationIds.length} operations? The session will not resume them.`}
										keep="Go back"
										commit={confirming.outcome === "committed"
											? "Mark all completed"
											: "Abandon all"}
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
												Abandon all…
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
												Mark all completed…
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
											? "Tell the session whether the outside action completed. It cannot tell from here."
											: effect.phase === "prepared"
											? "Resume the recorded recovery path, or abandon it before it produces a result."
											: "Resume the recorded recovery path to finish applying its result."}
									</p>
									{confirming?.id === effect.id
										? (
											<Confirm
												label="Resolve session operation"
												tone={confirming.outcome === "committed" ? "primary" : "danger"}
												say={confirming.outcome === "committed"
													? "Use this only when the outside action is known to have completed. The session will not perform it again."
													: "The session will not resume this. Whatever already happened outside stays as it is."}
												keep="Go back"
												commit={confirming.outcome === "committed"
													? "Mark completed"
													: "Abandon operation"}
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
														Mark completed…
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
