// Sending files, and changing the files on a line already posted.
//
// A room admits each file and publishes one message; a direct line grants
// sender-hosted blob capabilities. Callers still go through `send.ts`.

import { Ref } from "@pancake/runtime";
import { type Attachment, validateAttachmentSource } from "../../../lib/attachment.ts";
import { PostedLine, Room } from "../../../lib/room_client.ts";
import { lineCost, MAX_LINE, MAX_MESSAGE_FILES } from "../../../lib/limits.ts";
import * as store from "../store.ts";
import { type AttachmentView, type DirId, type DmConv, type Item, type RoomConv, silencedFrom } from "../types.ts";
import { lineRoom, tooLong } from "../text.ts";
import { fetchesOnArrival } from "../media.ts";
import { failRoomSend, markSend, NOT_IN_THIS_ROOM, reason, trouble } from "./common.ts";
import { convSession, dirSession, isConnected, isCurrent } from "./live.ts";
import {
	commitAttachmentUpdates,
	holdRoomFile,
	keepObjectUrl,
	measureImage,
	noteAttachmentProgress,
	openAttachment,
	releaseHeldFile,
	releaseRoomAttachments,
} from "./files.ts";
import { pickedSource } from "../file_source.ts";
import { deliverDm, holdDmLine } from "./direct.ts";
import { withdraw } from "./send.ts";

/** Send files to the active room or direct conversation.
 *
 * The line is painted at once as sending. A room admits each file, publishes
 * their one message, then drives its uploads in parallel. A direct message
 * grants sender-hosted blob capabilities over the selected peer session.
 */
export function sendFiles(conv: RoomConv | DmConv, files: File[], caption: string): void {
	// Being offline is answered first, because it is the case a reader can act
	// on. Only once there is a session does "we are not in that room" mean
	// anything, and that one stays silent: the composer is not reachable from a
	// room this tab has left.
	if (!isConnected()) {
		store.deliverActive(store.sysItem("Not connected, your files were not sent"));
		return;
	}
	// Held conversation, no membership behind it. This used to return without a
	// word, and the composer is cleared either way, so the files and their caption
	// were dropped in silence. Saying it and then going on is what keeps them: the
	// ordinary failure path paints the bubble, marks it unsent, and holds the
	// picked files for the retry that carries them when the room is back.
	if (conv.type === "room" && !convSession(conv.key)?.rooms.has(conv.key)) {
		store.deliver(conv.key, store.sysItem(NOT_IN_THIS_ROOM));
	}
	const attachments = files.map((file) =>
		store.attachmentView({
			name: file.name,
			mime: file.type || "application/octet-stream",
			size: file.size,
		})
	);
	const item = store.chatItem(
		store.dirNick(conv.dir),
		caption || files[0].name,
		true,
		"sending",
		attachments,
	);
	// The session owns the picked files, the upload, and the stop that ends it. It
	// was here a moment ago, when this refused to run offline, and if it has gone
	// in between there is nothing to own this send: the bubble was already drawn
	// as going, and nothing left would ever settle it or answer its Stop.
	const owner = convSession(conv.key);
	if (owner !== null) {
		owner.outgoing.set(item.id, {
			key: conv.key,
			attachmentIds: attachments.map((file) => file.id),
			files,
			caption,
		});
	}
	store.deliver(conv.key, item);
	if (owner === null) {
		markSend(conv.key, item.id, "refused");
		store.deliver(conv.key, store.sysItem("The connection went before these files could be sent."));
		return;
	}
	void uploadPickedFiles(conv.key, item.id);
}

/** Send one of our own file messages: the first attempt, and every retry. The
 * files are held on the session by message id, so a retry sends them together
 * rather than re-posting the caption on its own. */
