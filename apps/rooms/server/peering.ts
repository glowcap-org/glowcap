import { type Argument, type Behavior, currentSession, Ref, type Session } from "@pancake/runtime";
import { MAX_ROOM, PEERED_ROOM_READY_TIMEOUT_MS } from "../lib/limits.ts";
import { PUBLICATION_READY, PUBLISH_DURABLE_ROOM, REVOKE } from "../lib/protocol.ts";
import { notifyPublicRoom } from "./discovery.ts";
import type { RoomServerContext } from "./context.ts";
import type { ForeignRoomEntry } from "./registry.ts";
import type { OperatorRevision } from "./operator/revision.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";

export interface PendingOperatorPublication {
	readonly id: string;
	readonly name: string;
	readonly origin: string;
	readonly proof: "authenticated" | "session";
	cancel(): void;
}

/** One server's in-flight peered publications. A second server does not see
 * reservations this table still holds. */
export class PendingPeering {
	readonly #pending = new Map<string, PendingOperatorPublication>();

	constructor(readonly operator: OperatorRevision) {}

	*rows(): Iterable<Pick<PendingOperatorPublication, "id" | "name" | "origin" | "proof">> {
		for (const { id, name, origin, proof } of this.#pending.values()) {
			yield { id, name, origin, proof };
		}
	}

	set(publication: PendingOperatorPublication): void {
		this.#pending.set(publication.id, publication);
		this.operator.noteChange();
	}

	drop(id: string): boolean {
		if (!this.#pending.delete(id)) return false;
		this.operator.noteChange();
		return true;
	}

	remove(id: string): boolean {
		const pending = this.#pending.get(id);
		if (pending == null) return false;
		pending.cancel();
		return true;
	}
}

function revoke(ctx: RoomServerContext, id: string): void {
	const removed = ctx.live.forgetForeignRoom(id);
	if (removed !== null) notifyPublicRoom(ctx, removed, "closed", null);
}

/** The separately published authority to add foreign rooms to this directory. */
export function peeringBehavior(ctx: RoomServerContext): Behavior {
	return (verb: string, args: Argument[]): ReturnType<Behavior> => {
		const source = currentSession();
		if (source == null) throw new Error("directory peering is reachable only over a session");
		if (verb !== PUBLISH_DURABLE_ROOM) {
			if (hasCapabilityArguments(args)) {
				throwAfterReleasingCapabilities(
					source,
					args,
					new Error(`directory peering ${verb} does not take capability arguments`),
				);
			}
			throw new Error(`directory peering has no method ${verb}`);
		}
		const name = typeof args[0] === "string" ? args[0] : "";
		const room = args[1];
		if (args.length !== 2 || name.length === 0 || name.length > MAX_ROOM || !(room instanceof Ref)) {
			throwAfterReleasingCapabilities(
				source,
				args,
				new Error(
					`publishDurableRoom needs a name of at most ${MAX_ROOM} characters and one room capability`,
				),
			);
		}
		let reservation: ReturnType<RoomServerContext["live"]["reserveForeignRoom"]>;
		try {
			reservation = ctx.live.reserveForeignRoom(name, source);
		} catch (error) {
			ctx.journal.release(source, room, "unreserved peered room");
			throw error;
		}
		let entry: ForeignRoomEntry | null = null;
		let settled = false;
		let finishReady: (() => void) | null = null;
		let failReady: ((error: unknown) => void) | null = null;
		let expiry: ReturnType<typeof setTimeout> | null = null;
		const ready = new Promise<void>((resolve, reject) => {
			finishReady = resolve;
			failReady = reject;
		});
		// A holder may revoke without first waiting, and admission itself may
		// refuse below. Claim the rejection before either path can settle it.
		void ready.catch(() => {});
		const failPending = (error: unknown): boolean => {
			if (settled) return false;
			settled = true;
			ctx.peering.drop(reservation.id);
			if (expiry !== null) clearTimeout(expiry);
			ctx.live.cancelForeignRoom(reservation);
			ctx.journal.release(source, room, "pending peered room");
			failReady?.(error);
			return true;
		};
		ctx.peering.set({
			id: reservation.id,
			name: reservation.name,
			origin: reservation.origin,
			proof: reservation.proof,
			cancel: () => {
				failPending(new Error("the Rooms operator removed the pending room publication"));
			},
		});
		let resolution: ReturnType<Session["listen"]>;
		try {
			resolution = source.listen(room);
		} catch (error) {
			failPending(error);
			throw error;
		}
		expiry = setTimeout(() => {
			failPending(new Error("the handed room did not resolve before the publication deadline"));
		}, PEERED_ROOM_READY_TIMEOUT_MS);
		void resolution.then(
			(resolved) => {
				if (!(resolved instanceof Ref)) {
					failPending(new Error("the handed room did not resolve to a capability"));
					return;
				}
				if (settled) {
					ctx.journal.release(source, resolved, "late peered room");
					return;
				}
				try {
					ctx.peering.drop(reservation.id);
					const committed = ctx.live.commitForeignRoom(reservation, resolved);
					try {
						notifyPublicRoom(ctx, committed, "opened", null);
					} catch (error) {
						revoke(ctx, committed.id);
						throw error;
					}
					entry = committed;
					settled = true;
					if (expiry !== null) clearTimeout(expiry);
					ctx.journal.release(source, room, "pending peered room");
					finishReady?.();
				} catch (error) {
					if (entry === null && !settled && ctx.live.cancelForeignRoom(reservation)) {
						ctx.journal.release(source, resolved, "unpublished peered room");
					}
					failPending(error);
				}
			},
			(error) => {
				failPending(error);
			},
		);
		try {
			const lease = source.spawn((leaseVerb, leaseArgs) => {
				const caller = currentSession();
				if (caller == null) throw new Error("a room publication lease is reachable only over a session");
				if (hasCapabilityArguments(leaseArgs)) {
					throwAfterReleasingCapabilities(
						caller,
						leaseArgs,
						new Error(`room publication lease ${leaseVerb} does not take capability arguments`),
					);
				}
				if (leaseArgs.length !== 0) throw new Error(`${leaseVerb} takes no arguments`);
				if (leaseVerb === PUBLICATION_READY) return ready.then(() => null);
				if (leaseVerb === REVOKE) {
					if (entry === null) {
						failPending(new Error("room publication was revoked before it became ready"));
					} else revoke(ctx, entry.id);
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
