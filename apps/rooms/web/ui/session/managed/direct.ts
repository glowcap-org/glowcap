// Directory registration and exact introduction receipts own direct admission.
// The application's rule (`directReach`) names the one open row a member has.
import { LocalRefusal } from "../../../../lib/text/failure.ts";
import type { Door } from "./session.ts";
import type { ConversationOpening } from "./openings.ts";
import type { WorkspaceSnapshot } from "./model.ts";
import { directReach } from "../../application.ts";

export async function acquireDirect(
	session: Door,
	directory: string,
	peer: string,
	expectedRegistration?: string,
	opening?: ConversationOpening,
): Promise<string | null> {
	const signal = opening?.signal;
	signal?.throwIfAborted();
	const accepted = session.current;
	const initial = await session.readBeforeSending();
	const original = (accepted ?? initial).intent.directories.find((row) => row.id === directory);
	if (original?.name == null || original.inbox == null) {
		throw new LocalRefusal("directory-gone");
	}
	const reader = await session.request((workspace) => workspace.directoryReader(directory));
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
	const current = await session.readBeforeSending();
	checkOrigin(current);
	// The open row that reaches this registration is the conversation, under
	// any contact the directory held and whoever opened it.
	const existing = directReach(current.intent, directory, registration).open;
	if (existing != null) {
		return existing;
	}
	const closed = new Set(
		current.intent.conversations.filter((row) => row.kind === "direct" && row.closed).map((row) => row.id),
	);
	const introduction = crypto.randomUUID();
	const operation = crypto.randomUUID();
	return await session.press(
		operation,
		({ command }) =>
			command("startDirect", [directory, peer, registration, introduction], operation, checkOrigin, signal),
		async (command, after) => {
			await after.complete(command);
			// The row the route opened or reached is the answer. A session that
			// cannot be read names no row, and the press never guesses one.
			const settled = await after.readOr<WorkspaceSnapshot | null>(null, (reads) => reads.readNow());
			if (settled == null) return null;
			const open = directReach(settled.intent, directory, registration).open;
			const row = settled.intent.conversations.find((row) => row.kind === "direct" && row.id === open);
			if (row?.kind !== "direct") throw new LocalRefusal("direct-not-opened");
			// Only an opening that landed its own route made the row. A route given
			// back left a row someone else opened, which the opening does not own.
			if (row.introduction?.opening === introduction) {
				await opening?.acquired(row.id, closed.has(row.id) ? "closeDirect" : "leaveConversation");
			}
			return row.id;
		},
		signal,
	);
}
