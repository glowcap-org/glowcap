// One delivery transfers all transient handles together. A presentation owner
// takes custody before retaining files or incoming offers. Failure beforehand
// leaves them with the reader. The carrier and handles keep their identities.
import { type ActivityEvent, activityNotice, type ActivityPage } from "./model.ts";

export class ActivityDelivery {
	#page: ActivityPage | null;
	constructor(page: ActivityPage<unknown>) {
		// Rust proves the delivery envelope. Validate its notice once here,
		// before any readiness or presentation consumer can act on it. Reuse
		// the owned carrier; only the schema's parsed notice is materialized.
		if (page.event != null) page.event.notice = activityNotice(page.event.notice);
		this.#page = page as ActivityPage;
	}
	get event(): ActivityEvent | undefined {
		return this.#page?.event;
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

export function releaseActivity(page: ActivityPage<unknown>): void {
	for (const file of page.event?.files ?? []) file.free();
	page.event?.authority?.free();
	page.event?.route?.free();
}
