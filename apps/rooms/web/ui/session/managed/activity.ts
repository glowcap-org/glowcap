// One delivery transfers all transient handles together. A presentation owner
// takes custody before retaining files or incoming offers. Failure beforehand
// leaves them with the reader. The carrier and handles keep their identities.
import { invariant } from "../../../../lib/invariant.ts";
import { activityNotice, type ActivityPage } from "./model.ts";

export class ActivityDelivery {
	#page: ActivityPage | null;
	/** Whether this was read while the page caught up on what happened before
	 * it was reading. */
	readonly replayed: boolean;
	constructor(page: ActivityPage<unknown>, replayed: boolean) {
		this.replayed = replayed;
		// Rust proves the delivery envelope. Validate its notice once here,
		// before presentation takes custody. Reuse the owned carrier; only the
		// schema's parsed notice is materialized.
		if (page.event != null) page.event.notice = activityNotice(page.event.notice);
		this.#page = page as ActivityPage;
	}

	take(): ActivityPage {
		invariant(this.#page != null, "this activity delivery already transferred custody");
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
