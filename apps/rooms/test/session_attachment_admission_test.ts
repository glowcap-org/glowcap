import { Ref, type Session } from "@pancake/runtime";
import { ROOMS_SESSION_FILES, ROOMS_SESSION_REFILE } from "../lib/rooms_session.ts";
import { dispatchAttachmentCommand } from "../session/attachment_commands.ts";
import type { DurableRoomsRuntime } from "../session/runtime.ts";
import type { DurableRoomsSessionState } from "../session/state.ts";
import { assertEquals } from "./assert.ts";

function ref(): Ref {
	return Object.create(Ref.prototype) as Ref;
}

Deno.test("session file-command refusal releases every supplied capability occurrence", () => {
	const released: Ref[] = [];
	const session = { release: (capability: Ref) => released.push(capability) } as unknown as Session;
	const owner = {} as { state: DurableRoomsSessionState; runtime: DurableRoomsRuntime };

	const unauthorized = ref();
	let refused = false;
	try {
		dispatchAttachmentCommand("observe", ROOMS_SESSION_FILES, [unauthorized], session, owner);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(released, [unauthorized]);

	const malformed = ref();
	refused = false;
	try {
		dispatchAttachmentCommand("interact", ROOMS_SESSION_FILES, [malformed], session, owner);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(released.at(-1), malformed);

	const badOperation = ref();
	refused = false;
	try {
		dispatchAttachmentCommand(
			"interact",
			ROOMS_SESSION_FILES,
			[
				"",
				0n,
				"conversation",
				"caption",
				"file",
				"note.txt",
				"text/plain",
				1n,
				badOperation,
				0n,
				0n,
			],
			session,
			owner,
		);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(released.at(-1), badOperation);

	const badKeep = ref();
	refused = false;
	try {
		dispatchAttachmentCommand(
			"interact",
			ROOMS_SESSION_REFILE,
			[
				"00000000-0000-4000-8000-000000000001",
				0n,
				"conversation",
				1n,
				"caption",
				0n,
				0n,
				"file",
				"note.txt",
				"text/plain",
				1n,
				badKeep,
				0n,
				0n,
			],
			session,
			owner,
		);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(released.at(-1), badKeep);
});
