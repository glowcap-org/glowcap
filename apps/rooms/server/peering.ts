import { type Argument, type Behavior, currentSession, Ref } from "@pancake/runtime";
import { MAX_ROOM, PEERED_ROOM_READY_TIMEOUT_MS } from "../lib/limits.ts";
import { PUBLICATION_READY, PUBLISH_DURABLE_ROOM, REVOKE } from "../lib/protocol.ts";
import { notifyPublicRoom } from "./discovery.ts";
import {
	cancelForeignRoom,
	commitForeignRoom,
	type ForeignRoomEntry,
	forgetForeignRoom,
	handBack,
	reserveForeignRoom,
} from "./registry.ts";

function revoke(id: string): void {
	const removed = forgetForeignRoom(id);
	if (removed !== null) notifyPublicRoom(removed, "closed", null);
}

/** The separately published authority to add foreign rooms to this directory. */
export function peeringBehavior(): Behavior {
	return (verb: string, args: Argument[]): ReturnType<Behavior> => {
		if (verb !== PUBLISH_DURABLE_ROOM) throw new Error(`directory peering has no method ${verb}`);
		const source = currentSession();
		if (source === null) throw new Error("directory peering is reachable only over a session");
		const name = typeof args[0] === "string" ? args[0] : "";
		const room = args[1];
		if (name.length === 0 || name.length > MAX_ROOM) {
			throw new Error(`publishDurableRoom needs a name of at most ${MAX_ROOM} characters`);
		}
		if (!(room instanceof Ref)) throw new Error("publishDurableRoom needs a room capability");
		const reservation = reserveForeignRoom(name, source);
		let entry: ForeignRoomEntry | null = null;
		let settled = false;
		let finishReady: (() => void) | null = null;
		let failReady: ((error: unknown) => void) | null = null;
		let expiry: ReturnType<typeof setTimeout> | null = null;
		const ready = new Promise<void>((resolve, reject) => {
			finishReady = resolve;
			failReady = reject;
		});
		const failPending = (error: unknown): boolean => {
			if (settled) return false;
			settled = true;
			if (expiry !== null) clearTimeout(expiry);
			cancelForeignRoom(reservation);
			handBack(source, room, "pending peered room");
			failReady?.(error);
			return true;
		};
		expiry = setTimeout(() => {
			failPending(new Error("the handed room did not resolve before the publication deadline"));
		}, PEERED_ROOM_READY_TIMEOUT_MS);
		void source.listen(room).then(
			(resolved) => {
				if (!(resolved instanceof Ref)) {
					failPending(new Error("the handed room did not resolve to a capability"));
					return;
				}
				if (settled) {
					handBack(source, resolved, "late peered room");
					return;
				}
				try {
					const committed = commitForeignRoom(reservation, resolved);
					try {
						notifyPublicRoom(committed, "opened", null);
					} catch (error) {
						revoke(committed.id);
						throw error;
					}
					entry = committed;
					settled = true;
					if (expiry !== null) clearTimeout(expiry);
					handBack(source, room, "pending peered room");
					finishReady?.();
				} catch (error) {
					if (entry === null && !settled && cancelForeignRoom(reservation)) {
						handBack(source, resolved, "unpublished peered room");
					}
					failPending(error);
				}
			},
			(error) => {
				failPending(error);
			},
		);
		// A holder may revoke without first waiting. Keep that lifecycle from
		// surfacing as an unhandled JavaScript rejection; `ready` still reports it.
		void ready.catch(() => {});
		try {
			const lease = source.spawn((leaseVerb) => {
				if (leaseVerb === PUBLICATION_READY) return ready.then(() => null);
				if (leaseVerb === REVOKE) {
					if (entry === null) {
						failPending(new Error("room publication was revoked before it became ready"));
					} else revoke(entry.id);
					return null;
				}
				throw new Error(`room publication lease has no method ${leaseVerb}`);
			});
			return lease;
		} catch (error) {
			failPending(error);
			throw error;
		}
	};
}
