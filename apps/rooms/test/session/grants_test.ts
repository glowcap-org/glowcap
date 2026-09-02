import { DURABLE_SWISS_ENTROPY_BYTES, type Session } from "@glowcap/runtime";
import { assertEquals } from "../assert.ts";
import { type RoomsSessionGrantPublisher, type RoomsSessionGrantRecord } from "../../session/grants.ts";
import { MAX_ACTIVE_SESSION_GRANTS } from "../../lib/limits.ts";
import { openSessionGrants } from "../support/session_disk.ts";

const ROOT_ENTROPY = new Uint8Array(DURABLE_SWISS_ENTROPY_BYTES).fill(0x5a);
const SESSION = {} as Session;

function id(at: number): string {
	return `00000000-0000-4000-8000-${at.toString(16).padStart(12, "0")}`;
}

function refused(work: () => Promise<unknown>): Promise<boolean> {
	return work().then(() => false, () => true);
}

class FakePublisher implements RoomsSessionGrantPublisher {
	readonly published: { grant: RoomsSessionGrantRecord; entropy: string; active: () => boolean }[] = [];
	readonly unpublished: string[] = [];
	readonly liveRevocations: string[] = [];
	beforePublish: (() => void) | null = null;
	failPublish = false;
	failUnpublish = false;

	publish(grant: RoomsSessionGrantRecord, entropy: Uint8Array, active: () => boolean): string {
		this.beforePublish?.();
		if (this.failPublish) throw new Error("injected publish failure");
		const encoded = [...entropy].map((byte) => byte.toString(16).padStart(2, "0")).join("");
		this.published.push({ grant, entropy: encoded, active });
		return encoded;
	}

	unpublish(swiss: string): boolean {
		this.unpublished.push(swiss);
		if (this.failUnpublish) throw new Error("injected unpublish failure");
		return true;
	}

	sturdyref(_session: Session, swiss: string): string {
		return `ocapn://session.id/s/${swiss}`;
	}

	revokeLive(grantId: string): Promise<void> {
		this.liveRevocations.push(grantId);
		return Promise.resolve();
	}
}

Deno.test("opening a durable grant ledger has no publication effect", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-grants-open-" });
	try {
		const publisher = new FakePublisher();
		publisher.beforePublish = () => {
			throw new Error("grant opening published authority");
		};
		await openSessionGrants(directory, ROOT_ENTROPY, publisher);
		assertEquals(publisher.published, []);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("durable session grants persist before publication and retry by exact id", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-grants-" });
	try {
		const publisher = new FakePublisher();
		publisher.beforePublish = () => {
			const disk = JSON.parse(Deno.readTextFileSync(`${directory}/grants.json`));
			assertEquals(disk.grants.map((grant: RoomsSessionGrantRecord) => grant.id), [id(1)]);
		};
		const grants = await openSessionGrants(directory, ROOT_ENTROPY, publisher);
		const issued = await grants.issue(id(1), "interact", " Phone ", false, SESSION);
		assertEquals({ id: issued.id, rights: issued.rights, label: issued.label }, {
			id: id(1),
			rights: "interact",
			label: " Phone ",
		});
		assertEquals(publisher.published.length, 1);
		assertEquals((await grants.issue(id(1), "interact", " Phone ", false, SESSION)).sturdyref, issued.sturdyref);
		assertEquals(publisher.published.length, 1);
		assertEquals(await refused(() => grants.issue(id(1), "observe", " Phone ", false, SESSION)), true);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("durable session grants restore the same sturdyref and tombstone revocation", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-grants-restart-" });
	try {
		const firstPublisher = new FakePublisher();
		const first = await openSessionGrants(directory, ROOT_ENTROPY, firstPublisher);
		const issued = await first.issue(id(2), "observe", "Read-only wall display", false, SESSION);
		const live = firstPublisher.published[0];
		assertEquals(live.active(), true);

		const restoredPublisher = new FakePublisher();
		const restored = await openSessionGrants(directory, ROOT_ENTROPY, restoredPublisher);
		await restored.restore();
		assertEquals(restored.list(SESSION)[0]?.sturdyref, issued.sturdyref);
		assertEquals(restoredPublisher.published[0]?.entropy, firstPublisher.published[0]?.entropy);
		assertEquals(await restored.revoke(id(2)), true);
		assertEquals(restoredPublisher.liveRevocations, [id(2)]);
		assertEquals(restoredPublisher.unpublished.length, 1);
		assertEquals(restoredPublisher.published[0]?.active(), false);
		assertEquals(restored.list(SESSION), []);
		assertEquals(
			await refused(() => restored.issue(id(2), "observe", "Read-only wall display", false, SESSION)),
			true,
		);

		const afterPublisher = new FakePublisher();
		const after = await openSessionGrants(directory, ROOT_ENTROPY, afterPublisher);
		await after.restore();
		assertEquals(afterPublisher.published, []);
		assertEquals(after.active(id(2)), false);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("durable session grant admission is bounded and malformed state refuses startup", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-grants-bound-" });
	try {
		const grants = await openSessionGrants(directory, ROOT_ENTROPY, new FakePublisher());
		for (let at = 1; at <= MAX_ACTIVE_SESSION_GRANTS; at += 1) {
			await grants.issue(id(at), "observe", `Display ${at}`, false, SESSION);
		}
		assertEquals(
			await refused(() =>
				grants.issue(id(MAX_ACTIVE_SESSION_GRANTS + 1), "observe", "One too many", false, SESSION)
			),
			true,
		);
		assertEquals(await grants.revoke(id(1)), true);
		await grants.issue(id(MAX_ACTIVE_SESSION_GRANTS + 1), "observe", "Replacement display", false, SESSION);
		await Deno.writeTextFile(`${directory}/grants.json`, '{"version":1,"grants":[{"id":"bad"}]}');
		assertEquals(
			await refused(() => openSessionGrants(directory, ROOT_ENTROPY, new FakePublisher())),
			true,
		);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("durable grant publication failures remain retryable and revocation cleanup cannot hide commit", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-grants-failure-" });
	try {
		const publisher = new FakePublisher();
		const grants = await openSessionGrants(directory, ROOT_ENTROPY, publisher);
		let changes = 0;
		grants.onChange(() => changes += 1);
		publisher.failPublish = true;
		assertEquals(await refused(() => grants.issue(id(3), "interact", "Retrying tablet", false, SESSION)), true);
		assertEquals(grants.active(id(3)), true);
		assertEquals(changes, 0);
		publisher.failPublish = false;
		await grants.issue(id(3), "interact", "Retrying tablet", false, SESSION);
		assertEquals(changes, 1);
		publisher.failUnpublish = true;
		assertEquals(await refused(() => grants.revoke(id(3))), true);
		assertEquals(grants.active(id(3)), false);
		assertEquals(grants.list(SESSION), []);
		assertEquals(changes, 2);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});
