// Construction and partial-start cleanup for one durable directory connection.

import type { Runtime } from "@pancake/runtime";
import { inboxPublisher } from "../lib/dm_inbox.ts";
import { dial } from "../lib/locator.ts";
import { Directory } from "../lib/room_client.ts";
import type { WorkspaceConversation, WorkspaceDirectory } from "../lib/rooms_state.ts";
import type { DurableRoomsArchive } from "./archive.ts";
import { DurableDirectoryView } from "./directory_view.ts";
import {
	cancelDirectRouteAttempts,
	directInbox,
	type DirectRealizationCallbacks,
	establishRequestedDirectRoute,
	reconcileDirects,
} from "./directory_directs.ts";
import type { LiveDirectory, LiveRoom } from "./live.ts";
import { RoomRealization } from "./room_realization.ts";
import { makeRoomCallbacks, reconcileRooms, type RoomMessageReceiver } from "./room_reconcile.ts";
import { roomsDirectoryConnectionTopology } from "./topology.ts";

interface DirectoryConnectionOptions {
	runtime: Runtime;
	saved: WorkspaceDirectory;
	conversations: readonly WorkspaceConversation[];
	memberLocator: string;
	archive: DurableRoomsArchive;
	keepHistory: () => boolean;
	messages: ReadonlySet<RoomMessageReceiver>;
	directCallbacks: DirectRealizationCallbacks;
	releaseRoom(live: LiveRoom): void;
	onClosed(live: LiveDirectory): void;
	retry(): void;
	notifyView(): void;
	setIssue(subject: string, error: unknown | null): boolean;
	cleanup(work: Promise<unknown>, label: string): Promise<void>;
}

export async function connectDirectory(options: DirectoryConnectionOptions): Promise<LiveDirectory> {
	const { saved } = options;
	const directory = await Directory.connect(saved.locator, (address) => dial(address, options.runtime));
	const view = new DurableDirectoryView(saved.id);
	const slot: { live: LiveDirectory | null } = { live: null };
	const offerer = inboxPublisher(options.runtime.host).offerer({
		dir: () => slot.live?.directory ?? null,
		behaviorFor: (peer, registrationId) => {
			const live = slot.live;
			if (live == null) throw new Error("the durable directory connection is not ready for inbox offers");
			return directInbox(live, peer, registrationId, options.directCallbacks);
		},
		skip: (peer) => peer.toLowerCase() === saved.nick.toLowerCase(),
		onError: (peer, error) => options.setIssue(`direct-inbox:${saved.id}:${peer.toLowerCase()}`, error),
	});
	const live: LiveDirectory = {
		id: saved.id,
		topology: roomsDirectoryConnectionTopology(saved),
		nick: saved.nick,
		directory,
		view,
		roomRealization: new RoomRealization(),
		directs: new Map(),
		directIntents: new Map(),
		directRouteAttempts: new Map(),
		directConversationByRegistration: new Map(),
		offerer,
		stopClose: () => {},
	};
	slot.live = live;
	live.stopClose = directory.session.onClose(() => options.onClosed(live));
	try {
		const rooms = await directory.watch((event) => {
			if (!view.apply(event)) return;
			options.setIssue(
				`directory-view:${saved.id}`,
				view.snapshot().truncated
					? "this directory has more live rooms or peers than a shared view can carry"
					: null,
			);
			options.notifyView();
		});
		view.replaceRooms(rooms);
		options.setIssue(
			`directory-view:${saved.id}`,
			view.snapshot().truncated ? "this directory has more live rooms than a shared view can carry" : null,
		);
		await reconcileDirects(live, options.conversations, options.directCallbacks);
		if (saved.nick !== "") {
			await directory.register(
				saved.nick,
				options.memberLocator,
				(peer, registrationId) => offerer.offer(peer, registrationId),
				(_peer, registrationId) => {
					const subject = `direct-request:${saved.id}:${registrationId}`;
					void establishRequestedDirectRoute(live, registrationId, options.directCallbacks).then(
						() => options.setIssue(subject, null),
						(error) => options.setIssue(subject, error),
					);
				},
			);
		} else return live;
		await reconcileRooms(
			live.roomRealization,
			live,
			options.conversations,
			makeRoomCallbacks({
				held: live,
				archive: options.archive,
				keepHistory: options.keepHistory,
				receivers: options.messages,
				release: options.releaseRoom,
				retry: options.retry,
				notifyView: options.notifyView,
				setIssue: options.setIssue,
				cleanup: options.cleanup,
			}),
		);
		return live;
	} catch (error) {
		live.directIntents.clear();
		live.directConversationByRegistration.clear();
		const openings = cancelDirectRouteAttempts(live);
		await offerer.close();
		for (const direct of [...live.directs.values()].reverse()) {
			await options.cleanup(direct.close(), "a partial direct conversation would not close");
		}
		for (const room of [...live.roomRealization.rooms.values()].reverse()) {
			options.releaseRoom(room);
			await options.cleanup(room.room.leave(), "a partial room would not leave");
		}
		await options.cleanup(directory.close(), "a partial directory would not close");
		await openings;
		throw error;
	}
}
