// Presentation fixtures exercise managed intent and activity without a Host.
import type {
	ConversationIntent,
	DirectIntent,
	RoomIntent,
	WorkspaceSnapshot,
} from "../../../web/ui/session/managed/model.ts";
import type { ManagedRoomsSession } from "../../../web/ui/session/managed/session.ts";
import type { ManagedOperation } from "../../../web/ui/session/managed/operation.ts";
import type { ManagedNavigation } from "../../../web/ui/session/managed/navigation.ts";
import { ManagedProjection } from "../../../web/ui/session/managed/projection.ts";
import { presentationFiles } from "../../../web/ui/session/managed/files.ts";
import { RoomsPage } from "../../../web/ui/page.ts";
import * as store from "../../../web/ui/store.ts";

export function room(): RoomIntent {
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
export function direct(): DirectIntent {
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

export function fixture(conversation: ConversationIntent = room()) {
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
	const operations: ManagedOperation[] = [];
	const acquisitions: string[] = [];
	const cancelledAcquisitions: string[] = [];
	const cancelledEffects: string[] = [];
	const navigation: { readonly selected: string | undefined; choice: ManagedNavigation["choice"] } = {
		choice: undefined,
		get selected() {
			return this.choice?.id;
		},
	};
	const session = {
		current,
		access: { status: "active" },
		pending,
		pendingOperations: operations,
		recoverable: pending,
		effects: {
			standing: (_name: string, _target: string | null, accepted: string | null) => accepted,
			cancelledConversations: cancelledEffects,
		},
		actions: { pending: acquisitions, recoverable: acquisitions, cancelledConversations: cancelledAcquisitions },
		openings: { destination: null },
		navigation,
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
		operations,
		acquisitions,
		cancelledAcquisitions,
		cancelledEffects,
		navigation,
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
