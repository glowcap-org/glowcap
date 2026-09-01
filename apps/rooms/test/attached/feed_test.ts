/// <reference lib="dom" />

import type { RoomsSessionLineEvent, RoomsSessionSnapshot } from "../../lib/session/client.ts";
import type { Attachment } from "../../lib/attachment.ts";
import { AttachedSessionFeed } from "../../web/ui/session/attached_feed.ts";
import type { AttachedRoomsRemote } from "../../web/ui/session/remote.ts";
import { assertEquals } from "../assert.ts";
import { roomsSessionSnapshot } from "../support/session_snapshot.ts";

function refusal(work: () => unknown): string {
	try {
		work();
		return "";
	} catch (error) {
		return error instanceof Error ? error.message : String(error);
	}
}

function attachment(name: string): Attachment {
	return { name, mime: "text/plain", size: 1, width: 0, height: 0, blob: {} as Attachment["blob"] };
}

function line(source: string, sequence: number, file?: Attachment): RoomsSessionLineEvent {
	return {
		source,
		sequence,
		conversationId: "room",
		from: "bo",
		text: String(sequence),
		at: sequence,
		lineId: null,
		change: null,
		editable: false,
		history: null,
		system: false,
		attachments: file == null ? [] : [file],
	};
}

Deno.test("the attached feed owns accepted revisions and releases them on close", async () => {
	let changed!: (snapshot: RoomsSessionSnapshot) => void;
	let operationsChanged!: (scope: string) => void;
	let snapshotReads = 0;
	const initial = roomsSessionSnapshot({ revision: 1 });
	const remote = {
		watch(
			onChanged: (snapshot: RoomsSessionSnapshot) => void,
			_event: unknown,
			onOperationsChanged: (scope: string) => void,
		) {
			changed = onChanged;
			operationsChanged = onOperationsChanged;
			return Promise.resolve(initial);
		},
		snapshot() {
			snapshotReads += 1;
			return Promise.resolve(initial);
		},
	} as unknown as AttachedRoomsRemote;
	const feed = new AttachedSessionFeed(remote);
	const revisions: number[] = [];
	const invalidated: string[] = [];
	feed.onSnapshot((snapshot) => revisions.push(snapshot.revision));
	feed.onOperationsInvalidated((scope) => invalidated.push(scope));
	await feed.start();

	const settling = feed.settleRevision(2);
	changed(roomsSessionSnapshot({ revision: 2 }));
	assertEquals((await settling).revision, 2);
	changed(roomsSessionSnapshot({ revision: 1 }));
	operationsChanged("home");
	assertEquals(feed.current?.revision, 2);
	assertEquals(revisions, [1, 2]);
	assertEquals(invalidated, ["home"]);
	assertEquals(snapshotReads, 0);

	feed.close();
	assertEquals(feed.current, null);
	assertEquals(
		refusal(() => feed.onSnapshot(() => {})),
		"this attached Rooms feed is closed",
	);
	await feed.refresh().then(
		() => {
			throw new Error("a closed feed refreshed");
		},
		(error) =>
			assertEquals(error instanceof Error ? error.message : String(error), "this attached Rooms feed is closed"),
	);
	assertEquals(snapshotReads, 0);
});

Deno.test("the attached feed releases every event it cannot hand to its line owner", async () => {
	let arrived!: (event: RoomsSessionLineEvent) => void;
	const released: string[] = [];
	const initial = roomsSessionSnapshot();
	const remote = {
		watch(_changed: unknown, event: (value: RoomsSessionLineEvent) => void) {
			arrived = event;
			return Promise.resolve(initial);
		},
		snapshot: () => Promise.resolve(initial),
		releaseAttachment: (file: Attachment) => released.push(file.name),
	} as unknown as AttachedRoomsRemote;
	const feed = new AttachedSessionFeed(remote);
	await feed.start();

	arrived(line("gap", 2, attachment("gap.txt")));
	for (let sequence = 1; sequence <= 257; sequence += 1) {
		arrived(line("buffer", sequence, attachment(`buffer-${sequence}.txt`)));
	}
	assertEquals(released, ["gap.txt", "buffer-1.txt"]);
	feed.close();
	assertEquals(released.length, 258);
	arrived(line("closed", 1, attachment("closed.txt")));
	assertEquals(released.at(-1), "closed.txt");
});

Deno.test("an attached line event has exactly one presentation owner", async () => {
	let arrived!: (event: RoomsSessionLineEvent) => void;
	const initial = roomsSessionSnapshot();
	const remote = {
		watch(_changed: unknown, event: (value: RoomsSessionLineEvent) => void) {
			arrived = event;
			return Promise.resolve(initial);
		},
		snapshot: () => Promise.resolve(initial),
	} as unknown as AttachedRoomsRemote;
	const feed = new AttachedSessionFeed(remote);
	await feed.start();
	const stop = feed.onLine(() => {});
	assertEquals(refusal(() => feed.onLine(() => {})), "the attached Rooms feed already has a line owner");
	stop();
	feed.onLine(() => {})();
	arrived(line("retry", 1));
	arrived(line("retry", 2));
	let first = true;
	assertEquals(
		refusal(() =>
			feed.onLine(() => {
				if (first) {
					first = false;
					throw new Error("projection failed");
				}
			})
		),
		"projection failed",
	);
	const retried: string[] = [];
	feed.onLine((event) => retried.push(event.text))();
	assertEquals(retried, ["2"]);
	feed.close();
});
