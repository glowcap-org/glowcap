/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionProjection } = await import("../web/ui/session/projection.ts");
const { onCapabilitySetChanged } = await import("../web/ui/ops/capability_set_events.ts");
const { emptyRoomsSessionState } = await import("../lib/rooms_state.ts");
const store = await import("../web/ui/store.ts");
const { dirId } = await import("../web/ui/types.ts");
const { assertEquals } = await import("./assert.ts");
const { adminSessionView } = await import("./support/session_snapshot.ts");
const { registrationId } = await import("./support/registration.ts");

const adminView = adminSessionView();

Deno.test("an attached checkpoint projects intent without claiming directory liveness", async () => {
	const projection = new AttachedSessionProjection();
	let capabilityChanges = 0;
	const stopCapabilityChanges = onCapabilitySetChanged(() => {
		capabilityChanges += 1;
	});
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "room" as const,
			id: "room-id",
			directory: "directory",
			name: "general",
			held: false,
			standing: null,
			draft: "half written",
		}],
		invitations: [{
			kind: "room-link" as const,
			id: "invite-1",
			directory: "directory",
			locator: "ocapn://directory.id",
			nick: "ada",
			label: "quiet room",
			from: "bo",
			link: "ocapn://directory.iroh/s/quiet-room",
		}],
		active: "room-id",
	};
	projection.apply({
		revision: 1,
		...adminView,
		checkpoint,
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: [],
		memberLocator: null,
		roomViews: [{
			conversationId: "room-id",
			members: [["ada", { online: true, away: "" }], ["bo", { online: true, away: "" }]],
			topic: "Shared work",
			lineBytes: 4096,
			canSetTopic: true,
			canModerate: true,
		}],
		directoryViews: [{
			directoryId: "directory",
			rooms: [{ id: "general", name: "general", kind: "local", count: 2, origin: "", proof: "local" }],
			peers: [{ name: "bo", registrationId: registrationId(1) }],
			truncated: false,
		}],
	});
	const room = [...store.get().convs.values()][0];
	const directory = dirId("directory");
	assertEquals(store.get().dirs.get(directory)?.session, "reconnecting");
	assertEquals(store.get().dirs.get(directory)?.requestedNick, "ada");
	assertEquals(store.get().dirs.get(directory)?.nick, "");
	assertEquals([...store.get().dirs.get(directory)!.liveRooms.keys()], ["general"]);
	assertEquals([...store.get().dirs.get(directory)!.dmablePeers], [["bo", {
		name: "bo",
		registrationId: registrationId(1),
	}]]);
	assertEquals(store.get().activeKey, room.key);
	assertEquals(store.get().drafts.get(room.key)?.text, "half written");
	assertEquals(store.get().invites.map((invitation) => invitation.id), ["invite-1"]);
	store.showJoinFor({ source: "press" });
	projection.apply({
		revision: 1,
		...adminView,
		checkpoint,
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: [],
		memberLocator: null,
		roomViews: [{
			conversationId: "room-id",
			members: [["ada", { online: true, away: "" }], ["bo", { online: true, away: "" }]],
			topic: "Shared work",
			lineBytes: 4096,
			canSetTopic: true,
			canModerate: true,
		}],
	});
	assertEquals(store.get().activeKey, null);
	store.switchTo(room.key);
	const initialRoom = store.get().convs.get(room.key);
	assertEquals(initialRoom?.type === "room" ? initialRoom.membership : null, "joined");
	assertEquals(initialRoom?.type === "room" ? [...initialRoom.members.keys()] : [], ["ada", "bo"]);
	assertEquals(initialRoom?.type === "room" ? initialRoom.topic : null, "Shared work");
	assertEquals(initialRoom?.type === "room" ? [...initialRoom.grants].sort() : [], ["steward", "topic"]);
	projection.line({
		source: "lines",
		sequence: 1,
		conversationId: "room-id",
		from: "room",
		text: "Welcome to general",
		at: 40,
		lineId: null,
		change: null,
		editable: false,
		system: true,
		presence: { kind: "roster", names: ["ada", "bo"] },
		facts: { topic: "Shared work", lineBytes: 4096 },
		history: null,
		attachments: [],
	});
	const welcomed = store.get().convs.get(room.key);
	assertEquals(welcomed?.type === "room" ? [...welcomed.members.keys()] : [], ["ada", "bo"]);
	assertEquals(welcomed?.type === "room" ? welcomed.topic : null, "Shared work");
	assertEquals(welcomed?.type === "room" ? welcomed.lineBytes : null, 4096);
	const welcomeLine = welcomed?.history.at(-1);
	assertEquals(welcomeLine?.kind, "sys");
	assertEquals(welcomeLine?.kind === "sys" ? welcomeLine.audience : null, "here");
	projection.line({
		source: "lines",
		sequence: 2,
		conversationId: "room-id",
		from: "room",
		text: "cy joined",
		at: 41,
		lineId: null,
		change: null,
		editable: false,
		system: true,
		presence: { kind: "join", name: "cy" },
		history: null,
		attachments: [],
	});
	const joined = store.get().convs.get(room.key);
	assertEquals(joined?.type === "room" ? joined.members.get("cy")?.online : false, true);
	const joinedLine = joined?.history.at(-1);
	assertEquals(joinedLine?.kind === "sys" ? joinedLine.audience : null, "shared");
	projection.apply({
		revision: 1,
		...adminView,
		checkpoint,
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [
			{ subject: "directory:directory", reason: "directory refused the connection" },
			{ subject: "room:directory:room-id", reason: "room membership was refused" },
		],
		connectedDirectories: [],
		memberLocator: null,
		roomViews: [],
	});
	assertEquals(store.get().dirs.get(directory)?.session, "disconnected");
	assertEquals(store.get().dirs.get(directory)?.statusText, "directory refused the connection");
	const unavailableRoom = store.get().convs.get(room.key);
	assertEquals(
		unavailableRoom?.type === "room" ? unavailableRoom.membership : null,
		"unavailable",
	);
	projection.line({
		source: "lines",
		sequence: 1,
		conversationId: "room-id",
		from: "bo",
		text: "hello",
		at: 42,
		lineId: 7,
		change: "said",
		editable: false,
		system: false,
		history: null,
		attachments: [],
	});
	assertEquals(store.get().dirs.get(directory)?.session, "connected");
	assertEquals(store.get().convs.get(room.key)?.history.at(-1)?.at, 42);
	projection.line({
		source: "lines",
		sequence: 2,
		conversationId: "room-id",
		from: "bo",
		text: "hello again",
		at: 43,
		lineId: 7,
		change: "edited",
		editable: false,
		system: false,
		history: null,
		attachments: [],
	});
	assertEquals(store.get().convs.get(room.key)?.history.at(-1)?.text, "hello again");
	projection.line({
		source: "lines",
		sequence: 3,
		conversationId: "room-id",
		from: "bo",
		text: "",
		at: 44,
		lineId: 7,
		change: "withdrawn",
		editable: false,
		system: false,
		history: null,
		attachments: [],
	});
	const withdrawn = store.get().convs.get(room.key)?.history.at(-1);
	assertEquals(withdrawn?.kind === "chat" ? withdrawn.withdrawn : false, true);
	projection.line({
		source: "lines",
		sequence: 4,
		conversationId: "room-id",
		from: "bo",
		text: "earlier generation",
		at: 45,
		lineId: 8,
		change: "said",
		editable: false,
		system: false,
		history: { source: "session", generation: "earlier", id: "8" },
		attachments: [],
	});
	projection.line({
		source: "lines",
		sequence: 5,
		conversationId: "room-id",
		from: "bo",
		text: "current generation",
		at: 46,
		lineId: 8,
		change: "said",
		editable: false,
		system: false,
		history: { source: "session", generation: "current", id: "8" },
		attachments: [],
	});
	projection.line({
		source: "lines",
		sequence: 6,
		conversationId: "room-id",
		from: "bo",
		text: "current generation edited",
		at: 47,
		lineId: 8,
		change: "edited",
		editable: false,
		system: false,
		history: { source: "session", generation: "current", id: "8" },
		attachments: [],
	});
	const generations =
		store.get().convs.get(room.key)?.history.filter((item) => item.kind === "chat" && item.history?.id === "8") ??
			[];
	assertEquals(generations.map((item) => item.kind === "chat" ? item.text : ""), [
		"earlier generation",
		"current generation edited",
	]);
	projection.apply({
		revision: 2,
		...adminView,
		checkpoint: {
			...checkpoint,
			directories: [{ ...checkpoint.directories[0], standing: "away" }],
			conversations: [{ ...checkpoint.conversations[0], draft: "changed" }],
		},
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: ["directory"],
		memberLocator: null,
		roomViews: [],
	});
	assertEquals(store.get().drafts.get(room.key)?.text, "changed");
	assertEquals(store.get().dirs.get(directory)?.standing, "away");
	assertEquals(store.get().dirs.get(directory)?.nick, "ada");
	projection.apply({
		revision: 3,
		...adminView,
		checkpoint: {
			...checkpoint,
			capabilities: {
				...checkpoint.capabilities,
				operations: [{ capability: "operator", scope: "directory", swiss: "saved" }],
			},
		},
		pendingEffects: [],
		pendingEffectDetails: [{
			id: "private-recovery",
			kind: "private-room",
			subject: 'Create private room "plans"',
			phase: "prepared",
		}],
		issues: [],
		connectedDirectories: ["directory"],
		memberLocator: null,
		roomViews: [],
	});
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(capabilityChanges, 1);
	assertEquals(store.get().sessionEffects[0]?.id, "private-recovery");
	projection.apply({
		revision: 3,
		...adminView,
		checkpoint,
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: ["directory"],
		memberLocator: null,
		roomViews: [],
	});
	assertEquals(store.get().sessionEffects.length, 0);
	stopCapabilityChanges();
	store.dropInvite("invite-1");
	store.forgetConv(room.key);
	store.forgetDir(directory);
});

