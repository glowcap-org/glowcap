// Directory registration and exact introduction receipts own direct admission.
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
		throw new Error("The initiating registration was retired");
	}
	const reader = await session.workspace.directoryReader(directory);
	let registration: string;
	try {
		registration = await reader.memberRegistration(peer);
	} finally {
		reader.free();
	}
	if (expectedRegistration != null && registration !== expectedRegistration) {
		throw new Error(
			"That name now has a different registration. Start a separate conversation from the directory.",
		);
	}
	const checkOrigin = (snapshot: WorkspaceSnapshot) => {
		const origin = snapshot.intent.directories.find((row) => row.id === directory);
		if (origin?.name == null || origin.inbox == null) {
			throw new Error("The initiating registration was retired");
		}
		if (
			origin.access !== original.access || origin.source !== original.source ||
			origin.name !== original.name || origin.inbox !== original.inbox
		) {
			throw new Error("The initiating registration changed while selecting the peer");
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
	// Install the scalar readiness waiter before asking for an introduction.
	// Only the original directory and exact registration can wake it.
	const readiness = session.waitNotice((event) => {
		const notice = event.notice;
		return event.target.kind === "directory" && event.target.id === directory &&
			notice?.kind === "introducible" && notice.registration === registration &&
			notice.opening === introduction;
	});
	const cancel = () => readiness.cancel();
	signal?.addEventListener("abort", cancel, { once: true });
	try {
		const introduce = async (): Promise<string | null> => {
			const operation = crypto.randomUUID();
			let id: string | null = null;
			let ready = false;
			await session.execute(operation, () =>
				session.command(
					"startDirect",
					[directory, peer, registration, introduction],
					operation,
					checkOrigin,
					signal,
				), async (command) => {
				const result = readDirectReceipt(await command.result());
				if (result.status === "pending") {
					session.finish(command);
					return;
				}
				ready = true;
				await session.completeResult(command);
			}, {
				signal,
				settled: async () => {
					if (!ready) return;
					const adopted = (await session.refresh()).intent.conversations.find((row) =>
						row.kind === "direct" && row.directory === directory && !row.closed &&
						row.introduction?.registration === registration && row.introduction.opening === introduction
					);
					if (adopted == null) throw new Error("The original direct introduction is no longer held");
					id = adopted.id;
					await opening?.acquired(adopted.id, closed.has(adopted.id) ? "closeDirect" : "leaveConversation");
				},
			});
			return id;
		};
		let id = await introduce();
		if (id == null) {
			await readiness.ready;
			signal?.throwIfAborted();
			id = await introduce();
		}
		if (id == null) throw new Error("The original direct introduction has no ready route");
		return id;
	} finally {
		signal?.removeEventListener("abort", cancel);
		readiness.cancel();
	}
}
