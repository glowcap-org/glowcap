// The attached session this page is working through, for the page-level acts
// that need that session rather than a new one.
//
// A capability names a peer and a swissnum, and a Host keeps one session per
// peer. So an act handed a second capability for the peer this page is already
// talking to cannot open a session to try it, and must ask the session it has.
// The act runs from the browser controller, which is built before any session
// exists, so what it needs is a place to look rather than an argument.

import type { AttachedRoomsController } from "./attached.ts";

export class PageAttachedSession {
	#controller: AttachedRoomsController | null = null;

	/** The live attached session, or null while this page is local, still
	 * opening, or has let its session go. A caller that finds null has no
	 * session to ask and opens one of its own. */
	get current(): AttachedRoomsController | null {
		return this.#controller;
	}

	hold(controller: AttachedRoomsController): void {
		this.#controller = controller;
	}

	release(): void {
		this.#controller = null;
	}
}