Deno.test("an attached nickname release clears the live grant and keeps saved conversations", () => {
	const projection = new AttachedSessionProjection();
	const directory = dirId("release-directory");
	const named = {
		...emptyRoomsSessionState(),
		directories: [{
			id: directory,
			locator: "ocapn://release-directory.id",
			home: true,
			nick: "ada",
			standing: null,
		}],
		conversations: [{
			kind: "room" as const,
			id: "release-room",
			directory,
			name: "general",
			held: false,
			standing: null,
			draft: "unfinished",
		}],
	};
	const snapshot = (revision: number, checkpoint: typeof named) => ({
		revision,
		...adminView,
		checkpoint,
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: [directory],
		memberLocator: null,
		roomViews: [],
		directoryViews: [],
	});
	projection.apply(snapshot(1, named));
	assertEquals(store.get().dirs.get(directory)?.nick, "ada");
	const unnamed = { ...named, directories: [{ ...named.directories[0], nick: "" }] };
	projection.apply(snapshot(2, unnamed));
	assertEquals(store.get().dirs.get(directory)?.requestedNick, "");
	assertEquals(store.get().dirs.get(directory)?.nick, "");
	assertEquals([...store.get().convs.values()].map((conversation) => conversation.persistId), ["release-room"]);
	store.forgetConv([...store.get().convs.values()][0]!.key);
	store.forgetDir(directory);
});

