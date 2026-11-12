// Directory registration and exact introduction receipts own direct admission.
import { invariant } from "../../../../lib/invariant.ts";
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { ConversationOpening } from "./openings.ts";
import type { WorkspaceSnapshot } from "./model.ts";
import { readDirectReceipt } from "./direct_receipt.ts";

export async function acquireDirect(
	session: ManagedRoomsSession,
	directory: string,
	peer: string,
	expectedRegistration?: string,
	opening?: ConversationOpening,
): Promise<string> {
	const signal = opening?.signal;
	signal?.throwIfAborted();
	const accepted = session.current;
	const initial = await session.refresh();
	const original = (accepted ?? initial).intent.directories.find((row) => row.id === directory);
	if (original?.name == null || original.inbox == null) {
		throw new LocalRefusal("directory-gone");
	}
	const reader = await session.workspace.directoryReader(directory);
	let registration: string;
	try {
		registration = await reader.memberRegistration(peer);
	} finally {
		reader.free();
	}
	if (expectedRegistration != null && registration !== expectedRegistration) {
		throw new LocalRefusal("registration-ended");
	}
	const checkOrigin = (snapshot: WorkspaceSnapshot) => {
		const origin = snapshot.intent.directories.find((row) => row.id === directory);
		if (origin?.name == null || origin.inbox == null) {
			throw new LocalRefusal("directory-gone");
		}
		if (
			origin.access !== original.access || origin.source !== original.source ||
			origin.name !== original.name || origin.inbox !== original.inbox
		) {
			throw new LocalRefusal("registration-changed");
		}
		return origin;
	};
	const current = await session.refresh();
	const origin = checkOrigin(current);
	const existing = current.intent.conversations.find((row) =>
		row.kind === "direct" && row.directory === directory && row.peer === peer && !row.closed &&
		row.introduction?.access === origin.access && row.introduction.name === origin.name &&
		row.introduction.callback === origin.inbox && row.introduction.registration === registration
	);
	if (existing != null) {
		return existing.id;
	}
	const closed = new Set(
		current.intent.conversations.filter((row) => row.kind === "direct" && row.closed).map((row) => row.id),
	);
	const introduction = crypto.randomUUID();
	const operation = crypto.randomUUID();
	let id: string | null = null;
	await session.execute(operation, () =>
		session.command(
			"startDirect",
			[directory, peer, registration, introduction],
			operation,
			checkOrigin,
			signal,
		), async (command) => {
		readDirectReceipt(await command.result());
		await session.completeResult(command);
	}, {
		signal,
		settled: async () => {
			const adopted = (await session.refresh()).intent.conversations.find((row) =>
				row.kind === "direct" && row.directory === directory && !row.closed &&
				row.introduction?.registration === registration && row.introduction.opening === introduction
			);
			if (adopted == null) throw new LocalRefusal("direct-not-opened");
			id = adopted.id;
			await opening?.acquired(adopted.id, closed.has(adopted.id) ? "closeDirect" : "leaveConversation");
		},
	});
	invariant(id != null, "the original direct introduction has no ready route");
	return id;
}
