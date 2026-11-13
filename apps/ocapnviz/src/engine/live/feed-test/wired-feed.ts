import { LiveFeed, type LivePeerFactory } from "../connection.ts";
import type { BaseTimelineEvent } from "../record.ts";
import type { TimelineEvent } from "../../timeline.ts";

/** A feed whose records the test sends by hand, and what it reports and draws. */
export async function wiredFeed(): Promise<{
	feed: LiveFeed;
	errors: string[];
	seen: TimelineEvent[];
	send: (record: BaseTimelineEvent) => void;
}> {
	const records: Array<(line: string) => void> = [];
	const factory: LivePeerFactory = (_ref, onRecord) => {
		records.push(onRecord);
		return Promise.resolve({ closed: new Promise<void>(() => {}), close: () => Promise.resolve() });
	};
	const feed = new LiveFeed("ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss", factory);
	const errors: string[] = [];
	const seen: TimelineEvent[] = [];
	feed.onError((e) => errors.push(e.detail));
	feed.subscribe((ev) => seen.push(ev));
	feed.connect();
	await Promise.resolve();
	const send = (record: BaseTimelineEvent) => records[0]?.(JSON.stringify(record));
	return { feed, errors, seen, send };
}