Deno.test("an attached direct message becomes live and uses the local notification gate", () => {
	const projection = new AttachedSessionProjection();
	const directory = dirId("dm-directory");
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "dm-directory", locator: "127.0.0.1:2", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "direct" as const,
			id: "dm-id",
			directory: "dm-directory",
			peer: "bo",
			peerRegistrationId: registrationId(1),
			closed: false,
			draft: "",
		}],
		active: null,
	};
	projection.apply({
		revision: 1,
		...adminView,
		checkpoint,
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: ["dm-directory"],
		memberLocator: null,
		roomViews: [],
	});
	store.set({ notifyOn: true, visible: false });
	const notifications: string[] = [];
	const priorNotification = globalThis.Notification;
	Object.defineProperty(globalThis, "Notification", {
		configurable: true,
		value: class {
			static permission = "granted";
			constructor(title: string) {
				notifications.push(title);
			}
		},
	});
	try {
		projection.line({
			source: "direct",
			sequence: 1,
			conversationId: "dm-id",
			from: "bo",
			text: "hello",
			at: 1,
			lineId: 1,
			change: "said",
			editable: false,
			history: null,
			attachments: [],
			system: false,
		});
		const conv = [...store.get().convs.values()][0];
		assertEquals(conv?.type === "dm" ? conv.line : null, "live");
		assertEquals(notifications, ["bo"]);
	} finally {
		Object.defineProperty(globalThis, "Notification", { configurable: true, value: priorNotification });
		store.set({ notifyOn: false, visible: true });
		store.forgetConv("dm:1");
		store.forgetDir(directory);
	}
});

