// What a call over an attached page's link to its session needs of that link.
// A handle is read with its stamp and called in the same turn, so a loss is
// always charged to the link the call ran on.
import { connectionLost } from "../../../../lib/text/failure.ts";
import type { LocalRefusalKey } from "../../../../lib/text/local_refusals.ts";
import { RoomsError, SESSION_UNREACHABLE } from "../../../../lib/error_codes.ts";
import type { RoomsManagedWorkspace } from "../../../../../../zig-out/wasm/rooms/rooms_browser.js";

/** The generation of the link a page starts on. */
export const FIRST_LINK = 0;

/** Which link a handle travels. Each new link carries a newer stamp, so a loss
 * over a replaced link is that link's and leaves its successor alone. */
export interface Stamp {
	readonly generation: number;
}

/** The stamp `link` carries, alone, so what keeps it holds no handle alive
 * past the link that handle travels. */
export function stampOf(link: Stamp): Stamp {
	return { generation: link.generation };
}

/** The current link's workspace handle and its stamp, read together. */
export interface LinkHandle extends Stamp {
	readonly workspace: RoomsManagedWorkspace;
}

/** `link`'s workspace, read where a call is about to use it. A newer link
 * freed that handle, so once one replaced `link` the read throws the loss of
 * `link` instead, and work that has sent nothing over it runs again over the
 * new link. Read it after the last await and call it in the same turn. */
export function liveWorkspace(port: Pick<LinkPort, "isCurrent">, link: LinkHandle): () => RoomsManagedWorkspace {
	return () => {
		if (!port.isCurrent(link)) throw new RoomsError(SESSION_UNREACHABLE, "a newer link replaced this one");
		return link.workspace;
	};
}

/** What the session supplies to build its port. */
export interface LinkSource {
	/** The current link, read at once. */
	current(): LinkHandle;
	/** A call under a handle stamped `stamp` failed with `error`. A lost
	 * connection ends the link when that is still the current one, and says
	 * nothing of a link that replaced it. Any other failure keeps the link. */
	lost(error: unknown, stamp: Stamp): void;
	/** After a lost connection: whether a new link comes, which is never so for
	 * a session this browser runs. Waits for as long as the page is trying. */
	available(): Promise<boolean>;
	/** Wait for a live link before a first send, for as long as recovery may
	 * take, and throw why none came: the session's refusal, a closed page, or
	 * the bound passing with nothing sent, which a send names `not-sent` and a
	 * read `session-unread`. A live link answers at once. */
	ready(unsent: LocalRefusalKey): Promise<void>;
}

/** What a call over the link holds. The source stays inside the port, so a
 * loss is charged only by the call it ended. A dial's own calls run over no
 * link yet, so their failure is the dial's. */
export interface LinkPort extends Pick<LinkSource, "current" | "ready"> {
	/** Whether `stamp` is the current link's. */
	isCurrent(stamp: Stamp): boolean;
	/** Run `call` over the current link, and charge a lost connection under it
	 * to that link. The failure stands. */
	over<T>(call: (link: LinkHandle) => Promise<T>): Promise<T>;
	/** Run `call` over a handle the caller holds, stamped `stamp` by the read that
	 * produced it, and charge a lost connection under it to that stamp. */
	overStamped<T>(stamp: Stamp, call: () => Promise<T>): Promise<T>;
	/** Whether `error` is a lost connection and a new link is now live, so work
	 * the loss ended may run again over it. The loss was charged where it
	 * happened. */
	relinkedAfter(error: unknown): Promise<boolean>;
}

export function linkPort(source: LinkSource): LinkPort {
	const overStamped = async <T>(stamp: Stamp, call: () => Promise<T>): Promise<T> => {
		try {
			return await call();
		} catch (error) {
			source.lost(error, stamp);
			throw error;
		}
	};
	return {
		current: () => source.current(),
		ready: (unsent) => source.ready(unsent),
		isCurrent: (stamp) => stamp.generation === source.current().generation,
		over: (call) => {
			const link = source.current();
			return overStamped(link, () => call(link));
		},
		overStamped,
		relinkedAfter: async (error) => connectionLost(error) && await source.available(),
	};
}
