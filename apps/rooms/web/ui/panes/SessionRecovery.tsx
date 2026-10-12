// Durable work that stopped before it finished, on a card of its own. Each row
// is one retained operation named from its original request, with the one act
// that moves it on. An unknown upstream outcome stays unknown until the
// original observation resumes.
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { useAsyncAction } from "../async_action.ts";
import { Button } from "../Button.tsx";
import { ModalHead } from "../ModalHead.tsx";
import { Said } from "../Said.tsx";
import { Confirm } from "../Confirm.tsx";
import { useHeldModal, useModalDialog } from "../modal.ts";
import { useManagedSession } from "../session/managed/context.tsx";
import type { EffectView } from "../session/managed/model.ts";
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

export function SessionRecoveryModal(
	{ open, onClose, dismissWhenEmpty = true }: { open: boolean; onClose(): void; dismissWhenEmpty?: boolean },
) {
	const session = useManagedSession();
	const dialog = useRef<HTMLDialogElement>(null);
	const close = useRef<HTMLButtonElement>(null);
	// The receipt inventory, or null until it has been read since opening.
	const [rows, setRows] = useState<EffectView[] | null>(null);
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
	// The card draws the session's own admission and retry state, so it
	// repaints when those change rather than when the inventory read lands.
	useSyncExternalStore(session.subscribe, () =>
		JSON.stringify([
			session.pending,
			session.recoverable,
			session.actions.pending,
			session.actions.recoverable,
			session.updatesRetrying,
			session.updatesFailure != null,
		]), () => "");
	const { held, onExited } = useHeldModal(open);
	useModalDialog(dialog, onClose, close, open, onExited);
	useEffect(() => {
		if (!open) {
			setRows(null);
			return;
		}
		let current = true;
		let dirty = false;
		let reading = false;
		const refresh = () => {
			dirty = true;
			if (reading) return;
			reading = true;
			void (async () => {
				try {
					while (current && dirty) {
						dirty = false;
						try {
							const rows: EffectView[] = await session.workspace.effects();
							if (current && !dirty) {
								setRows(rows);
								setSaid((prior) => prior.list ? { ...prior, list: "" } : prior);
							}
						} catch (error) {
							if (current && !dirty) setSaid((prior) => ({ ...prior, list: refusalText(error) }));
						}
					}
				} finally {
					reading = false;
				}
			})();
		};
		const unsubscribe = session.subscribe(refresh);
		refresh();
		return () => {
			current = false;
			unsubscribe();
		};
	}, [open, session]);
	const busy = recovery.busy ? acting : null;
	const act = (id: string, kind: "complete" | "acquire" | "release") => void recovery.run(id, kind);
	type State = keyof typeof recoveryStatus;
	// The inventory owns which receipts are still open, whoever holds them; the
	// session adds the results it still has to save and the work it has not yet
	// receipted. A committed receipt nothing here still has to save is done.
	const holding = new Set(session.pending);
	const acquiring = new Set(
		[...session.pendingOperations].filter((operation) => operation.acquiring).map((operation) => operation.id),
	);
	const recoverable = new Set([...session.recoverable, ...session.actions.recoverable]);
	const receipted = new Set((rows ?? []).map((row) => row.operation));
	const known = (status: string) => (status in recoveryStatus ? status : "unknown") as State;
	type Item = {
		id: string;
		status: string;
		state: State;
		act: (() => void) | null;
		letGo: boolean;
		resumable?: boolean;
	};
	const items: Item[] = [
		...session.actions.pending.map((id) => ({
			id,
			status: "committed",
			state: recoverable.has(id) ? "saving" as const : "working" as const,
			act: recoverable.has(id) ? () => act(id, "acquire") : null,
			// An uncertain local commit still needs its original receiver.
			letGo: false,
		})),
		...(rows ?? []).filter((row) => row.status !== "committed" || holding.has(row.operation)).map((row) => {
			const id = row.operation;
			const ready = holding.has(id) ? recoverable.has(id) : row.resumable;
			// Held work that is not recoverable is still running here.
			const running = holding.has(id) && !ready;
			return {
				id,
				status: row.status,
				resumable: row.resumable,
				state: running ? "working" as const : known(row.status),
				act: ready ? () => act(id, "complete") : null,
				// Paused executors still own admitted work and its settlement.
				letGo: !running && !row.resumable && !acquiring.has(id) && row.status !== "pending",
			};
		}),
		// Held here with no receipt: still being admitted, or its receipt has
		// left the window, which leaves its outcome unknown for good.
		...session.pending.filter((id) => !receipted.has(id)).map((id) => ({
			id,
			status: "held",
			state: recoverable.has(id) ? "unknown" as const : "working" as const,
			act: recoverable.has(id) ? () => act(id, "complete") : null,
			letGo: recoverable.has(id) && !acquiring.has(id),
		})),
	];
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
			<div className="modal-card card-plane session-recovery-modal">
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
					{said.list
						? <Said kind="failure">{recoveryListUnread(said.list)}</Said>
						: (
							<p className="lead" style={{ visibility: rows == null ? "hidden" : undefined }}>
								{recoveryLead(items.length)}
							</p>
						)}
					<div className={items.length === 0 ? undefined : "group well"}>
						<ul className="entries" id="sessionRecoveryList" aria-busy={rows == null}>
							{items.map((item) => (
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
										{(item.act != null || item.letGo) && asking?.id !== item.id && (
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
												{item.act != null && (
													<Button
														variant="quiet"
														busy={busy === item.id}
														disabled={busy != null}
														onClick={item.act}
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
							))}
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
			</div>
		</dialog>
	);
}
