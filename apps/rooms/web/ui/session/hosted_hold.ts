// How this page shares its local session: the act is registered after the
// local controller exists, and the browser controller only has a place to look.

import { nothingToShare } from "../../../lib/text/attached.ts";

export class PageHostedSession {
	#share: (() => Promise<string>) | null = null;
	#inflight: Promise<string> | null = null;

	bind(share: () => Promise<string>): void {
		this.#share = share;
	}

	share(): Promise<string> {
		if (this.#inflight != null) return this.#inflight;
		const run = this.#share?.() ??
			Promise.resolve(nothingToShare);
		const inflight = run.finally(() => {
			if (this.#inflight === inflight) this.#inflight = null;
		});
		this.#inflight = inflight;
		return inflight;
	}
}