async function uploadPickedFiles(key: string, id: number): Promise<void> {
	// Both of these leave a bubble already drawn as going, so neither may return
	// in silence: nothing else settles a send whose owner is not there to fail.
	const owner = convSession(key);
	if (owner === null) {
		markSend(key, id, "refused");
		return;
	}
	const outgoing = owner.outgoing.get(id);
	if (outgoing === undefined) {
		markSend(key, id, "refused");
		return;
	}
	const { attachmentIds, files, caption } = outgoing;
	// A fresh one per attempt: a retry after a stop must not inherit the trip
	// that ended the last one.
	const stop = new AbortController();
	outgoing.stop = stop;
	try {
		const measured = await Promise.all(
			files.map((file) => measureImage(file, file.type || "application/octet-stream")),
		);
		// Measuring an image yields to the browser. Closing the conversation or
		// reconnecting during that yield removes this exact outgoing attempt; do
		// not recreate its URLs or send it after its owner has gone.
		const conv = store.getConv(key);
		if (!isCurrent(owner) || owner.outgoing.get(id) !== outgoing || conv === null) return;
		const item = conv.history.find((row) => row.id === id);
		const direct = conv.type === "dm";
		const sources = files.map((file, index) => {
			const mime = file.type || "application/octet-stream";
			const dimensions = measured[index];
			const attachment = item?.kind === "chat"
				? item.attachments?.find((candidate) => candidate.id === attachmentIds[index])
				: undefined;
			if (
				attachment !== undefined && attachment.url === undefined &&
				(direct || mime.startsWith("image/"))
			) {
				store.updateAttachment(key, attachmentIds[index], {
					url: keepObjectUrl(owner, attachmentIds[index], file),
					...dimensions,
				});
			} else store.updateAttachment(key, attachmentIds[index], dimensions);
			return {
				...pickedSource(file),
				...dimensions,
			};
		});
		if (conv?.type === "room") {
			// The room this message belongs to, not whichever one is on screen: a
			// reader may switch rooms while an upload runs, and the bytes still owe
			// their bubble.
			const room = owner.rooms.get(key);
			// Read by a person: this becomes the reason under each file in the
			// bubble, so it says the state rather than naming the table it failed
			// to find a row in.
			if (!room) throw new Error("not in this room at the moment");
			const uploads = await Promise.all(sources.map((source) => room.stage(source)));
			// Staging yields. Leaving the conversation or losing this session in
			// that window removes the outgoing owner; discard what was admitted
			// instead of publishing a message after its bubble was torn down.
			if (!isCurrent(owner) || owner.outgoing.get(id) !== outgoing || store.getConv(key) === null) {
				await Promise.allSettled(uploads.map((upload) => room.discard(upload)));
				return;
			}
			owner.echoes.push({ key, id, attachmentIds, text: caption || files[0].name });
			let line: PostedLine | null;
			try {
				line = await room.postFiles(caption);
			} catch (error) {
				await Promise.allSettled(uploads.map((upload) => room.discard(upload)));
				throw error;
			}
			// The room answered with the line's reference, the same one `say` gets
			// for a text line: holding it is what lets this file line be captioned
			// again, have its files changed, or be taken back. Held under this
			// window's id; the echo below names the wire line it maps to.
			if (line !== null && owner.outgoing.get(id) === outgoing) {
				owner.posted.set(id, line);
				store.holdLine(key, id);
			}
			await Promise.all(
				uploads.map((upload, index) =>
					room.upload(
						upload,
						sources[index],
						(sent) => noteAttachmentProgress(owner, key, attachmentIds[index], sent),
						stop.signal,
					)
				),
			);
		} else if (conv?.type === "dm") {
			const line = await deliverDm(conv, caption || files[0].name, sources);
			if (line !== null && owner.outgoing.get(id) === outgoing) holdDmLine(key, id, line);
			markSend(key, id, undefined);
			store.setDmLine(key, "live");
		} else throw new Error("conversation closed");
		commitAttachmentUpdates(
			owner,
			key,
			new Map(attachmentIds.map((fileId) => [fileId, { got: undefined, error: undefined }])),
		);
		owner.outgoing.delete(id);
		// Everything this message carries is on the room now. The echo may have
		// come and gone while the bytes were going up, in which case it left the
		// bubble sending for this to clear.
		if (!owner.echoes.some((row) => row.id === id)) markSend(key, id, undefined);
	} catch (err) {
		const conv = store.getConv(key);
		if (conv?.type === "room") failRoomSend(key, id, owner);
		else markSend(key, id, "failed");
		// The bytes never reached the room, so there is nothing for a file row to
		// fetch: the failed message's own retry is what sends them, and it clears
		// these when it does. Two controls for one failure, one of which cannot
		// work, is worse than the one that can.
		const why = reason(err);
		commitAttachmentUpdates(
			owner,
			key,
			new Map(attachmentIds.map((fileId) => [fileId, { got: undefined, error: why, lost: true }])),
		);
	}
}

