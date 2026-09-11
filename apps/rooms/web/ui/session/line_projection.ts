import type { AttachedLineEvent as RoomsSessionLineEvent } from "./remote.ts";
// Projection of live attached-session lines into the presentation store.

import * as store from "../store.ts";
import { sameArchiveCoordinates } from "../../../lib/archive/coordinates.ts";
import { lineNotShowable } from "../text.ts";
import { maybeNotify } from "../notify.ts";
import { isStateOnlyRoomEvent } from "../room_event.ts";
import { applyTyping } from "../typing.ts";
import { fetchesOnArrival } from "../media.ts";
import { type AttachmentView, type DirId, silencedFrom } from "../types.ts";
import { type AttachedSessionFiles, EARLIER_CONNECTION_BYTES_UNAVAILABLE } from "./attached_files.ts";
import type { RoomsPageContext } from "../page.ts";

/** Own the synchronous handoff from one accepted session event to either the
 * visible log or file-capability release. Snapshot topology remains in the
 * parent projection; this owner only resolves its stable conversation key. */
export class AttachedLineProjection {
	readonly #conversationKey: (conversationId: string) => string | null;
	readonly #files: AttachedSessionFiles | null;
	readonly #page: RoomsPageContext;

	constructor(
		conversationKey: (conversationId: string) => string | null,
		files: AttachedSessionFiles | null,
		page: RoomsPageContext,
	) {
		this.#conversationKey = conversationKey;
		this.#files = files;
		this.#page = page;
	}

