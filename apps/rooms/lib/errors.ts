// The rooms failure taxonomy.
//
// A broken OCapN promise carries a *string* reason — a thrown error's message — so a
// stable code rides at the front of it and a peer branches on the code, never on the
// prose of a message. The directory and rooms throw a `RoomError` with one of the
// codes below; callers extract the reason string and reconstruct the typed error
// with `RoomError.from()`. Change the human wording freely; the code is the contract.
//
// `roomErrorOf` is the reader. What varies per binding is the carrier: here an
// awaited send breaks as a `VowBroken` holding the wire's reason, so this is
// where that reason is unwrapped before the portable `RoomError.from` parses the
// code out of it. Other client languages mirror the codes below and read them
// through their own binding's carrier.
//
// Only the failures an app actually reacts to are typed. A plain `Error` (a missing
// capability, a bad verb) is an invariant violation nobody branches on — those stay
// untyped, and `RoomError.from()` returns null for them.

import { VowBroken } from "@pancake/runtime";

/** A room subscribe whose nick is already claimed in that room. */
export const NICK_TAKEN = "nick-taken";
/** `enter` on a room that is not open. */
export const NO_SUCH_ROOM = "no-such-room";
/** `open` on a room that already exists. */
export const ROOM_EXISTS = "room-exists";
/** `open` with a room name longer than `MAX_ROOM`. */
export const ROOM_TOO_LONG = "room-too-long";
/** A `link` that would make one more room name durable after the server has
 * reached `MAX_ROOM_LINKS`. Existing linked rooms still return their links. */
export const ROOM_LINKS_FULL = "room-links-full";
/** An introduction to a member the directory has no registration for. */
export const PEER_OFFLINE = "peer-offline";
/** An introduction the member has not minted an inbox for. The directory has
 * asked them; retry when the register inbox hears `notify("introducible", peer)`
 * (see `protocol.ts`). */
export const INTRODUCTION_PENDING = "introduction-pending";
/** A verb that needs the caller's own registered name, from a connection holding
 * none. `register` first. */
export const NOT_REGISTERED = "not-registered";
/** A register whose nick is longer than `MAX_NICK`. The nick is the key every
 * member files an inbox under, so the directory caps it rather than passing an
 * arbitrary-length name on to them. */
export const NICK_TOO_LONG = "nick-too-long";
/** A register whose locator names somewhere other than the registrant. The
 * directory hands that locator to everyone it introduces, who dial it — so a
 * locator it cannot tie to the caller is a dial it would be aiming on their
 * behalf at an address of the caller's choosing. */
export const NOT_YOUR_LOCATOR = "not-your-locator";
/** A `post` carrying trailing arguments. The room composes what rides after a
 * line's text — presence, typing, and the file record it builds for an
 * attachment — so a member that supplies its own is refused rather than
 * relayed, since members read those positions as the room's word. */
export const BAD_ATTACHMENT = "bad-attachment";
/** An `attach` the room will not take: a file over `MAX_ATTACHMENT_BYTES`, a
 * name or type over its cap, or a member already holding
 * `MAX_MESSAGE_FILES` unposted uploads. */
export const ATTACHMENT_REFUSED = "attachment-refused";
/** A `write` before publication or past the size declared at `attach`. */
export const UPLOAD_INCOMPLETE = "upload-incomplete";
/** A `read` on a file the room has dropped to stay under its media ceiling.
 * The reference stays valid and says so plainly; it does not answer an empty
 * file, which a reader could not tell from a real one. */
export const BLOB_EXPIRED = "blob-expired";

export type RoomErrorCode =
	| typeof NICK_TAKEN
	| typeof NO_SUCH_ROOM
	| typeof ROOM_EXISTS
	| typeof ROOM_TOO_LONG
	| typeof ROOM_LINKS_FULL
	| typeof PEER_OFFLINE
	| typeof INTRODUCTION_PENDING
	| typeof NOT_REGISTERED
	| typeof NICK_TOO_LONG
	| typeof NOT_YOUR_LOCATOR
	| typeof BAD_ATTACHMENT
	| typeof ATTACHMENT_REFUSED
	| typeof UPLOAD_INCOMPLETE
	| typeof BLOB_EXPIRED;

const CODES = new Set<string>([
	NICK_TAKEN,
	NO_SUCH_ROOM,
	ROOM_EXISTS,
	ROOM_TOO_LONG,
	ROOM_LINKS_FULL,
	PEER_OFFLINE,
	INTRODUCTION_PENDING,
	NOT_REGISTERED,
	NICK_TOO_LONG,
	NOT_YOUR_LOCATOR,
	BAD_ATTACHMENT,
	ATTACHMENT_REFUSED,
	UPLOAD_INCOMPLETE,
	BLOB_EXPIRED,
]);

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
		// A break reason reaches a caller as the message of a thrown error, and the
		// binding may have said something of its own first ("pancake error -14: ").
		// The code is a segment of that message, not necessarily its head, so look
		// for it across the colons rather than only at the front.
		const parts = reason.split(": ");
		for (let i = 0; i < parts.length; i += 1) {
			if (CODES.has(parts[i])) {
				return new RoomError(parts[i] as RoomErrorCode, parts.slice(i + 1).join(": "));
			}
		}
		return null;
	}
}

/** The typed `RoomError` a caught failure carries, or null. Reads the
 * broken-promise reason (a `VowBroken` from an awaited send) or a plain error
 * message, then parses the code out of it. */
export function roomErrorOf(err: unknown): RoomError | null {
	if (err instanceof RoomError) return err;
	const reason = err instanceof VowBroken ? err.reason : err instanceof Error ? err.message : String(err);
	return RoomError.from(reason);
}
