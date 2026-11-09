// Durable work that stopped before it finished, on a card of its own. Each row
// is one retained operation named from its original request, with the one act
// that moves it on. An unknown upstream outcome stays unknown until the
// original observation resumes.
import { useEffect, useRef, useState } from "react";
import { useAsyncAction } from "../async_action.ts";
import { Button } from "../Button.tsx";
import { ModalHead } from "../ModalHead.tsx";
import { Said } from "../Said.tsx";
import { Confirm } from "../Confirm.tsx";
import { useHeldModal, useModalDialog } from "../modal.ts";
import { useManagedSession } from "../session/managed/context.tsx";
import { useOpenChanges } from "../session/managed/open_changes.ts";
import { isRetainedCommandIntent } from "../session/managed/admission.ts";
import { useRoomsProjection, useRoomsState } from "../hooks.ts";
import { releaseSentLine } from "../store.ts";
import {
	recoveryFinish,
	recoveryKeep,
	recoveryLead,
	recoveryLetGo,
	recoveryLetGoAsk,
	recoveryLetGoLabel,
	recoveryLetGoSay,
	recoveryLetGoSend,
	recoveryListUnread,
	recoveryOperationDetails,
	recoveryPickUp,
	recoveryRetryUpdates,
	recoveryRowHint,
	recoveryStatus,
	recoverySubject,
	recoveryTitle,
	recoveryUpdatesStopped,
} from "../../../lib/text/recovery.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import { ModalCard } from "../ModalCard.tsx";

