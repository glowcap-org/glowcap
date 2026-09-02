import { DURABLE_SWISS_ENTROPY_BYTES, type Session } from "@glowcap/runtime";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { memorySessionDocuments } from "../../session/documents.ts";
import { fileSessionDocuments } from "../../session/file_documents.ts";
import {
	DurableRoomsSessionGrants,
	type RoomsSessionGrantPublisher,
	type RoomsSessionGrantRecord,
} from "../../session/grants.ts";
import { DurableRoomsSessionState } from "../../session/state.ts";
import { assertEquals } from "../assert.ts";

const ROOT_ENTROPY = new Uint8Array(DURABLE_SWISS_ENTROPY_BYTES).fill(0x5a);
const SESSION = {} as Session;
const GRANT_ID = "00000000-0000-4000-8000-000000000001";

class FakePublisher implements RoomsSessionGrantPublisher {
	readonly published: string[] = [];

	publish(_grant: RoomsSessionGrantRecord, entropy: Uint8Array, _active: () => boolean): string {
		const swiss = [...entropy].map((byte) => byte.toString(16).padStart(2, "0")).join("");
		this.published.push(swiss);
		return swiss;
	}

	unpublish(): boolean {
		return true;
	}

	sturdyref(_session: Session, swiss: string): string {
		return `ocapn://session.id/s/${swiss}`;
	}

	revokeLive(): Promise<void> {
		return Promise.resolve();
	}
}

Deno.test("a memory session store restores a checkpoint and grants without a directory", async () => {
	const documents = memorySessionDocuments();
	const state = await DurableRoomsSessionState.open(documents);
	assertEquals(await state.replace("op-1", 0, { ...emptyRoomsSessionState(), standing: "elsewhere" }), 1);

	const restored = await DurableRoomsSessionState.open(documents);
	assertEquals(restored.snapshot().revision, 1);
	assertEquals(restored.snapshot().checkpoint.standing, "elsewhere");

	const firstPublisher = new FakePublisher();
	const grants = await DurableRoomsSessionGrants.open(documents, ROOT_ENTROPY, firstPublisher);
	const issued = await grants.issue(GRANT_ID, "interact", "tablet", false, SESSION);
	assertEquals(issued.history, false);
	assertEquals(issued.suspended, false);

	const restoredPublisher = new FakePublisher();
	const restoredGrants = await DurableRoomsSessionGrants.open(documents, ROOT_ENTROPY, restoredPublisher);
	await restoredGrants.restore();
	const listed = restoredGrants.list(SESSION);
	assertEquals(listed.length, 1);
	assertEquals(listed[0].id, GRANT_ID);
	assertEquals(listed[0].sturdyref, issued.sturdyref);
	assertEquals(restoredPublisher.published, firstPublisher.published);
});

Deno.test("a memory store still refuses an effects ledger missing beside a checkpoint", async () => {
	const documents = memorySessionDocuments();
	await DurableRoomsSessionState.open(documents);
	const checkpoint = await documents.read("checkpoint");
	if (checkpoint == null) throw new Error("the memory store lost its checkpoint");
	const orphan = memorySessionDocuments();
	await orphan.write("checkpoint", checkpoint);
	assertEquals(
		await DurableRoomsSessionState.open(orphan).then(() => false, () => true),
		true,
	);
});

Deno.test("a file session store treats a missing directory as absence and creates it only on write", async () => {
	const parent = await Deno.makeTempDir({ prefix: "glowcap-rooms-session-docs-" });
	const directory = `${parent}/missing`;
	try {
		const documents = fileSessionDocuments(directory);
		assertEquals(await documents.read("checkpoint"), null);
		assertEquals(
			await Deno.stat(directory).then(() => "present", (error) => {
				if (error instanceof Deno.errors.NotFound) return "absent";
				throw error;
			}),
			"absent",
		);
		const payload = new TextEncoder().encode('{"version":1,"grants":[]}\n');
		await documents.write("grants", payload);
		const raw = await documents.read("grants");
		if (raw == null) throw new Error("the file store lost the grants document it just wrote");
		assertEquals(raw, payload);
	} finally {
		await Deno.remove(parent, { recursive: true });
	}
});