Deno.test("attached image lines and refiles start their bounded automatic fetch", () => {
	const opened: { key: string; id: number }[] = [];
	const files = {
		hold(attachment: { name: string; mime: string; size: number; width: number; height: number }) {
			return store.attachmentView({
				name: attachment.name,
				mime: attachment.mime,
				size: attachment.size,
				width: attachment.width,
				height: attachment.height,
			});
		},
		open(key: string, id: number) {
			opened.push({ key, id });
		},
		release() {},
		markLost() {},
	};
	const projection = new AttachedSessionProjection(
		files as unknown as import("../web/ui/session/attached_files.ts").AttachedSessionFiles,
	);
	const directory = dirId("image-directory");
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: directory, locator: "127.0.0.1:8", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "room" as const,
			id: "image-room",
			directory,
			name: "images",
			held: false,
			standing: null,
			draft: "",
		}],
		active: "image-room",
	};
	projection.apply({
		revision: 1,
		...adminView,
		checkpoint,
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: [directory],
		memberLocator: null,
		roomViews: [{ conversationId: "image-room", members: [], topic: null, lineBytes: null }],
	});
	const image = (name: string) => ({
		name,
		mime: "image/png",
		size: 80,
		blob: {} as import("@pancake/runtime").Ref,
		width: 4,
		height: 2,
	});
	const event = (sequence: number, change: "said" | "refiled", name: string, lineId: number) => ({
		source: "images",
		sequence,
		conversationId: "image-room",
		from: "bo",
		text: name,
		at: sequence,
		lineId,
		change,
		editable: false,
		system: false,
		history: null,
		attachments: [image(name)],
	});
	projection.line(event(1, "said", "first.png", 1));
	projection.line(event(2, "refiled", "replacement.png", 1));
	assertEquals(opened.length, 2);
	store.set({ ignored: new Set(["bo"]) });
	projection.line(event(3, "said", "silenced.png", 2));
	assertEquals(opened.length, 2);
	const room = [...store.get().convs.values()].find((conversation) => conversation.persistId === "image-room");
	if (room != null) store.forgetConv(room.key);
	store.forgetDir(directory);
	store.set({ ignored: new Set() });
});

Deno.test("attached projection does not reuse a persistent ID for a different conversation", () => {
	const projection = new AttachedSessionProjection();
	const oldDirectory = dirId("collision-old");
	const newDirectory = dirId("collision-new");
	const roomCheckpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "collision-old", locator: "127.0.0.1:5", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "room" as const,
			id: "collision",
			directory: "collision-old",
			name: "old-room",
			held: false,
			standing: null,
			draft: "",
		}],
		active: "collision",
	};
	projection.apply({
		revision: 1,
		...adminView,
		checkpoint: roomCheckpoint,
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: ["collision-old"],
		memberLocator: null,
		roomViews: [{ conversationId: "collision", members: [], topic: null, lineBytes: null }],
	});
	const old = [...store.get().convs.values()][0];
	if (old == null) throw new Error("persistent-ID test did not create the original room");
	store.deliver(old.key, store.chatItem("bo", "old history", false));
	const directCheckpoint = {
		...roomCheckpoint,
		directories: [{ id: "collision-new", locator: "127.0.0.1:6", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "direct" as const,
			id: "collision",
			directory: "collision-new",
			peer: "bo",
			peerRegistrationId: registrationId(2),
			closed: false,
			draft: "",
		}],
	};
	projection.apply({
		revision: 2,
		...adminView,
		checkpoint: directCheckpoint,
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: ["collision-new"],
		memberLocator: null,
		roomViews: [],
	});
	const current = [...store.get().convs.values()];
	assertEquals(current.length, 1);
	assertEquals(current[0]?.type, "dm");
	assertEquals(current[0]?.id, "bo");
	assertEquals(current[0]?.dir, newDirectory);
	assertEquals(current[0]?.history.length, 0);
	store.forgetConv(current[0]!.key);
	store.forgetDir(oldDirectory);
	store.forgetDir(newDirectory);
});

Deno.test("attached projection preserves a live direct line across checkpoint updates", () => {
	const projection = new AttachedSessionProjection();
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "direct-live", locator: "127.0.0.1:7", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "direct" as const,
			id: "direct-live-conversation",
			directory: "direct-live",
			peer: "bo",
			peerRegistrationId: registrationId(3),
			closed: false,
			draft: "",
		}],
		active: "direct-live-conversation",
	};
	const apply = (revision: number) =>
		projection.apply({
			revision,
			...adminView,
			checkpoint,
			pendingEffects: [],
			pendingEffectDetails: [],
			issues: [],
			connectedDirectories: ["direct-live"],
			memberLocator: null,
			roomViews: [],
		});
	apply(1);
	const conversation = [...store.get().convs.values()][0];
	if (conversation?.type !== "dm") throw new Error("live direct projection did not create a DM");
	store.setDmLine(conversation.key, "live");
	apply(2);
	const current = store.get().convs.get(conversation.key);
	assertEquals(current?.type === "dm" ? current.line : null, "live");
	store.forgetConv(conversation.key);
	store.forgetDir(dirId("direct-live"));
});
