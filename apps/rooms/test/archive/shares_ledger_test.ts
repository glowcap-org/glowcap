import { DURABLE_SWISS_ENTROPY_BYTES } from "@pancake/runtime";
import { assertEquals } from "../assert.ts";
import { type ArchiveSharePublisher, type ArchiveShareRecord, DurableArchiveShares } from "../../archive/shares.ts";
import { ALL_ARCHIVE_RECORDS } from "../../lib/archive/protocol.ts";
import { MAX_ACTIVE_ARCHIVE_SHARES } from "../../lib/limits.ts";

const ROOT_ENTROPY = new Uint8Array(DURABLE_SWISS_ENTROPY_BYTES).fill(0x5a);

function id(at: number): string {
	return `00000000-0000-4000-8000-${at.toString(16).padStart(12, "0")}`;
}

function refused(work: () => Promise<unknown>): Promise<boolean> {
	return work().then(() => false, () => true);
}

class FakePublisher implements ArchiveSharePublisher {
	readonly published: { share: ArchiveShareRecord; entropy: string; active: () => boolean }[] = [];
	readonly unpublished: string[] = [];
	beforePublish: (() => void) | null = null;
	failUnpublish = false;

	publish(share: ArchiveShareRecord, entropy: Uint8Array, active: () => boolean): string {
		this.beforePublish?.();
		const encoded = [...entropy].map((byte) => byte.toString(16).padStart(2, "0")).join("");
		this.published.push({ share, entropy: encoded, active });
		return encoded;
	}

	unpublish(swiss: string): boolean {
		this.unpublished.push(swiss);
		if (this.failUnpublish) throw new Error("injected unpublish failure");
		return true;
	}

	sturdyref(swiss: string): string {
		return `ocapn://archive.id/s/${swiss}`;
	}
}

Deno.test("opening an archive share ledger has no publication effect", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-archive-shares-open-" });
	try {
		const publisher = new FakePublisher();
		publisher.beforePublish = () => {
			throw new Error("share opening published authority");
		};
		await DurableArchiveShares.open(directory, ROOT_ENTROPY, publisher);
		assertEquals(publisher.published, []);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("archive shares persist before publication and survive revoke tombstones", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-archive-shares-" });
	try {
		const publisher = new FakePublisher();
		publisher.beforePublish = () => {
			const disk = JSON.parse(Deno.readTextFileSync(`${directory}/shares.json`));
			assertEquals(disk.shares.map((share: ArchiveShareRecord) => share.id), [id(1)]);
		};
		const shares = await DurableArchiveShares.open(directory, ROOT_ENTROPY, publisher);
		const sturdyref = await shares.issue(id(1), "Room log", {
			...ALL_ARCHIVE_RECORDS,
			kind: "line",
			conversationKind: "room",
			directory: "directory",
			conversation: "lobby",
		});
		assertEquals(sturdyref.startsWith("ocapn://archive.id/s/"), true);
		assertEquals(publisher.published.length, 1);
		assertEquals(await shares.revoke(id(1)), true);
		assertEquals(publisher.unpublished.length, 1);
		assertEquals(
			await refused(() => shares.issue(id(1), "Room log", ALL_ARCHIVE_RECORDS)),
			true,
		);
		const restarted = await DurableArchiveShares.open(directory, ROOT_ENTROPY, new FakePublisher());
		assertEquals(
			await refused(() => restarted.issue(id(1), "Room log", ALL_ARCHIVE_RECORDS)),
			true,
		);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("archive share ledger refuses a 33rd active share", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-archive-shares-cap-" });
	try {
		const shares = await DurableArchiveShares.open(directory, ROOT_ENTROPY, new FakePublisher());
		for (let at = 1; at <= MAX_ACTIVE_ARCHIVE_SHARES; at += 1) {
			await shares.issue(id(at), `Share ${at}`, ALL_ARCHIVE_RECORDS);
		}
		assertEquals(
			await refused(() => shares.issue(id(MAX_ACTIVE_ARCHIVE_SHARES + 1), "One too many", ALL_ARCHIVE_RECORDS)),
			true,
		);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("listing archive shares waits for an in-flight publication", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-archive-shares-list-" });
	try {
		const publisher = new FakePublisher();
		const shares = await DurableArchiveShares.open(directory, ROOT_ENTROPY, publisher);
		let listing: ReturnType<DurableArchiveShares["list"]> | null = null;
		publisher.beforePublish = () => {
			listing = shares.list();
		};
		await shares.issue(id(1), "Room log", ALL_ARCHIVE_RECORDS);
		assertEquals((await listing!).map((share) => share.id), [id(1)]);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});