/** Change the files on one of our own posted lines: keep some of what is there,
 * add newly-picked ones, and let the rest go.
 *
 * `keeping` is the subset of the line's current files to hold onto; `newFiles`
 * are freshly picked ones to add after them. Removing everything with no caption
 * takes the line back, so that routes to `withdraw` rather than posting a blank
 * line. The new set is painted at once and reconciled by the room's `refiled`
 * echo (see `applyRefile`), so a kept file never leaves the screen and a new one
 * shows from the bytes we already hold. */
export async function refileActive(
	conv: RoomConv | DmConv,
	id: number,
	caption: string,
	keeping: readonly AttachmentView[],
	newFiles: readonly File[],
): Promise<void> {
	const owner = convSession(conv.key);
	const room = conv.type === "room" ? owner?.rooms.get(conv.key) : undefined;
	const line = owner?.posted.get(id);
	const item = store.getConv(conv.key)?.history.find((row) => row.id === id);
	// A room refile needs the room and the line's wire id; a direct one needs
	// only the handle the peer answered with, which `posted` already holds.
	if (
		owner === null || line === undefined || item?.kind !== "chat" ||
		(conv.type === "room" && (!room || item.lineId === undefined))
	) {
		store.deliverActive(store.sysItem("That line's files cannot be changed from here."));
		return;
	}
	// The files to keep, in the order they sit on the line now: a kept file's
	// position here is the index the line's host knows it by, so these two lists
	// stay in step. Anything `keeping` names that has since left the line is gone.
	const original = item.attachments ?? [];
	// The caption as posted, kept beside the file set for the same rollback: a
	// refused refile must put back everything the optimistic paint changed, and
	// the paint changes both.
	const originalText = item.text;
	const keptViews: AttachmentView[] = [];
	const keptIndices: number[] = [];
	original.forEach((view, index) => {
		if (keeping.some((kept) => kept.id === view.id)) {
			keptViews.push(view);
			keptIndices.push(index);
		}
	});
	// Nothing kept, nothing added, nothing said: the line is empty, so this is a
	// takedown rather than a post of nothing, and the withdraw path already says
	// it and frees the reference.
	if (keptViews.length === 0 && newFiles.length === 0 && caption === "") {
		withdraw(conv.key, id);
		return;
	}
	if (keptViews.length + newFiles.length > MAX_MESSAGE_FILES) {
		store.deliverActive(store.sysItem(`A message may carry at most ${MAX_MESSAGE_FILES} files.`));
		return;
	}
	const cap = lineRoom(conv, MAX_LINE);
	if (lineCost(caption) > cap) {
		store.deliverActive(store.sysItem(tooLong("Message", cap)));
		return;
	}
	try {
		for (const file of newFiles) validateAttachmentSource(pickedSource(file));
	} catch (err) {
		store.deliverActive(store.sysItem(reason(err)));
		return;
	}
	const measured = await Promise.all(
		newFiles.map((file) => measureImage(file, file.type || "application/octet-stream")),
	);
	// Measuring yields to the browser. If the line or its session went in that
	// window there is nothing left to refile.
	if (convSession(conv.key) !== owner || owner.posted.get(id) !== line) return;
	// Fresh views for the added files, each shown at once from the bytes we hold.
	const newViews = newFiles.map((file, index) => {
		const mime = file.type || "application/octet-stream";
		const view = store.attachmentView({ name: file.name, mime, size: file.size, ...measured[index] });
		return mime.startsWith("image/") ? { ...view, url: keepObjectUrl(owner, view.id, file) } : view;
	});
	const nextViews = [...keptViews, ...newViews];
	const sources = newFiles.map((file, index) => ({ ...pickedSource(file), ...measured[index] }));

	// A direct line hosts its files inline and has no echo to reconcile against,
	// so the refile carries the new files itself and the sender's own copy is
	// painted here, once and for good. The kept files are never re-sent — the
	// receiver holds them — so only the added ones cross the wire.
	if (conv.type === "dm") {
		owner.outgoing.set(id, {
			key: conv.key,
			attachmentIds: newViews.map((view) => view.id),
			files: [...newFiles],
			caption,
		});
		store.updateItem(conv.key, id, { text: caption, attachments: nextViews.length > 0 ? nextViews : undefined });
		owner.outgoing.delete(id);
		try {
			await line.refile(caption, keptIndices, sources);
		} catch (err) {
			for (const view of newViews) releaseHeldFile(owner, view.id);
			store.updateItem(conv.key, id, {
				text: originalText,
				attachments: original.length > 0 ? original : undefined,
			} as Partial<Item>);
			store.deliverActive(store.sysItem(`Could not change that line's files: ${reason(err)}`));
			return;
		}
		// The receiver accepted the replacement. Views no longer on the line must
		// release their local preview URLs now; conversation teardown can no longer
		// discover them by walking history.
		for (const view of original) {
			if (!keptViews.some((kept) => kept.id === view.id)) releaseHeldFile(owner, view.id);
		}
		return;
	}

	// The room path from here. Both were required by the guard for a room line;
	// re-stating them narrows the types and can never actually return.
	if (!room || item.lineId === undefined) return;
	const lineId = item.lineId;
	// Paint the new set and remember it, so the `refiled` echo reconciles against
	// exactly these views rather than replacing them.
	owner.refiling.set(lineId, nextViews);
	owner.outgoing.set(id, {
		key: conv.key,
		attachmentIds: newViews.map((view) => view.id),
		files: [...newFiles],
		caption,
	});
	store.updateItem(conv.key, id, { text: caption, attachments: nextViews });
	owner.outgoing.delete(id);
	let uploads: Ref[] = [];
	try {
		uploads = await Promise.all(sources.map((source) => room.stage(source)));
		if (convSession(conv.key) !== owner || owner.posted.get(id) !== line) {
			await Promise.allSettled(uploads.map((upload) => room.discard(upload)));
			return;
		}
		await line.refile(caption, keptIndices);
	} catch (err) {
		await Promise.allSettled(uploads.map((upload) => room.discard(upload)));
		// Nothing was committed on the room, so put the line back the way it was —
		// caption and files both — and let the added views go, whose bytes were
		// only ever local.
		owner.refiling.delete(lineId);
		for (const view of newViews) releaseHeldFile(owner, view.id);
		store.updateItem(conv.key, id, { text: originalText, attachments: original } as Partial<Item>);
		store.deliverActive(store.sysItem(`Could not change that line's files: ${reason(err)}`));
		return;
	}
	await Promise.all(
		uploads.map((upload, index) =>
			room.upload(
				upload,
				sources[index],
				(sent) => noteAttachmentProgress(owner, conv.key, newViews[index].id, sent),
			).catch((err) => {
				// The refile itself landed; only a byte transfer broke. Say it on the
				// file's own row, the way a first upload's failure does.
				store.updateAttachment(conv.key, newViews[index].id, {
					got: undefined,
					error: reason(err),
					lost: true,
				});
			})
		),
	);
}
/** Stop a send whose bytes are still going.
 *
 * The message is already posted by the time its files are being filled — that
 * order is what lets a bubble appear before its pictures do — so this cannot
 * un-say it. What it does is give back the rest of the reader's bandwidth and
 * leave the send where a stopped one belongs: not sent, with the retry the
 * interface already offers on anything that did not arrive. Stopping and
 * retrying are the same pair the failure path already has, so a reader who
 * picked the wrong sixty-megabyte file has somewhere to go that is not waiting.
 *
 * Only the bytes are tripped. Everything after is the ordinary failure path,
 * which already marks the message and records why against each file. */
