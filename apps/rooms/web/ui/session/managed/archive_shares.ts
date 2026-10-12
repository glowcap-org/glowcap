import { LOCAL_LIMITS } from "./local_gestures.ts";
import { archiveDropFull, archiveReadFull } from "../../../../lib/text/archive.ts";
import { managedSessionText as managedText, sharedHistoryLabel } from "../../../../lib/text/managed_session.ts";
// Incoming choices select session archive custody. Displayed files retain the
// exact reader through offer dismissal and later workspace selection changes.
import type { RoomsPageContext } from "../../page.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { RoomsWorkspaceController } from "../../controller/session.ts";
import type { AttachedSessionFiles } from "../attached_files.ts";
import type { PresentedFile } from "./files.ts";
import { ArchiveSource } from "./history.ts";
import { conversationIdentity, coordinate, type ReceivedArchive } from "./model.ts";
import * as store from "../../store.ts";
import { reconcileSharedArchive } from "../shared_archive_projection.ts";
import type { ArchiveRecord } from "../../../../lib/archive/protocol.ts";
import { MAX_ARCHIVE_READ, MAX_ARCHIVE_RECORDS } from "../../../../lib/archive/limits.ts";
import { refusalText } from "../../../../lib/text/failure.ts";
import { revisionReadKey } from "./reads.ts";

function offerIdentity(row: ReceivedArchive): string {
	return JSON.stringify([
		row.id,
		row.channel,
		row.directory,
		row.kind,
		row.conversation,
		row.from,
		row.access,
		row.source,
		row.durable,
	]);
}

type Reading = Pick<
	RoomsWorkspaceController,
	| "readArchiveShare"
	| "dropArchiveShare"
	| "shareArchiveHistory"
	| "offerDurableArchive"
	| "listIssuedArchiveShares"
	| "revokeIssuedArchiveShare"
