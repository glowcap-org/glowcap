// Submission stays with the initiating draft and conversation through command
// admission, effect completion and exact result acquisition.
import { clearRefusal, remaining, rememberRefusal } from "../../admission_feedback.ts";
import { conversationIdentity } from "./model.ts";
import { editLine } from "./edit.ts";
import { withdrawLine } from "./withdraw.ts";
import * as store from "../../store.ts";
import type { RoomsPageContext } from "../../page.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { CommandPowers } from "../../commands.ts";
import { CommandRefused } from "../../commands/types.ts";
import type { RoomsConversationController } from "../../controller/session.ts";
import { interpretComposerSend } from "../../composer/commit.ts";
import { composerLineRefusal, type ComposerPlan, planComposerSend } from "../../composer/send.ts";
import { draftWithMention, recalledDraft } from "../../composer/draft.ts";
import { isSessionConv } from "../../types.ts";
import { applicationModule } from "../../application.ts";
import { pickedSource } from "../../file_source.ts";
import { refusalText } from "../../../../lib/text/failure.ts";
import type { RoomsBrowserSource } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";
import { type ManagedOperation, ResultAcquisitionError, ResultExpired, TerminalObservationError } from "./operation.ts";
import { managedSessionText, resultAcquisitionFailure } from "../../../../lib/text/managed_session.ts";
import { CompletedLine, isLineResult } from "./completed_line.ts";
import type { Conv } from "../../types.ts";

type Draft = ReturnType<typeof store.draftFor>;
interface Send {
	draft: Draft;
	task: Promise<void>;
	queued?: { draft: Draft; task: Promise<void> };
}

/** How a submitted command's line result settled. `acquired` carries the
 * exact receipt; `degraded` means delivery is known but its result
 * acquisition failed, so the receipt is partial and the original operation
 * retains recovery; `expired` means the line's returned authority expired
 * with an earlier session and it stands as sent, unchangeable. */
type LineSettlement =
	| { kind: "acquired"; completed: CompletedLine }
	| { kind: "degraded"; completed: CompletedLine; failure: ResultAcquisitionError }
	| { kind: "expired" };

/** The partial result a failed acquisition carried, read as the line result
 * the committed send produced. An unprovable shape claims no receipt. */
function degradedCompletion(error: ResultAcquisitionError): CompletedLine {
	const result: unknown = error.result;
	return new CompletedLine(isLineResult(result) ? result : null);
}

type Composer = Pick<
	RoomsConversationController,
	"setDraft" | "send" | "mention" | "recallLastSent" | "retry" | "withdraw"
