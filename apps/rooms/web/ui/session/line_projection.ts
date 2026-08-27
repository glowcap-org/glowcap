// Projection of live attached-session lines into the presentation store.

import type { RoomsSessionLineEvent } from "../../../lib/rooms_session.ts";
import { sameArchiveCoordinates } from "../../../lib/archive.ts";
import * as store from "../store.ts";
import { lineNotShowable } from "../text.ts";
import { maybeNotify } from "../notify.ts";
import { isStateOnlyRoomEvent } from "../room_event.ts";
import { applyTyping } from "../net/typing.ts";
import { fetchesOnArrival } from "../media.ts";
import { type AttachmentView, silencedFrom } from "../types.ts";
import type { AttachedSessionFiles } from "./attached_files.ts";

/** Own the synchronous handoff from one accepted session event to either the
 * visible log or file-capability release. Snapshot topology remains in the
 * parent projection; this owner only resolves its stable conversation key. */
export class AttachedLineProjection {
	readonly #conversationKey: (conversationId: string) => string | null;
	readonly #files: AttachedSessionFiles | null;

	constructor(conversationKey: (conversationId: string) => string | null, files: AttachedSessionFiles | null) {
		this.#conversationKey = conversationKey;
		this.#files = files;
	}

	apply(event: RoomsSessionLineEvent): void {
		const key = this.#conversationKey(event.conversationId);
		if (key == null) {
			this.#releaseIncoming(event);
			return;
		}
		const conversation = store.getConv(key);
		if (conversation == null) {
			this.#releaseIncoming(event);
			return;
		}
		const mine = event.from === store.dirNick(conversation.dir);
		if (conversation.type === "dm") store.setDmLine(key, "live");
		store.patchDir(conversation.dir, { session: "connected", statusText: "" });
		if (event.presence?.kind === "typing") {
			applyTyping(key, event.presence.name, event.presence.on);
			this.#releaseIncoming(event);
			return;
		}
		if (event.presence != null) store.applyPresence(key, event.presence);
		if (isStateOnlyRoomEvent(event.text, event.presence, event.attachments)) {
			this.#releaseIncoming(event);
			return;
		}
		const unshowable = lineNotShowable(event.from, event.text);
		if (unshowable != null) {
			store.deliver(key, store.sysItem(unshowable));
			this.#releaseIncoming(event);
			return;
		}
		const recorded = event.history == null
			? undefined
			: conversation.history.find((item) =>
				item.kind === "chat" && sameArchiveCoordinates(item.history, event.history)
			);
		const named = recorded ??
			(event.lineId == null
				? undefined
				: conversation.history.find((item) => item.kind === "chat" && item.lineId === event.lineId));
		if (event.change === "edited" && event.lineId != null) {
			if (named?.kind === "chat") store.updateItem(key, named.id, { text: event.text, edited: true });
			this.#releaseIncoming(event);
			return;
		}
		if (event.change === "withdrawn" && event.lineId != null) {
			if (named?.kind === "chat") this.#files?.release(named.attachments ?? []);
			if (named?.kind === "chat") store.updateItem(key, named.id, { withdrawn: true });
			this.#releaseIncoming(event);
			return;
		}
		if (event.change === "refiled" && event.lineId != null) {
			if (named?.kind !== "chat") {
				this.#releaseIncoming(event);
				return;
			}
			this.#files?.release(named.attachments ?? []);
			const attachments = this.#holdIncoming(event);
			store.updateItem(key, named.id, {
				text: event.text,
				attachments: attachments.length === 0 ? undefined : attachments,
			});
			this.#openArrivingImages(key, event, mine, attachments);
			return;
		}
		if (event.facts?.topic != null) store.setTopic(key, event.facts.topic);
		if (event.facts?.lineBytes != null) store.setLineBytes(key, event.facts.lineBytes);
		if (event.system) {
			store.deliver(key, store.sysItem(event.text, event.presence?.kind === "roster" ? "here" : "shared"));
			this.#releaseIncoming(event);
			return;
		}
		const attachments = this.#holdIncoming(event);
		if (recorded?.kind === "chat") {
			if (attachments.length > 0) this.#files?.release(recorded.attachments ?? []);
			store.updateItem(key, recorded.id, {
				text: event.text,
				at: event.at,
				...(event.lineId == null ? {} : { lineId: event.lineId }),
				...(event.editable ? { held: true } : {}),
				...(attachments.length === 0 ? {} : { attachments }),
			});
			this.#openArrivingImages(key, event, mine, attachments);
			return;
		}
		const item = store.chatItem(event.from, event.text, mine, undefined, undefined, event.at);
		store.deliver(key, {
			...item,
			...(event.history == null ? {} : { history: event.history }),
			...(attachments.length === 0 ? {} : { attachments }),
			...(event.lineId == null ? {} : { lineId: event.lineId }),
			...(event.editable ? { held: true } : {}),
		});
		this.#openArrivingImages(key, event, mine, attachments);
		if (
			conversation.type === "dm" && !mine && store.get().activeKey !== key &&
			!silencedFrom(event.from, false, store.get().ignored)
		) maybeNotify(event.from, event.text || event.attachments[0]?.name || "sent a file");
	}

	#holdIncoming(event: RoomsSessionLineEvent): AttachmentView[] {
		if (event.attachments.length === 0) return [];
		const files = this.#files;
		if (files == null) throw new Error("the attached line projection has no file capability owner");
		return event.attachments.map((attachment) => files.hold(attachment));
	}

	#releaseIncoming(event: RoomsSessionLineEvent): void {
		if (event.attachments.length === 0) return;
		if (this.#files == null) throw new Error("the attached line projection has no file capability owner");
		this.#files.releaseIncoming(event.attachments);
	}

	#openArrivingImages(
		key: string,
		event: RoomsSessionLineEvent,
		mine: boolean,
		views: readonly AttachmentView[],
	): void {
		const silenced = silencedFrom(event.from, mine, store.get().ignored);
		for (const [index, view] of views.entries()) {
			const attachment = event.attachments[index];
			if (attachment != null && fetchesOnArrival(attachment, silenced)) this.#files?.open(key, view.id);
		}
	}
}
