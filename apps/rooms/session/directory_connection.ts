// Construction and partial-start cleanup for one durable directory connection.

import type { Runtime } from "@pancake/runtime";
import { inboxPublisher } from "../lib/dm_inbox.ts";
import { dialDirectory } from "../lib/locator.ts";
import { Directory } from "../lib/room/client.ts";
import type { WorkspaceDirectory } from "../lib/rooms_state.ts";
import { DurableDirectoryView } from "./directory_view.ts";
import {
	cancelDirectRouteAttempts,
	directInbox,
	type DirectRealizationCallbacks,
	establishRequestedDirectRoute,
} from "./directory_directs.ts";
import type { LiveDirectory, LiveRoom } from "./live.ts";
import { RoomRealization } from "./room_realization.ts";
import { roomsDirectoryConnectionTopology } from "./topology.ts";
import type { RuntimeStateReconciliation } from "./state_sync.ts";
import { adoptedRegistrationNick, takeAdoptedDirectory } from "./directory_adopt.ts";
import { answerWebrtcSignaling } from "./webrtc_answer.ts";

interface DirectoryConnectionOptions {
	runtime: Runtime;
	saved: WorkspaceDirectory;
	memberLocator: string;
	directCallbacks: DirectRealizationCallbacks;
	releaseRoom(live: LiveRoom): void;
	onClosed(live: LiveDirectory): void;
	notifyView(): void;
	roomPublicationsChanged(): void;
	setIssue(subject: string, error: unknown | null): boolean;
	cleanup(work: Promise<unknown>, label: string): Promise<void>;
	reconcileState(change: RuntimeStateReconciliation): Promise<void>;
}

export async function connectDirectory(options: DirectoryConnectionOptions): Promise<LiveDirectory> {
	const { saved } = options;
	const adopted = takeAdoptedDirectory(saved.id, saved.locator);
	const directory = adopted?.directory ??
		await Directory.connect(saved.locator, (address) => dialDirectory(address, options.runtime));
	const nick = adoptedRegistrationNick(saved.nick, adopted);
	const view = new DurableDirectoryView(saved.id);
	const slot: { live: LiveDirectory | null } = { live: null };
	const offerer = inboxPublisher(options.runtime.host).offerer({
		dir: () => slot.live?.directory ?? null,
		behaviorFor: (peer, registrationId) => {
			const live = slot.live;
			if (live == null) throw new Error("the durable directory connection is not ready for inbox offers");
			return directInbox(live, peer, registrationId, options.directCallbacks);
		},
		skip: (peer) => peer.toLowerCase() === nick.toLowerCase(),
		onError: (peer, error) => options.setIssue(`direct-inbox:${saved.id}:${peer.toLowerCase()}`, error),
	});
	const live: LiveDirectory = {
		id: saved.id,
		topology: roomsDirectoryConnectionTopology(saved),
		nick,
		directory,
		view,
		roomRealization: new RoomRealization(),
		directs: new Map(),
		directIntents: new Map(),
		directRouteAttempts: new Map(),
		directConversationByRegistration: new Map(),
		offerer,
		stopClose: () => {},
		signaling: null,
	};
	slot.live = live;
	live.stopClose = directory.session.onClose(() => options.onClosed(live));
	try {
		const rooms = await directory.watch((event) => {
			if (!view.apply(event)) return;
			if (event.kind === "opened" || event.kind === "closed") options.roomPublicationsChanged();
			options.setIssue(
				`directory-view:${saved.id}`,
				view.snapshot().truncated
					? "this directory has more live rooms or peers than a shared view can carry"
					: null,
			);
			options.notifyView();
		});
		view.replaceRooms(rooms);
		await options.reconcileState({
			type: "directory-reached",
			directoryId: saved.id,
			locator: saved.locator,
		});
		options.setIssue(
			`directory-view:${saved.id}`,
			view.snapshot().truncated ? "this directory has more live rooms than a shared view can carry" : null,
		);
		if (nick !== "") {
			await directory.register(
				nick,
				options.memberLocator,
				(peer, registrationId) => {
					const accept = options.directCallbacks.acceptDirect;
					if (accept == null) {
						offerer.offer(peer, registrationId);
						return;
					}
					void accept(live, peer, registrationId).then(
						() => {
							options.setIssue(`direct-inbox:${saved.id}:${peer.toLowerCase()}`, null);
							offerer.offer(peer, registrationId);
						},
						(error) => options.setIssue(`direct-inbox:${saved.id}:${peer.toLowerCase()}`, error),
					);
				},
				(_peer, registrationId) => {
					const subject = `direct-request:${saved.id}:${registrationId}`;
					void establishRequestedDirectRoute(live, registrationId, options.directCallbacks).then(
						() => options.setIssue(subject, null),
						(error) => options.setIssue(subject, error),
					);
				},
			);
			live.signaling = await answerWebrtcSignaling({
				host: options.runtime.host,
				directory,
				memberLocator: options.memberLocator,
				onError: (error) => options.setIssue(`webrtc-signaling:${saved.id}`, error),
			});
		}
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
		if (live.signaling != null) {
			await options.cleanup(live.signaling.close(), "partial WebRTC signaling would not close");
		}
		await options.cleanup(directory.close(), "a partial directory would not close");
		await openings;
		throw error;
	}
}