export function stopSend(key: string, id: number): void {
	convSession(key)?.outgoing.get(id)?.stop?.abort();
}
/** Re-send a failed file message: every file, not just its caption. */
export function resendFile(key: string, id: number): void {
	const outgoing = convSession(key)?.outgoing.get(id);
	if (outgoing === undefined) return;
	markSend(key, id, "sending");
	for (const fileId of outgoing.attachmentIds) {
		store.updateAttachment(key, fileId, { error: undefined, lost: undefined });
	}
	void uploadPickedFiles(key, id);
}

/** Apply a `refiled` echo: replace one line's file set with the records the
 * room sent.
 *
 * Our own refile has already painted the new views optimistically, in the order
 * the room echoes them back. That case holds each fresh blob under the view
 * already on screen and keeps its local URL, so a kept file keeps its bytes and
 * a newly-added one keeps the copy we uploaded — nothing is downloaded again.
 * Somebody else's refile has no such window, so it replaces the set with fresh
 * views and fetches each image the way a first post does. Either way the files
 * this line no longer carries let go of their bytes and their URL. */
export function applyRefile(
	dir: DirId,
	room: Room,
	key: string,
	lineId: number,
	caption: string,
	records: Attachment[],
): void {
	const owner = dirSession(dir);
	const conv = store.getConv(key);
	if (owner === null || conv === null) {
		releaseRoomAttachments(room, records);
		return;
	}
	const item = conv.history.find((line) => line.kind === "chat" && line.lineId === lineId);
	if (item?.kind !== "chat") {
		releaseRoomAttachments(room, records);
		return;
	}
	const old = item.attachments ?? [];
	const pending = owner.refiling.get(lineId);
	if (pending != null && pending.length === records.length) {
		owner.refiling.delete(lineId);
		// The optimistic views are already on the item and in the echoed order, so
		// hold each fresh blob under its view and leave the URLs alone. A kept file
		// already held a blob from the first post; that one is released before the
		// fresh one takes its place, but its URL stays so the picture never blinks.
		pending.forEach((view, index) => {
			const record = records[index];
			if (record === undefined) return;
			owner.files.get(view.id)?.release();
			owner.files.set(view.id, holdRoomFile(room, record));
		});
		// Whatever this refile dropped is no longer named by the line: release the
		// bytes and URL it was holding.
		for (const view of old) {
			if (!pending.some((kept) => kept.id === view.id)) releaseHeldFile(owner, view.id);
		}
		if (item.text !== caption) store.updateItem(key, item.id, { text: caption });
		return;
	}
	if (pending != null) {
		owner.refiling.delete(lineId);
		trouble(
			"room file refile echo",
			new Error(`expected ${pending.length} files, received ${records.length}`),
		);
	}
	// Not our doing: replace the set outright. The old files go, and each new one
	// arrives as a fresh view the reader fetches, images on their own.
	for (const view of old) releaseHeldFile(owner, view.id);
	const views = records.map((record) =>
		store.attachmentView({
			name: record.name,
			mime: record.mime,
			size: record.size,
			width: record.width,
			height: record.height,
		})
	);
	records.forEach((record, index) => owner.files.set(views[index].id, holdRoomFile(room, record)));
	store.updateItem(key, item.id, { text: caption, attachments: views });
	// Silenced here for the same reason a first delivery is: a refile is that
	// member speaking again, and a line the reader will not see fetches nothing.
	const silenced = silencedFrom(item.from, item.mine, store.get().ignored);
	records.forEach((record, index) => {
		const view = views[index];
		if (fetchesOnArrival(record, silenced)) openAttachment(key, view.id);
	});
}
