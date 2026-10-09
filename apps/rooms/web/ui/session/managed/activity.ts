// One delivery transfers all transient handles together. A presentation owner
// takes custody before retaining files or incoming offers; failure beforehand
// leaves them with the reader. No wrapper or payload is cloned.
import type { ActivityPage } from "./model.ts";

export class ActivityDelivery {
	#page: ActivityPage | null;
	constructor(page: ActivityPage) {
		this.#page = page;
	}
	take(): ActivityPage {
		if (this.#page == null) throw new Error("This activity delivery already transferred custody");
		const page = this.#page;
		this.#page = null;
		return page;
	}
	close(): void {
		const page = this.#page;
		this.#page = null;
		if (page != null) releaseActivity(page);
	}
}

export function releaseActivity(page: ActivityPage): void {
	for (const file of page.event?.files ?? []) file.free();
	page.event?.authority?.free();
	page.event?.route?.free();
}
