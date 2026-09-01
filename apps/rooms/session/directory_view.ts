// Bounded live discovery state for one durable directory connection.

import type { DirectoryMember, RoomEvent, RoomInfo } from "../lib/directory_publications.ts";
import { MAX_SESSION_DIRECTORY_ROWS } from "../lib/limits.ts";
import type { RoomsSessionDirectoryView } from "../lib/session/client.ts";

function sameRoom(left: RoomInfo, right: RoomInfo): boolean {
	return left.id === right.id && left.name === right.name && left.kind === right.kind && left.count === right.count &&
		left.origin === right.origin && left.proof === right.proof;
}

export class DurableDirectoryView {
	readonly #directoryId: string;
	readonly #rooms = new Map<string, RoomInfo>();
	readonly #peers = new Map<string, DirectoryMember>();
	#truncated = false;

	constructor(directoryId: string) {
		this.#directoryId = directoryId;
	}

	replaceRooms(rooms: readonly RoomInfo[]): void {
		this.#rooms.clear();
		for (const room of rooms.slice(0, MAX_SESSION_DIRECTORY_ROWS)) this.#rooms.set(room.id, room);
		if (rooms.length > MAX_SESSION_DIRECTORY_ROWS) this.#markTruncated();
	}

	roomNamed(name: string): RoomInfo | null {
		const key = name.toLowerCase();
		for (const room of this.#rooms.values()) {
			if (room.name.toLowerCase() === key) return room;
		}
		return null;
	}

	room(id: string): RoomInfo | null {
		return this.#rooms.get(id) ?? null;
	}

	apply(event: RoomEvent): boolean {
		if (event.kind === "truncated") return this.#markTruncated();
		if (event.entry == null) {
			return this.#setPeer(
				{ name: event.name, registrationId: event.registrationId },
				event.kind === "registered",
			);
		}
		if (event.kind === "closed") return this.#rooms.delete(event.entry.id);
		const prior = this.#rooms.get(event.entry.id);
		if (prior != null) {
			this.#rooms.set(event.entry.id, event.entry);
			return !sameRoom(prior, event.entry);
		}
		if (this.#rooms.size === MAX_SESSION_DIRECTORY_ROWS) {
			return this.#markTruncated();
		}
		this.#rooms.set(event.entry.id, event.entry);
		return true;
	}

	snapshot(limit = MAX_SESSION_DIRECTORY_ROWS): RoomsSessionDirectoryView {
		const rooms = [...this.#rooms.values()].slice(0, limit);
		const peers = [...this.#peers.values()].slice(0, Math.max(0, limit - rooms.length));
		return {
			directoryId: this.#directoryId,
			rooms,
			peers,
			truncated: this.#truncated || rooms.length < this.#rooms.size || peers.length < this.#peers.size,
		};
	}

	#setPeer(peer: DirectoryMember, reachable: boolean): boolean {
		const key = peer.name.toLowerCase();
		if (!reachable) {
			if (this.#peers.get(key)?.registrationId !== peer.registrationId) return false;
			return this.#peers.delete(key);
		}
		if (this.#peers.get(key)?.registrationId === peer.registrationId) return false;
		if (this.#peers.size === MAX_SESSION_DIRECTORY_ROWS) {
			return this.#markTruncated();
		}
		this.#peers.set(key, peer);
		return true;
	}

	#markTruncated(): boolean {
		if (this.#truncated) return false;
		this.#truncated = true;
		return true;
	}
}