export function SessionRecoveryModal(
	{ open, onClose, dismissWhenEmpty = true }: { open: boolean; onClose(): void; dismissWhenEmpty?: boolean },
) {
	const session = useManagedSession();
	const dialog = useRef<HTMLDialogElement>(null);
	const close = useRef<HTMLButtonElement>(null);
	const [said, setSaid] = useState<Readonly<Record<string, string>>>({});
	const [acting, setActing] = useState<string | null>(null);
	// The open question keeps the row's standing from when it was asked, so a
	// background retry that briefly changes the row cannot take it away.
	const [asking, setAsking] = useState<{ id: string; state: keyof typeof recoveryLetGoSay } | null>(null);
	const projection = useRoomsProjection();
	// One act at a time: each changes the same session's receipts, and two at
	// once would race for them. Letting go removes the receipt for good.
	const recovery = useAsyncAction(async (_signal, id: string, act: "complete" | "acquire" | "release") => {
		setActing(id);
		setSaid((prior) => ({ ...prior, [id]: "" }));
		try {
			if (act === "acquire") await session.actions.recoverAcquisition(id);
			else if (act === "complete") await session.completeOperation(id);
			else {
				await session.releaseOperation(id);
				releaseSentLine(projection, id);
			}
			if (act === "release") setAsking((open) => open?.id === id ? null : open);
		} catch (error) {
			setSaid((prior) => ({ ...prior, [id]: refusalText(error) }));
		}
	});
	const convs = useRoomsState((state) => state.convs);
	const { held, onExited } = useHeldModal(open);
	useModalDialog(dialog, onClose, close, open, onExited);
	// The rows, read while the card is open and re-read as the session changes.
	const { rows, changes: items, failure: unread } = useOpenChanges(session, open);
	const busy = recovery.busy ? acting : null;
	const act = (id: string, kind: "complete" | "acquire" | "release") => void recovery.run(id, kind);
	// The card closes itself once a read finds nothing open, not when the
	// notice's count dips: a row being recovered stays open until it lands.
	const empty = rows != null && items.length === 0;
	useEffect(() => {
		if (open && empty && dismissWhenEmpty) onClose();
	}, [open, empty, dismissWhenEmpty, onClose]);
	if (!held) return null;
	const conversation = (id: string) => {
		for (const row of convs.values()) if (row.type !== "directory" && row.persistId === id) return row.id;
		return null;
	};
	const diagnostics = new Map(
		[...session.effects.diagnostics, ...session.actions.diagnostics].map((row) => [row.operation, row]),
	);
	const intents = new Map<string, readonly unknown[] | Record<string, unknown>>();
	for (const operation of session.pendingOperations) intents.set(operation.id, operation.request.originalIntent());
	const isSend = (id: string) => {
		const original = intents.get(id);
		return Array.isArray(original) ? original[2] === "say" : original != null && "upload" in original;
	};
	const subject = (id: string) => {
		const original = intents.get(id);
		if (
			isRetainedCommandIntent(original) &&
			original[3].every((arg): arg is string => typeof arg === "string")
		) {
			return recoverySubject(original[2], original[3], conversation);
		}
		if (original != null && !Array.isArray(original) && "upload" in original) {
			return recoverySubject("upload", [String(original.conversation)], conversation);
		}
		return recoverySubject("", [], conversation);
	};
	return (
		<dialog
			ref={dialog}
			className="modal"
			aria-labelledby="sessionRecoveryTitle"
			onCancel={(event) => {
				event.preventDefault();
				onClose();
			}}
		>
			<ModalCard className="session-recovery-modal">
				<div className="modal-body">
					<ModalHead
						titleId="sessionRecoveryTitle"
						title={recoveryTitle(items.length)}
						onClose={onClose}
						closeRef={close}
					/>
					{
						/* Held in place until the first read settles, so the count does not
						   change under the reader. A failed read settles it too: the card
						   then says what it could not read, where the count would be. */
					}
					{unread !== ""
						? <Said kind="failure">{recoveryListUnread(unread)}</Said>
						: (
							<p className="lead" style={{ visibility: rows == null ? "hidden" : undefined }}>
								{recoveryLead(items.length)}
							</p>
						)}
					<div className={items.length === 0 ? undefined : "group well"}>
						<ul className="entries" id="sessionRecoveryList" aria-busy={rows == null}>
							{items.map((item) => {
								const move = item.act;
								return (
									<li
										className="entry"
										key={item.id}
										data-operation={item.id}
										data-status={item.status}
										data-resumable={item.resumable === true}
									>
										<div className="entry-head" data-one-line>
											<span className="entry-name">{subject(item.id)}</span>
											<span
												className="tag"
												data-tone={item.state === "unknown"
													? "warn"
													: item.state === "committed" || item.state === "saving"
													? undefined
													: "quiet"}
											>
												{recoveryStatus[item.state]}
											</span>
											{(move != null || item.letGo) && asking?.id !== item.id && (
												<div className="actions">
													{item.letGo && (
														<Button
															variant="quiet"
															disabled={busy != null}
															onClick={() =>
																item.state in recoveryLetGoSay &&
																setAsking({
																	id: item.id,
																	state: item.state as keyof typeof recoveryLetGoSay,
																})}
														>
															{recoveryLetGoAsk}
														</Button>
													)}
													{move != null && (
														<Button
															variant="quiet"
															busy={busy === item.id}
															disabled={busy != null}
															onClick={() => act(item.id, move)}
														>
															{item.state === "committed" || item.state === "saving"
																? recoveryFinish
																: recoveryPickUp}
														</Button>
													)}
												</div>
											)}
										</div>
										<p className="hint">{recoveryRowHint[item.state]}</p>
										{asking?.id === item.id && (
											<Confirm
												label={recoveryLetGoLabel}
												say={recoveryLetGoSay[asking.state] +
													(isSend(item.id) ? ` ${recoveryLetGoSend}` : "")}
												keep={recoveryKeep}
												commit={recoveryLetGo}
												busy={busy === item.id}
												onKeep={() => setAsking(null)}
												onCommit={() => act(item.id, "release")}
											/>
										)}
										{said[item.id] && <Said kind="failure">{said[item.id]}</Said>}
										{
											/* What the session recorded about this operation, for whoever has
										   to diagnose it: after everything the reader decides from, and
										   folded, because few readers need it. */
										}
										{diagnostics.has(item.id) && (
											<details className="disclosure">
												<summary>{recoveryOperationDetails}</summary>
												<pre className="error-body">{JSON.stringify(diagnostics.get(item.id), null, 2)}</pre>
											</details>
										)}
									</li>
								);
							})}
						</ul>
					</div>
					{session.updatesFailure != null && (
						<>
							<Said kind="warning">{recoveryUpdatesStopped(refusalText(session.updatesFailure))}</Said>
							<div className="actions">
								<Button
									variant="quiet"
									busy={session.updatesRetrying}
									disabled={session.updatesRetrying}
									onClick={() => session.retryUpdates()}
								>
									{recoveryRetryUpdates}
								</Button>
							</div>
						</>
					)}
				</div>
			</ModalCard>
		</dialog>
	);
}
