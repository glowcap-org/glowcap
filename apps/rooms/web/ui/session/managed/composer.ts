// Submission stays with the initiating draft and conversation through command
// admission, effect completion and exact result acquisition.
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
import { type ManagedOperation, ResultExpired, TerminalObservationError } from "./operation.ts";
import { managedSessionText } from "../../../../lib/text/managed_session.ts";
import type { HistoryCoordinate } from "../../types.ts";
import type { Conv } from "../../types.ts";

type Draft = ReturnType<typeof store.draftFor>;
/** What a committed send returns: the room's line id, its authority, and where it is archived. */
type SentReceipt = { id?: number; line?: unknown; history?: HistoryCoordinate | null };
interface Send {
	draft: Draft;
	task: Promise<void>;
	queued?: { draft: Draft; task: Promise<void> };
}

type Composer = Pick<
	RoomsConversationController,
	"setDraft" | "send" | "mention" | "recallLastSent" | "retry" | "withdraw"
>;
export function managedComposer(page: RoomsPageContext, session: ManagedRoomsSession, powers: CommandPowers): Composer {
	const projection = page.projection;
	const failures = (error: unknown) => store.toast(projection, "failure", refusalText(error));
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
		retain?.(id);
		try {
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
			void session.drafts.flush(row.persistId).catch(failures);
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
			void session.drafts.flush(row.persistId).catch(failures);
		}
		return cleared;
	}
	function restoreSubmission(row: Conv, cleared: Draft, draft: Draft): void {
		if (store.replaceDraft(projection, row.key, cleared, draft) && isSessionConv(row)) {
			session.drafts.stage(row.persistId, draft.text);
			void session.drafts.flush(row.persistId).catch(failures);
		}
	}
	function start(row: Conv, draft: Draft, plan?: ComposerPlan, cleared?: Draft): Promise<void> {
		plan ??= draft.changing == null ? planComposerSend(row, draft, powers) : undefined;
		if ((plan?.kind === "command" || plan?.kind === "send") && !retained.has(draft)) {
			cleared ??= clearSubmission(row, draft);
		}
		const task = perform(row, draft, plan, cleared).finally(() => sending.delete(row.key));
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
			await session.drafts.flush(row.persistId);
			const line = item.lineId;
			await gesture(
				draft,
				(operation) =>
					draft.keeping == null
						? session.command("editLine", [row.persistId, String(line), draft.text], operation)
						: upload(
							operation,
							row.persistId,
							draft.text,
							[],
							draft.files,
							line,
							(item.attachments ?? []).flatMap((file, i) =>
								draft.keeping?.some((kept) => kept.id === file.id) ? [i] : []
							),
						),
				async (command) => {
					if (draft.keeping == null) {
						await command.result();
						session.finish(command);
					} else await session.actions.acquireLine(row.persistId, command);
					if (store.draftFor(projection, row.key) === draft) {
						store.cancelChange(projection, row.key);
						session.drafts.stage(row.persistId, "");
						await session.drafts.flush(row.persistId);
					}
				},
			);
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
						let result = null as SentReceipt | null;
						let expired = false;
						try {
							result = await command.result() as SentReceipt | null;
						} catch (error) {
							// Delivered, but the line's returned authority expired with an
							// earlier session: it stands as sent and cannot be changed.
							if (!(error instanceof ResultExpired)) throw error;
							expired = true;
						}
						if (result?.id != null) {
							store.nameSentLine(projection, row.key, item.id, {
								id: result.id,
								history: result.history,
							});
						}
						if (expired) session.finish(command);
						else await session.actions.acquireLine(row.persistId, command);
						confirmed = true;
						if (result?.id != null) {
							store.confirmSentLine(projection, row.key, item.id, {
								id: result.id,
								history: result.history,
								held: result.line != null,
							});
						} else {
							store.updateItem(projection, row.key, item.id, {
								state: undefined,
								awaitingReceipt: undefined,
								operation: undefined,
								retryable: undefined,
							});
						}
						store.rememberLastSent(projection, row.key, prepared.original);
					},
					(operation) => store.updateItem(projection, row.key, item.id, { operation }),
				);
			} catch (error) {
				if (
					!confirmed && cleared != null && !retained.has(draft) &&
					!(error instanceof TerminalObservationError)
				) restoreSubmission(row, cleared, draft);
				// Presentation is not delivery evidence. A retained receipt keeps
				// its original source and cannot authorize a fresh blind send.
				if (!confirmed) {
					store.updateItem(projection, row.key, item.id, {
						state: error instanceof TerminalObservationError || retained.has(draft)
							? "unconfirmed"
							: "failed",
						retryable: retained.has(draft),
						operation: retained.get(draft),
					});
				}
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
			const snapshot = await session.refresh();
			return await session.perform(
				operation,
				() =>
					session.workspace.prepareUpload(
						operation,
						snapshot.revision,
						id,
						text,
						JSON.stringify(previews),
						// Wasm consumes each source wrapper during argument conversion.
						wrappers.splice(0),
						line == null ? undefined : String(line),
						new Uint32Array(keep),
					),
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
			const row = store.getConv(projection, key);
			const item = store.historyOf(projection, key).find((line) => line.id === id);
			if (row == null || !isSessionConv(row) || item?.kind !== "chat" || item.lineId == null) return;
			void session.actions.run("withdrawLine", [row.persistId, String(item.lineId)]).catch(failures);
		},
	};
}
