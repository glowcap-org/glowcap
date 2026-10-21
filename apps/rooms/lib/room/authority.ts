// Opaque identities used to synchronize durable room authority lifecycles. status-allow: purpose clause

import { parseRoomsSturdyref } from "../locator.ts";

const swissDecoder = new TextDecoder("utf-8", { fatal: true });

export type RoomAuthorityKind = "manager" | "steward" | "room";

/** A pushed authority retirement. `token` identifies the exact sturdyref
 * generation that ended, so a delayed notice cannot erase a later grant. */
export interface RoomAuthorityChange {
	readonly kind: RoomAuthorityKind;
	readonly token: string;
	readonly claimable: boolean;
}

/** The opaque durable-publication identity carried by a Rooms sturdyref.
 * Applications compare it for lifecycle synchronization. Transport, codec,
 * and CapTP profile selection remain owned below this layer. */
export function roomAuthorityToken(sturdyref: string): string {
	const token = swissDecoder.decode(parseRoomsSturdyref(sturdyref).swissnum);
	if (token === "") throw new Error("a room authority sturdyref has no publication identity");
	return token;
}
