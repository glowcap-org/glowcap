// Presentation fixtures exercise managed intent and activity without a Host.
import type { ConversationIntent, WorkspaceSnapshot } from "../../../web/ui/session/managed/model.ts";
import type { ManagedRoomsSession } from "../../../web/ui/session/managed/session.ts";
import { ManagedProjection } from "../../../web/ui/session/managed/projection.ts";
import { presentationFiles } from "../../../web/ui/session/managed/files.ts";
import { RoomsPage } from "../../../web/ui/page.ts";
import * as store from "../../../web/ui/store.ts";

export function room(): ConversationIntent {
	return {
		kind: "room",
		id: "conversation",
		directory: "directory",
		name: "garden",
		access: null,
		control: null,
		reconnect: "manual",
		standing: null,
		draft: "unfinished",
	};
}
export function direct(): ConversationIntent {
	return {
		kind: "direct",
		id: "conversation",
		directory: "directory",
		peer: "bo",
		access: "route-one",
		closed: false,
		draft: "",
	};
}

export function fixture(conversation = room()) {
	const page = new RoomsPage();
	const current: WorkspaceSnapshot = {
		revision: "1",
		intent: {
			version: 1,
			directories: [{
				id: "directory",
				access: "directory-access",
				home: true,
				nick: "ada",
				nickAllocation: "exact",
				standing: null,
			}],
			conversations: [conversation],
			invitations: [],
			active: conversation.id,
			standing: "",
			ignored: [],
			keepHistory: true,
			connection: "relay",
			archive: null,
			archiveControl: null,
			operators: [],
			peering: [],
		},
	};
	let staged: string | undefined;
	const pending: string[] = [];
	const acquisitions: string[] = [];
	const session = {
		current,
		access: { status: "active" },
		pending,
		recoverable: pending,
		actions: { pending: acquisitions, recoverable: acquisitions },
		navigation: { selected: undefined },
		drafts: {
			stage: (_id: string, text: string) => {
				staged = text;
			},
			value: (_id: string, accepted: string) => staged ?? accepted,
			retire: () => {
				staged = undefined;
			},
		},
	} as unknown as ManagedRoomsSession;
	const files = presentationFiles(page.projection, () => null);
	const projection = new ManagedProjection(page, session, files, () => {}, () => {});
	const apply = () => {
		current.revision = String(Number(current.revision) + 1);
		projection.apply();
	};
	const selected = () => {
		const row = store.activeConv(page.projection);
		if (row == null || row.type === "directory") throw new Error("selected managed conversation missing");
		return row;
	};
	const close = () => {
		files.close();
		for (const row of [...page.projection.get().convs.values()]) store.forgetConv(page.projection, row.key);
	};
	projection.apply();
	return {
		page,
		pending,
		acquisitions,
		current,
		projection,
		apply,
		selected,
		close,
		stage: (text: string) => {
			staged = text;
		},
	};
}
