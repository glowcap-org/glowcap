// Projection and capability custody for one live local room message.

import { type Message, Room } from "../../../lib/room_client.ts";
import * as store from "../store.ts";
import { type DirId, silencedFrom } from "../types.ts";
import { lineNotShowable, roomCalled } from "../text.ts";
import { notifiesYou } from "../commands.ts";
import { maybeNotify } from "../notify.ts";
import { fetchesOnArrival } from "../media.ts";
import { isStateOnlyRoomEvent } from "../room_event.ts";
import { trouble } from "./common.ts";
import { dirSession } from "./live.ts";
import {
	FILE_GONE_WITH_ITS_CONNECTION,
	holdRoomFile,
	openAttachment,
	releaseHeldFile,
	releaseRoomAttachment,
	releaseRoomAttachments,
} from "./files.ts";
import { applyRefile, confirmRoomEcho } from "./send.ts";

const ROOM_FILE_ECHO_MISSING = "the room did not return this file capability";

/** Project one message after its room pump has proved this membership current.
 * Every attachment occurrence either enters the directory session's file map
 * or is released through the room before this call returns. */
export function projectRoomMessage(dir: DirId, key: string, name: string, room: Room, message: Message): void {
	const { from, text, system, presence, facts, attachments, lineId, change } = message;
	const conv = store.ensureRoom(dir, name, { key });
	store.setRoomMembership(conv.key, "joined");
	if (presence != null) store.applyPresence(conv.key, presence);
	if (isStateOnlyRoomEvent(text, presence, attachments)) {
		releaseRoomAttachments(room, attachments);
		return;
	}
	const unshowable = lineNotShowable(from, text);
	if (unshowable != null) {
		store.deliver(conv.key, store.sysItem(unshowable));
		releaseRoomAttachments(room, attachments);
		return;
	}
	if (change === "edited" && lineId != null) {
		store.applyLineChange(conv.key, lineId, { text, edited: true });
		releaseRoomAttachments(room, attachments);
		return;
	}
	if (change === "withdrawn" && lineId != null) {
		const owner = dirSession(dir);
		const gone = conv.history.find((row) => row.kind === "chat" && row.lineId === lineId);
		if (owner != null && gone?.kind === "chat") {
			for (const view of gone.attachments ?? []) releaseHeldFile(owner, view.id);
		}
		store.applyLineChange(conv.key, lineId, { withdrawn: true });
		releaseRoomAttachments(room, attachments);
		return;
	}
	if (change === "refiled" && lineId != null) {
		applyRefile(dir, room, conv.key, lineId, text, attachments);
		return;
	}
	if (facts?.topic != null) store.setTopic(conv.key, facts.topic);
	if (facts?.lineBytes != null) store.setLineBytes(conv.key, facts.lineBytes);
	if (system) {
		store.deliver(conv.key, store.sysItem(text, presence?.kind === "roster" ? "here" : "shared"));
		releaseRoomAttachments(room, attachments);
		return;
	}
	const nick = store.dirNick(dir);
	const mine = from === nick;
	const echoed = mine ? confirmRoomEcho(conv.key, text) : null;
	const owner = dirSession(dir);
	if (echoed != null) {
		if (lineId != null) store.nameLine(conv.key, echoed.id, lineId);
		if (attachments.length !== echoed.attachmentIds.length) {
			trouble(
				"room file echo",
				new Error(`expected ${echoed.attachmentIds.length} files, received ${attachments.length}`),
			);
			if (owner != null) {
				for (let index = attachments.length; index < echoed.attachmentIds.length; index += 1) {
					const id = echoed.attachmentIds[index];
					releaseHeldFile(owner, id);
					store.updateAttachment(conv.key, id, {
						got: undefined,
						error: ROOM_FILE_ECHO_MISSING,
						lost: true,
					});
				}
			}
		}
		for (const [index, attachment] of attachments.entries()) {
			const id = echoed.attachmentIds[index];
			if (id != null && owner != null) owner.files.set(id, holdRoomFile(room, attachment));
			else releaseRoomAttachment(room, attachment);
		}
	} else {
		const available = owner != null;
		const views = attachments.map((attachment) =>
			store.attachmentView({
				name: attachment.name,
				mime: attachment.mime,
				size: attachment.size,
				width: attachment.width,
				height: attachment.height,
				...(available ? {} : { lost: true, error: FILE_GONE_WITH_ITS_CONNECTION }),
			})
		);
		const item = store.chatItem(from, text, mine, undefined, views.length > 0 ? views : undefined);
		if (owner != null) {
			attachments.forEach((attachment, index) =>
				owner.files.set(views[index].id, holdRoomFile(room, attachment))
			);
		} else releaseRoomAttachments(room, attachments);
		store.deliver(conv.key, lineId == null ? item : { ...item, lineId });
		const silenced = silencedFrom(from, mine, store.get().ignored);
		if (owner != null) {
			attachments.forEach((attachment, index) => {
				if (fetchesOnArrival(attachment, silenced)) openAttachment(conv.key, views[index].id);
			});
		}
	}
	if (!mine && !silencedFrom(from, mine, store.get().ignored) && notifiesYou(text, nick)) {
		maybeNotify(roomCalled(name, conv.held) + " · " + from, text);
	}
}