>;
export function managedComposer(page: RoomsPageContext, session: ManagedRoomsSession, powers: CommandPowers): Composer {
	const projection = page.projection;
	const failures = (error: unknown) => {
		store.toast(
			projection,
			"failure",
			error instanceof ResultAcquisitionError ? resultAcquisitionFailure(error.message) : refusalText(error),
		);
	};
	const sending = new Map<string, Send>();
	// Recovery belongs to the submitted draft. A new draft in the same
	// conversation is a separate gesture; it cannot become an old receipt retry.
	// The session's bounded completion registry retains uncertain submissions.
	const retained = new WeakMap<Draft, string>();
	async function gesture(
		draft: Draft,
		prepare: (id: string) => Promise<ManagedOperation>,
		complete: (command: ManagedOperation) => Promise<void>,
		retain?: (id: string) => void,
	): Promise<void> {
		const previous = retained.get(draft);
		if (previous != null) {
			await session.completeOperation(previous);
			return;
		}
		const id = crypto.randomUUID();
		retained.set(draft, id);
		try {
			retain?.(id);
			await session.execute(id, () => prepare(id), async (command) => {
				await complete(command);
				retained.delete(draft);
			});
		} catch (error) {
			if (!session.pending.includes(id)) retained.delete(draft);
			throw error;
		}
	}
	function setDraft(text: string): void {
		const row = store.activeConv(projection);
		if (row == null) return;
		store.setDraft(projection, text, row.key);
		if (isSessionConv(row)) {
			session.drafts.stage(row.persistId, text);
			session.drafts.sync(row.persistId);
		}
	}
	function submit(): Promise<void> {
		const row = store.activeConv(projection);
		if (row == null) return Promise.resolve();
		const draft = store.draftFor(projection, row.key);
		const previous = sending.get(row.key);
		if (previous?.draft === draft) return previous.task;
		const plan = draft.changing == null ? planComposerSend(row, draft, powers) : undefined;
		if (plan?.kind === "nothing") return Promise.resolve();
		if (plan?.kind !== "command" && remaining(projection.get().actionRefusals.get(`send:${row.key}`)) > 0) {
			return Promise.resolve();
		}
		if (previous == null) return start(row, draft, plan);
		if (previous.queued != null) {
			return previous.queued.draft === draft
				? previous.queued.task
				: Promise.reject(new Error(managedSessionText.composerBusy));
		}
		// One next gesture per conversation. Send transfers its immutable plan
		// and files out of the editable draft. Later typing cannot cancel that
		// submitted effect or become part of it.
		const cleared = plan?.kind === "command" || plan?.kind === "send" ? clearSubmission(row, draft) : undefined;
		const runQueued = () => {
			if (store.getConv(projection, row.key) == null) return;
			if (cleared == null && store.draftFor(projection, row.key) !== draft) return;
			return start(row, draft, plan, cleared);
		};
		// An uncertain earlier receipt retains its own recovery. It cannot
		// cancel the distinct gesture already submitted behind it.
		const task = previous.task.then(runQueued, runQueued);
		previous.queued = { draft, task };
		return task;
	}
	function clearSubmission(row: Conv, draft: Draft): Draft | undefined {
		const cleared: Draft = { ...draft, text: "", files: [], previews: [] };
		if (!store.replaceDraft(projection, row.key, draft, cleared)) return;
		if (isSessionConv(row)) {
			session.drafts.stage(row.persistId, "");
			session.drafts.sync(row.persistId);
		}
		return cleared;
	}
	function restoreSubmission(row: Conv, cleared: Draft, draft: Draft): void {
		if (store.replaceDraft(projection, row.key, cleared, draft) && isSessionConv(row)) {
			session.drafts.stage(row.persistId, draft.text);
			session.drafts.sync(row.persistId);
		}
	}
	function start(row: Conv, draft: Draft, plan?: ComposerPlan, cleared?: Draft): Promise<void> {
		plan ??= draft.changing == null ? planComposerSend(row, draft, powers) : undefined;
		if ((plan?.kind === "command" || plan?.kind === "send") && !retained.has(draft)) {
			cleared ??= clearSubmission(row, draft);
		}
		clearRefusal(projection, `send:${row.key}`);
		const task = perform(row, draft, plan, cleared).catch((error: unknown) => {
			if (!rememberRefusal(projection, `send:${row.key}`, error)) throw error;
		}).finally(() => sending.delete(row.key));
		sending.set(row.key, { draft, task });
		return task;
	}
	async function perform(row: Conv, draft: Draft, plan?: ComposerPlan, cleared?: Draft): Promise<void> {
		const original = retained.get(draft);
		if (original != null) {
			await session.completeOperation(original);
			return;
		}
		if (draft.changing != null) {
			if (!isSessionConv(row)) return;
			const item = store.historyOf(projection, row.key).find((line) => line.id === draft.changing);
			if (item?.kind !== "chat" || item.lineId == null || !item.held) {
				throw new Error("The original line authority is no longer held");
			}
			const refusal = composerLineRefusal(row, draft.text);
			if (refusal != null) throw new Error(refusal);
			const completeDraft = async () => {
				if (store.draftFor(projection, row.key) !== draft) return;
				store.cancelChange(projection, row.key);
				session.drafts.stage(row.persistId, "");
				await session.drafts.flush(row.persistId);
			};
			if (draft.keeping == null) {
				await editLine(page, session, row.key, item.id, draft.text, completeDraft);
			} else {
				await session.drafts.flush(row.persistId);
				await gesture(
					draft,
					(operation) =>
						upload(
							operation,
							row.persistId,
							draft.text,
							[],
							draft.files,
							item.lineId,
							(item.attachments ?? []).flatMap((file, i) =>
								draft.keeping?.some((kept) => kept.id === file.id) ? [i] : []
							),
						),
					async (command) => {
						await session.actions.acquireLine(row.persistId, command);
						await completeDraft();
					},
				);
			}
			return;
		}
		// Draft admission and the command both mutate the same workspace. Finish
		// this gesture's clear before starting its effect, retaining the plan.
		if (cleared != null && isSessionConv(row)) {
			try {
				await session.drafts.flush(row.persistId);
			} catch (error) {
				restoreSubmission(row, cleared, draft);
				throw error;
			}
		}
		const prepared = interpretComposerSend(projection, row, draft, powers, plan);
		if (prepared == null) {
			if (cleared != null) restoreSubmission(row, cleared, draft);
			return;
		}
		if (prepared.kind === "handled") {
			// The submitted command owns its draft while it settles. The visible
			// composer is ready for the next gesture; refusal restores only that
			// untouched empty draft, never text the reader typed meanwhile.
			cleared ??= clearSubmission(row, draft);
			try {
				await prepared.completion;
			} catch (error) {
				if (cleared != null) restoreSubmission(row, cleared, draft);
				if (error instanceof CommandRefused) {
					store.deliver(projection, row.key, store.sysItem(projection, error.message));
					return;
				}
				throw error;
			}
			store.rememberLastSent(projection, row.key, prepared.original);
			return;
		} else {
			if (!isSessionConv(row)) return;
			const item = store.chatItem(
				projection,
				store.dirNick(projection, row.dir),
				prepared.text,
				true,
				"sending",
				prepared.files.length === 0
					? undefined
					: prepared.files.map((file) =>
						store.attachmentView(projection, {
							name: file.name,
							mime: file.type || "application/octet-stream",
							size: file.size,
						})
					),
				Date.now(),
				prepared.previewUrls,
			);
			store.deliver(projection, row.key, { ...item, awaitingReceipt: true, retryable: false });
			let confirmed = false;
			const confirm = (completed?: CompletedLine) => {
				confirmed = true;
				store.confirmSentLine(
					projection,
					row.key,
					item.id,
					completed?.receipt(session.current) ?? { held: false },
				);
				store.rememberLastSent(projection, row.key, prepared.original);
			};
			const settleLineAcquisition = async (command: ManagedOperation): Promise<LineSettlement> => {
				try {
					return { kind: "acquired", completed: await session.actions.acquireLine(row.persistId, command) };
				} catch (error) {
					if (error instanceof ResultAcquisitionError) {
						return { kind: "degraded", completed: degradedCompletion(error), failure: error };
					}
					if (!(error instanceof ResultExpired)) throw error;
					session.finish(command);
					return { kind: "expired" };
				}
			};
			/** A send that did not confirm still settles its presentation
			 * exactly: delivery evidence degrades to a receipt, an uncertain
			 * observation retains its recovery, and a terminal refusal
			 * restores the cleared draft. */
			const settleSendFailure = (error: unknown) => {
				if (confirmed) return;
				if (error instanceof ResultAcquisitionError) {
					confirm(degradedCompletion(error));
					return;
				}
				// Presentation is not delivery evidence. A retained receipt
				// keeps its original source and cannot authorize a fresh blind
				// send.
				const outcomeRetained = error instanceof TerminalObservationError || retained.has(draft);
				if (cleared != null && !outcomeRetained) restoreSubmission(row, cleared, draft);
				store.updateItem(projection, row.key, item.id, {
					state: outcomeRetained ? "unconfirmed" : "failed",
					retryable: retained.has(draft),
					operation: retained.get(draft),
				});
			};
			try {
				await session.drafts.flush(row.persistId);
				await gesture(
					draft,
					(operation) =>
						prepared.files.length !== 0
							? upload(operation, row.persistId, prepared.text, prepared.previewUrls, prepared.files)
							: session.command("say", [
								row.persistId,
								prepared.text,
								JSON.stringify(prepared.previewUrls),
							], operation),
					async (command) => {
						const settlement = await settleLineAcquisition(command);
						confirm(settlement.kind === "expired" ? undefined : settlement.completed);
						// Delivery stays confirmed while the original operation
						// retains recovery of its result. A new send is never a
						// recovery action.
						if (settlement.kind === "degraded") throw settlement.failure;
					},
					(operation) => store.updateItem(projection, row.key, item.id, { operation }),
				);
			} catch (error) {
				settleSendFailure(error);
				throw error;
			}
			return;
		}
	}
	async function upload(
		operation: string,
		id: string,
		text: string,
		previews: readonly string[],
		files: readonly File[],
		line?: number,
		keep: number[] = [],
	): Promise<ManagedOperation> {
		const original = session.current?.intent.conversations.find((row) => row.id === id);
		if (original == null) throw new Error("The original conversation was removed");
		const identity = conversationIdentity(original);
		const originalLine = line == null ? undefined : original.lines?.find((row) => row.id === line)?.handle;
		session.effects.reserve(operation, line == null ? "say" : "editLine", [
			id,
			...(line == null ? [] : [String(line)]),
		]);
		const wrappers: RoomsBrowserSource[] = [];
		try {
			for (const file of files) {
				const source = await pickedSource(file);
				wrappers.push(
					new (applicationModule().RoomsBrowserSource)(
						source.name,
						source.mime,
						source.size ?? file.size,
						source.width ?? 0,
						source.height ?? 0,
						source.read,
					),
				);
			}
			return await session.perform(
				operation,
				async () => {
					const snapshot = await session.refresh();
					const current = snapshot.intent.conversations.find((row) => row.id === id);
					if (
						current == null || conversationIdentity(current) !== identity ||
						(line != null && current.lines?.find((row) => row.id === line)?.handle !== originalLine)
					) {
						throw new Error("The original upload target changed during preparation");
					}
					return session.workspace.prepareUpload(
						operation,
						snapshot.revision,
						id,
						text,
						JSON.stringify(previews),
						// Wasm consumes each source wrapper during argument conversion.
						wrappers.splice(0),
						line == null ? undefined : String(line),
						new Uint32Array(keep),
					);
				},
			);
		} finally {
			for (const wrapper of wrappers) wrapper.free();
		}
	}
	return {
		setDraft,
		mention: (who) => setDraft(draftWithMention(store.activeDraft(projection).text, who)),
		recallLastSent: () => {
			const row = store.activeConv(projection);
			if (row == null) return null;
			const text = recalledDraft(store.activeDraft(projection), store.lastSentFor(projection, row.key));
			if (text != null) setDraft(text);
			return text;
		},
		send: () => {
			void submit().catch(failures);
		},
		retry: (key, id) => {
			const item = store.historyOf(projection, key).find((line) => line.id === id);
			if (item?.kind !== "chat" || item.operation == null || item.state === "sending") return;
			const { operation, state } = item;
			// The line dims while its original observation resumes, then shows
			// the outcome without submitting another send.
			store.updateItem(projection, key, id, { state: "sending" });
			const still = () =>
				store.historyOf(projection, key).some((line) =>
					line.id === id && line.kind === "chat" && line.state === "sending"
				);
			void session.completeOperation(operation).then(() => {
				if (still()) {
					store.updateItem(projection, key, id, {
						state: undefined,
						awaitingReceipt: undefined,
						operation: undefined,
						retryable: undefined,
					});
				}
			}, (error: unknown) => {
				if (still()) store.updateItem(projection, key, id, { state });
				failures(error);
			});
		},
		withdraw: (key, id) => {
			void withdrawLine(page, session, key, id).catch(() => {
				// The original line retains the refusal and exact receipt.
			});
		},
	};
}
