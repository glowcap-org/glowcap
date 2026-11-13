// The durable room and manager links one room client holds.

import type { Ref, Session } from "@glowcap/runtime";
import { ask } from "../ask.ts";
import { LINK } from "../protocol.ts";
import { parseRoomsSturdyref } from "../locator.ts";
import { type RoomAuthorityChange, roomAuthorityToken } from "./authority.ts";
import { RoomManager } from "./manager.ts";

const swissDecoder = new TextDecoder("utf-8", { fatal: true });

/** The durable authority one room membership has accumulated: the room
 * sturdyref and the manager sturdyref, with the tokens that name them. */
export class RoomLinks {
	readonly #session: Session;
	readonly #room: Ref;
	#roomLink: string | null = null;
	#managerLink: string | null = null;
	#roomToken: string | null = null;
	#managerToken: string | null = null;

	constructor(session: Session, room: Ref) {
		this.#session = session;
		this.#room = room;
	}

	/** Create or recover the room's durable sturdyref. */
	async link(): Promise<string> {
		const authority = this.#managerLink == null
			? await this.#roomAuthority()
			: await this.#roomAuthorityFromManager(this.#managerLink);
		this.#roomLink = authority.link;
		this.#roomToken = authority.swiss;
		return authority.link;
	}

	async #roomAuthorityFromManager(managerLink: string): Promise<{ swiss: string; link: string }> {
		const manager = await RoomManager.take(this.#session, this.#room, managerLink);
		const link = await manager.roomLink();
		const swiss = swissDecoder.decode(parseRoomsSturdyref(link).swissnum);
		if (swiss === "") throw new Error("the room manager answered a link with no authority");
		return { swiss, link };
	}

	async #roomAuthority(): Promise<{ swiss: string; link: string }> {
		const link = await ask(this.#session, this.#room, LINK, [], "the room did not answer linking itself");
		if (typeof link !== "string" || link.length === 0) {
			throw new Error("link() did not return a sturdyref");
		}
		const swiss = swissDecoder.decode(parseRoomsSturdyref(link).swissnum);
		if (swiss === "") throw new Error("the room answered a sturdyref with no authority");
		return { swiss, link };
	}

	async takeManager(managerLink: string): Promise<void> {
		await RoomManager.take(this.#session, this.#room, managerLink);
		this.#managerLink = managerLink;
		this.#managerToken = roomAuthorityToken(managerLink);
	}

	get roomLink(): string | null {
		return this.#roomLink;
	}

	get managerLink(): string | null {
		return this.#managerLink;
	}

	/** Forget authority the server explicitly rotated. */
	forget(change: RoomAuthorityChange): void {
		if (change.kind === "room" && this.#roomToken === change.token) {
			this.#roomLink = null;
			this.#roomToken = null;
		}
		if (change.kind === "manager" && this.#managerToken === change.token) {
			this.#managerLink = null;
			this.#managerToken = null;
		}
	}
}