	apply(event: RoomsSessionLineEvent): void {
		const key = this.#conversationKey(event.conversationId);
		if (key == null) {
			this.#releaseIncoming(event);
			return;
		}
		const conversation = store.getConv(this.#page.projection, key);
		if (conversation == null) {
			this.#releaseIncoming(event);
			return;
		}
		const mine = event.from === store.dirNick(this.#page.projection, conversation.dir);
		if (conversation.type === "dm") store.setDmLine(this.#page.projection, key, "live");
		if (event.presence?.kind === "typing") {
			applyTyping(this.#page, key, event.presence.name, event.presence.on);
			this.#releaseIncoming(event);
			return;
		}
		if (isStateOnlyRoomEvent(event.text, event.presence, event.attachments)) {
			this.#releaseIncoming(event);
			return;
		}
		const unshowable = lineNotShowable(event.from, event.text);
		if (unshowable != null) {
			store.deliver(this.#page.projection, key, store.sysItem(this.#page.projection, unshowable));
			this.#releaseIncoming(event);
			return;
		}
		const history = store.historyOf(this.#page.projection, key);
		const recorded = event.history == null
			? undefined
			: history.find((item) => item.kind === "chat" && sameArchiveCoordinates(item.history, event.history));
		const named = recorded ??
			(event.lineId == null || event.history != null
				? undefined
				: history.find((item) => item.kind === "chat" && item.lineId === event.lineId)) ??
			(event.change === "said" && mine
				? history.find((item) =>
					item.kind === "chat" && item.mine && item.state != null && item.text === event.text &&
					(item.attachments?.length ?? 0) === event.attachments.length
				)
				: undefined);
		if (event.change === "edited" && event.lineId != null) {
			if (named?.kind === "chat") {
				store.updateItem(this.#page.projection, key, named.id, { text: event.text, edited: true });
			}
			this.#releaseIncoming(event);
			return;
		}
		if (event.change === "withdrawn" && event.lineId != null) {
			if (named?.kind === "chat") this.#files?.release(named.attachments ?? []);
			if (named?.kind === "chat") {
				// The event is the room's authoritative outcome. Updating the item also
				// retires a matching composer intent while preserving any newer input.
				store.updateItem(this.#page.projection, key, named.id, { withdrawn: true });
			}
			this.#releaseIncoming(event);
			return;
		}
		if (event.change === "refiled" && event.lineId != null) {
			if (named?.kind !== "chat") {
				this.#releaseIncoming(event);
				return;
			}
			this.#files?.release(named.attachments ?? []);
			const attachments = this.#holdIncoming(event, conversation.dir);
			store.updateItem(this.#page.projection, key, named.id, {
				text: event.text,
				attachments: attachments.length === 0 ? undefined : attachments,
			});
			this.#openArrivingImages(key, event, mine, attachments);
			return;
		}
		if (event.facts?.topic != null) store.setTopic(this.#page.projection, key, event.facts.topic);
		if (event.facts?.lineBytes != null) store.setLineBytes(this.#page.projection, key, event.facts.lineBytes);
		if (event.facts?.bridge != null) store.setBridgeFacts(this.#page.projection, key, event.facts.bridge);
		if (event.system) {
			store.deliver(
				this.#page.projection,
				key,
				store.sysItem(this.#page.projection, event.text, event.presence?.kind === "roster" ? "here" : "shared"),
			);
			this.#releaseIncoming(event);
			return;
		}
		if (named?.kind === "chat" && sameAttachments(named.attachments ?? [], event.attachments)) {
			// Replayed authority carries fresh capability occurrences for the same
			// immutable bytes. Keep settled object URLs and transfer state; only the
			// duplicate occurrences need releasing. An optimistic send also owns its
			// presentation identity: confirmation settles authority and send state,
			// but must not regroup or remount the bubble by replacing its local time.
			store.updateItem(this.#page.projection, key, named.id, {
				text: event.text,
				...(named.state == null ? { at: event.at } : {}),
				state: undefined,
				...(event.history == null ? {} : { history: event.history }),
				...(event.lineId == null ? {} : { order: event.lineId, lineId: event.lineId }),
				...(event.editable ? { held: true } : {}),
			});
			this.#releaseIncoming(event);
			return;
		}
		const attachments = this.#holdIncoming(event, conversation.dir);
		if (recorded?.kind === "chat") {
			if (attachments.length > 0) this.#files?.release(recorded.attachments ?? []);
			store.updateItem(this.#page.projection, key, recorded.id, {
				text: event.text,
				at: event.at,
				...(event.lineId == null ? {} : { order: event.lineId }),
				...(event.lineId == null ? {} : { lineId: event.lineId }),
				...(event.editable ? { held: true } : {}),
				...(attachments.length === 0 ? {} : { attachments }),
			});
			this.#openArrivingImages(key, event, mine, attachments);
			return;
		}
		const item = store.chatItem(
			this.#page.projection,
			event.from,
			event.text,
			mine,
			undefined,
			undefined,
			event.at,
		);
		store.deliver(this.#page.projection, key, {
			...item,
			...(event.history == null ? {} : { history: event.history }),
			...(event.history == null || event.lineId == null ? {} : { order: event.lineId }),
			...(attachments.length === 0 ? {} : { attachments }),
			...(event.lineId == null ? {} : { lineId: event.lineId }),
			...(event.editable ? { held: true } : {}),
		});
		this.#openArrivingImages(key, event, mine, attachments);
		if (
			conversation.type === "dm" && !mine && this.#page.projection.get().activeKey !== key &&
			!silencedFrom(event.from, false, this.#page.projection.get().ignored)
		) maybeNotify(this.#page.projection, event.from, event.text || event.attachments[0]?.name || "sent a file");
	}

	#holdIncoming(event: RoomsSessionLineEvent, directory: DirId): AttachmentView[] {
		if (event.attachments.length === 0) return [];
		const files = this.#files;
		if (files == null) throw new Error("the attached line projection has no file capability owner");
		const unavailable = this.#page.projection.get().dirs.get(directory)?.session === "disconnected"
			? EARLIER_CONNECTION_BYTES_UNAVAILABLE
			: undefined;
		return event.attachments.map((attachment) => files.hold(attachment, unavailable));
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
		const silenced = silencedFrom(event.from, mine, this.#page.projection.get().ignored);
		for (const [index, view] of views.entries()) {
			const attachment = event.attachments[index];
			if (attachment != null && fetchesOnArrival(attachment, silenced)) this.#files?.open(key, view.id);
		}
	}
}

function sameAttachments(
	views: readonly AttachmentView[],
	incoming: RoomsSessionLineEvent["attachments"],
): boolean {
	return views.length === incoming.length && views.every((view, index) => {
		const attachment = incoming[index];
		return attachment != null && view.name === attachment.name && view.mime === attachment.mime &&
			view.size === attachment.size && (view.width ?? 0) === attachment.width &&
			(view.height ?? 0) === attachment.height;
	});
}