>;
export function managedArchiveReading(
	page: RoomsPageContext,
	session: ManagedRoomsSession,
	files: AttachedSessionFiles<PresentedFile>,
): Reading {
	const running = new Map<string, Promise<string>>();
	async function share(
		key: string,
		peer: string | undefined,
		records: "line" | "standing",
		durable: boolean,
	): Promise<string> {
		try {
			const conversation = store.getConv(page.projection, key);
			if (conversation == null || conversation.type === "directory") {
				throw new Error("Select a room or direct conversation to share its history");
			}
			const kind = records === "standing" ? "standing" : conversation.type === "room" ? "room" : "direct";
			const original = session.current?.intent.conversations.find((row) => row.id === conversation.persistId);
			if (original == null) throw new Error("The original conversation is no longer held");
			const identity = conversationIdentity(original);
			const recipient = conversation.type === "dm"
				? conversation.persistId
				: await session.actions.direct(conversation.dir, peer?.trim() || "", false);
			const selected = session.current?.intent.conversations.find((row) => row.id === conversation.persistId);
			if (selected == null || conversationIdentity(selected) !== identity) {
				throw new Error("The original conversation changed while acquiring the history recipient");
			}
			await session.actions.run(durable ? "offerDurableArchive" : "shareArchiveHistory", [
				conversation.persistId,
				recipient,
				kind,
				crypto.randomUUID(),
				sharedHistoryLabel(conversation.id),
			]);
			return "";
		} catch (error) {
			return refusalText(error);
		}
	}
	async function drop(id: string, identity?: string): Promise<void> {
		const snapshot = await session.candidate();
		const shares = snapshot.intent.archiveShares;
		if (shares == null) return;
		const selected = shares.find((row) => row.id === id);
		if (selected == null) return;
		if (identity != null && offerIdentity(selected) !== identity) {
			throw new Error("The original archive offer changed before dismissal");
		}
		snapshot.intent.archiveShares = shares.filter((row) => row.id !== id);
		await session.actions.replace(snapshot);
	}
	async function read(id: string): Promise<string> {
		const selected = session.current?.intent.archiveShares?.find((row) => row.id === id);
		if (selected == null) return managedText.archiveOfferMissing;
		const identity = offerIdentity(selected);
		const receiving = store.convByPersistId(page.projection, selected.channel);
		if (receiving == null) return managedText.receivingConversationMissing;
		const receivingIntent = session.current?.intent.conversations.find((row) => row.id === selected.channel);
		if (receivingIntent == null) return managedText.receivingConversationMissing;
		const receivingIdentity = conversationIdentity(receivingIntent);
		const fresh = () => {
			const current = session.current?.intent.archiveShares?.find((row) => row.id === id);
			const conversation = store.convByPersistId(page.projection, selected.channel);
			const intent = session.current?.intent.conversations.find((row) => row.id === selected.channel);
			return current != null && offerIdentity(current) === identity && session.permits("readArchive") &&
				conversation?.key === receiving.key && intent != null &&
				receivingIdentity === conversationIdentity(intent);
		};
		store.patchArchiveShare(page.projection, id, { status: "reading", error: "" });
		let source: ArchiveSource | null = null;
		try {
			source = new ArchiveSource(
				await session.workspace.archiveReader(
					coordinate("archiveAccess", selected.access),
					session.permits("readFile"),
				),
			);
			if (!fresh()) throw new Error("The original archive selection or reading permission changed");
			const records: ArchiveRecord[] = [];
			let after = "0";
			while (records.length < MAX_ARCHIVE_RECORDS) {
				const result = await source.reader.read(
					JSON.stringify({
						source: null,
						generation: null,
						kind: selected.kind === "standing" ? "standing" : "line",
						conversationKind: selected.kind === "standing" ? null : selected.kind,
						directory: selected.directory,
						conversation: selected.conversation,
						digest: null,
					}),
					after,
					MAX_ARCHIVE_READ,
				);
				if (!fresh()) throw new Error("The original archive selection or reading permission changed");
				for (const { record } of result.records) records.push(record);
				if (records.length > MAX_ARCHIVE_RECORDS || (result.more && records.length === MAX_ARCHIVE_RECORDS)) {
					throw new Error("The archive exceeded its declared record bound");
				}
				if (!result.more) break;
				if (result.records.length === 0) throw new Error("The archive returned an empty continuation page");
				if (BigInt(result.next) <= BigInt(after)) throw new Error("The archive cursor did not advance");
				after = result.next;
			}
			if (!fresh()) throw new Error("The original receiving conversation or archive offer changed");
			const selectedSource = source;
			reconcileSharedArchive(
				page,
				receiving.key,
				records,
				selected.from,
				files,
				(record, index) => selectedSource.file(record, index),
			);
			await drop(id, identity);
			return "";
		} catch (error) {
			const reason = refusalText(error);
			if (fresh()) store.patchArchiveShare(page.projection, id, { status: "unavailable", error: reason });
			return reason;
		} finally {
			source?.release();
		}
	}
	return {
		shareArchiveHistory: (key, peer, records = "line") => share(key, peer, records, false),
		offerDurableArchive: (key, peer, records = "line") => share(key, peer, records, true),
		listIssuedArchiveShares: () =>
			session.reads.run(
				revisionReadKey("issuedShares", session.current?.intent.archive, session.current?.revision),
				() => session.workspace.issuedArchiveShares(),
			),
		revokeIssuedArchiveShare: async (id) => {
			try {
				await session.actions.run("revokeIssuedArchiveShare", [id]);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		readArchiveShare: (id) => {
			const existing = running.get(id);
			if (existing != null) return existing;
			if (running.size >= LOCAL_LIMITS.reads) {
				return Promise.resolve(archiveReadFull);
			}
			const task = read(id).finally(() => running.delete(id));
			running.set(id, task);
			return task;
		},
		dropArchiveShare: (id) => {
			if (running.has(id)) return;
			if (running.size >= LOCAL_LIMITS.reads) {
				store.patchArchiveShare(page.projection, id, {
					status: "unavailable",
					error: archiveDropFull,
				});
				return;
			}
			const selected = session.current?.intent.archiveShares?.find((row) => row.id === id);
			if (selected == null) return;
			const identity = offerIdentity(selected);
			store.patchArchiveShare(page.projection, id, { status: "dropping", error: "" });
			const task = drop(id, identity).then(() => "", (error: unknown) => {
				const why = refusalText(error);
				const current = session.current?.intent.archiveShares?.find((row) => row.id === id);
				if (current != null && offerIdentity(current) === identity) {
					store.patchArchiveShare(page.projection, id, { status: "unavailable", error: why });
				}
				return why;
			}).finally(() => running.delete(id));
			running.set(id, task);
		},
	};
}
