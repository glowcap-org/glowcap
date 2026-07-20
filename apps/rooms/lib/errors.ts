// The rooms failure taxonomy.
//
// A broken OCapN promise carries a *string* reason — a thrown error's message — so a
// stable code rides at the front of it and a peer branches on the code, never on the
// prose of a message. The directory and rooms throw a `RoomError` with one of the
// codes below; callers extract the reason string and reconstruct the typed error
// with `RoomError.from()`. Change the human wording freely; the code is the contract.
//
// Only the failures an app actually reacts to are typed. A plain `Error` (a missing
// capability, a bad verb) is an invariant violation nobody branches on — those stay
// untyped, and `RoomError.from()` returns null for them.

/** A room subscribe whose nick is already claimed in that room. */
export const NICK_TAKEN = "nick-taken";
/** `enter` on a room that is not open. */
export const NO_SUCH_ROOM = "no-such-room";
/** `open` on a room that already exists. */
export const ROOM_EXISTS = "room-exists";
/** An introduction to a member the directory has no registration for. */
export const PEER_OFFLINE = "peer-offline";

export type RoomErrorCode =
	| typeof NICK_TAKEN
	| typeof NO_SUCH_ROOM
	| typeof ROOM_EXISTS
	| typeof PEER_OFFLINE;

const CODES = new Set<string>([NICK_TAKEN, NO_SUCH_ROOM, ROOM_EXISTS, PEER_OFFLINE]);

/** A failure with a machine-readable code. The message the wire carries is
 * `"<code>: <detail>"`, so a peer can reconstruct the code with `RoomError.from`. */
export class RoomError extends Error {
	constructor(readonly code: RoomErrorCode, readonly detail: string) {
		super(`${code}: ${detail}`);
		this.name = "RoomError";
	}

	/** Reconstruct the typed error from a break reason, or null if the reason carries
	 * no known code (an anonymous failure). */
	static from(reason: string): RoomError | null {
		const i = reason.indexOf(": ");
		const code = i < 0 ? reason : reason.slice(0, i);
		if (!CODES.has(code)) return null;
		return new RoomError(code as RoomErrorCode, i < 0 ? "" : reason.slice(i + 2));
	}
}
