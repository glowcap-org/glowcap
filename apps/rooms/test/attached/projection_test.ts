/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionProjection } = await import("../../web/ui/session/projection.ts");
const { CapabilitySetEvents } = await import("../../web/ui/ops/capability_set_events.ts");
const { emptyRoomsSessionState } = await import("../../lib/rooms_state.ts");
const store = await import("../../web/ui/store.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { dirId } = await import("../../web/ui/types.ts");
const { assertEquals } = await import("../assert.ts");
const { adminSessionView } = await import("../support/session_snapshot.ts");
const { registrationId } = await import("../support/registration.ts");

const adminView = adminSessionView();

Deno.test("an attached checkpoint projects intent without claiming directory liveness", async () => {
	const page = new RoomsPage();
	const capabilityEvents = new CapabilitySetEvents();
	const projection = new AttachedSessionProjection(page, null, capabilityEvents);
	let capabilityChanges = 0;
	const stopCapabilityChanges = capabilityEvents.watch(() => {
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
			publicationId: "bridge-generation",
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
			membershipKind: "participant",
			policy: { visibility: "listed", entry: "open", speaking: "open" },
			members: [["ada", { online: true, away: "" }], ["bo", { online: true, away: "" }]],
			topic: "Shared work",
			lineBytes: 4096,
			canSetTopic: true,
			canModerate: true,
		}],
		directoryViews: [{
			directoryId: "directory",
			rooms: [{
				id: "bridge-generation",
				name: "general",
				kind: "bridge",
				count: 2,
				origin: "irc.example:6697",
				proof: "bridge",
				offers: "participant",
			}],
			peers: [{ name: "bo", registrationId: registrationId(1) }],
			truncated: false,
		}],
	});
	const room = [...page.projection.get().convs.values()][0];
	const directory = dirId("directory");
	assertEquals(page.projection.get().dirs.get(directory)?.session, "connecting");
	assertEquals(page.projection.get().dirs.get(directory)?.reached, false);
	assertEquals(page.projection.get().dirs.get(directory)?.requestedNick, "ada");
	assertEquals(page.projection.get().dirs.get(directory)?.nick, "");
	assertEquals([...page.projection.get().dirs.get(directory)!.liveRooms.keys()], ["general"]);
	assertEquals(room?.type === "room" ? room.publicationId : null, "bridge-generation");
	assertEquals(
		store.bridgedOrigin(
			page.projection.get().dirs.get(directory),
			room?.type === "room" ? room.publicationId : undefined,
		),
		"irc.example:6697",
	);
	assertEquals([...page.projection.get().dirs.get(directory)!.dmablePeers], [["bo", {
		name: "bo",
		registrationId: registrationId(1),
	}]]);
	assertEquals(page.projection.get().activeKey, room.key);
	assertEquals(page.projection.get().drafts.get(room.key)?.text, "half written");
	assertEquals(page.projection.get().invites.map((invitation) => invitation.id), ["invite-1"]);
	store.showJoinFor(page.projection, { source: "press" });
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
			membershipKind: "participant",
			policy: { visibility: "listed", entry: "open", speaking: "open" },
			members: [["ada", { online: true, away: "" }], ["bo", { online: true, away: "" }]],
			topic: "Shared work",
			lineBytes: 4096,
			canSetTopic: true,
			canModerate: true,
		}],
	});
	assertEquals(page.projection.get().activeKey, null);
	store.switchTo(page.projection, room.key);
	const initialRoom = page.projection.get().convs.get(room.key);
	assertEquals(initialRoom?.type === "room" ? initialRoom.membership : null, "joined");
	assertEquals(initialRoom?.type === "room" ? [...store.membersOf(page.projection, room.key).keys()] : [], [
		"ada",
		"bo",
	]);
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
	const welcomed = page.projection.get().convs.get(room.key);
	assertEquals(welcomed?.type === "room" ? [...store.membersOf(page.projection, room.key).keys()] : [], [
		"ada",
		"bo",
	]);
	assertEquals(welcomed?.type === "room" ? welcomed.topic : null, "Shared work");
	assertEquals(welcomed?.type === "room" ? welcomed.lineBytes : null, 4096);
	const welcomeLine = store.historyOf(page.projection, room.key).at(-1);
	assertEquals(welcomeLine?.kind, "sys");
	assertEquals(welcomeLine?.kind === "sys" ? welcomeLine.audience : null, "here");
	const historyBeforePresence = store.historyOf(page.projection, room.key).length;
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
	const afterPresence = page.projection.get().convs.get(room.key);
	assertEquals(
		afterPresence?.type === "room" ? store.membersOf(page.projection, room.key).get("cy") : undefined,
		undefined,
	);
	assertEquals(store.historyOf(page.projection, room.key).length, historyBeforePresence + 1);
	const joinedLine = store.historyOf(page.projection, room.key).at(-1);
	assertEquals(joinedLine?.kind === "sys" ? joinedLine.audience : null, "shared");
	const governed = store.chatItem(page.projection, "ada", "still said", true);
	store.deliver(page.projection, room.key, governed);
	store.nameLine(page.projection, room.key, governed.id, 6);
	store.holdLine(page.projection, room.key, governed.id);
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
	assertEquals(page.projection.get().dirs.get(directory)?.session, "disconnected");
	assertEquals(page.projection.get().dirs.get(directory)?.statusText, "directory refused the connection");
	const unavailableRoom = page.projection.get().convs.get(room.key);
	assertEquals(
		unavailableRoom?.type === "room" ? unavailableRoom.membership : null,
		"unavailable",
	);
	assertEquals(
		unavailableRoom?.type === "room" ? unavailableRoom.membershipIssue : null,
		"room membership was refused",
	);
	const retired = store.historyOf(page.projection, room.key).find((item) => item.id === governed.id);
	assertEquals(
		retired?.kind === "chat" ? [retired.text, retired.held, retired.lineId] : null,
		["still said", false, undefined],
		"directory loss left room-local mutation authority live",
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
	assertEquals(
		page.projection.get().dirs.get(directory)?.session,
		"disconnected",
		"a queued line overruled the newer directory snapshot",
	);
	assertEquals(page.projection.get().dirs.get(directory)?.reached, false);
	assertEquals(store.historyOf(page.projection, room.key).at(-1)?.at, 42);
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
	assertEquals(store.historyOf(page.projection, room.key).at(-1)?.text, "hello again");
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
	const withdrawn = store.historyOf(page.projection, room.key).at(-1);
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
	const generations = store.historyOf(page.projection, room.key).filter((item) =>
		item.kind === "chat" && item.history?.id === "8"
	);
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
	assertEquals(page.projection.get().drafts.get(room.key)?.text, "changed");
	assertEquals(page.projection.get().dirs.get(directory)?.standing, "away");
	assertEquals(page.projection.get().dirs.get(directory)?.nick, "ada");
	assertEquals(page.projection.get().dirs.get(directory)?.reached, true);
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
	assertEquals(page.projection.get().sessionEffects[0]?.id, "private-recovery");
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
	assertEquals(page.projection.get().sessionEffects.length, 0);
	stopCapabilityChanges();
	capabilityEvents.close();
	store.dropInvite(page.projection, "invite-1");
	store.forgetConv(page.projection, room.key);
	store.forgetDir(page.projection, directory);
});

Deno.test("an attached directory that has answered, then dropped, is reconnecting", () => {
	const page = new RoomsPage();
	const projection = new AttachedSessionProjection(page);
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{
			id: "directory",
			locator: "127.0.0.1:1",
			home: false,
			reached: true,
			nick: "ada",
			standing: null,
		}],
	};
	const snapshot = (revision: number, connected: readonly string[]) => ({
		revision,
		...adminView,
		checkpoint,
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: [...connected],
		memberLocator: null,
		roomViews: [],
	});
	projection.apply(snapshot(1, []));
	const directory = dirId("directory");
	assertEquals(page.projection.get().dirs.get(directory)?.session, "reconnecting");
	assertEquals(page.projection.get().dirs.get(directory)?.reached, true);
	projection.apply(snapshot(2, ["directory"]));
	assertEquals(page.projection.get().dirs.get(directory)?.session, "connected");
	projection.apply(snapshot(3, []));
	assertEquals(page.projection.get().dirs.get(directory)?.session, "reconnecting");
	assertEquals(page.projection.get().dirs.get(directory)?.reached, true);
	store.forgetDir(page.projection, directory);
});

Deno.test("an attached nickname release clears the live grant and keeps saved conversations", () => {
	const page = new RoomsPage();
	const projection = new AttachedSessionProjection(page);
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
	assertEquals(page.projection.get().dirs.get(directory)?.nick, "ada");
	const unnamed = { ...named, directories: [{ ...named.directories[0], nick: "" }] };
	projection.apply(snapshot(2, unnamed));
	assertEquals(page.projection.get().dirs.get(directory)?.requestedNick, "");
	assertEquals(page.projection.get().dirs.get(directory)?.nick, "");
	assertEquals(
		[...page.projection.get().convs.values()].flatMap((conversation) =>
			conversation.type === "directory" ? [] : [conversation.persistId]
		),
		["release-room"],
	);
	store.forgetConv(page.projection, [...page.projection.get().convs.values()][0]!.key);
	store.forgetDir(page.projection, directory);
});

Deno.test("attached image lines and refiles start their bounded automatic fetch", () => {
	const page = new RoomsPage();
	const opened: { key: string; id: number }[] = [];
	const files = {
		hold(attachment: { name: string; mime: string; size: number; width: number; height: number }) {
			return store.attachmentView(page.projection, {
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
		page,
		files as unknown as import("../../web/ui/session/attached_files.ts").AttachedSessionFiles,
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
		roomViews: [{
			conversationId: "image-room",
			membershipKind: "participant",
			policy: { visibility: "listed", entry: "open", speaking: "open" },
			members: [],
			topic: null,
			lineBytes: null,
		}],
	});
	const image = (name: string) => ({
		name,
		mime: "image/png",
		size: 80,
		blob: {} as import("@glowcap/runtime").Ref,
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
	page.projection.set({ ignored: new Set(["bo"]) });
	projection.line(event(3, "said", "silenced.png", 2));
	assertEquals(opened.length, 2);
	const room = [...page.projection.get().convs.values()].find((conversation) =>
		conversation.type !== "directory" && conversation.persistId === "image-room"
	);
	if (room != null) store.forgetConv(page.projection, room.key);
	store.forgetDir(page.projection, directory);
	page.projection.set({ ignored: new Set() });
});

Deno.test("attached projection does not reuse a persistent ID for a different conversation", () => {
	const page = new RoomsPage();
	const projection = new AttachedSessionProjection(page);
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
		roomViews: [{
			conversationId: "collision",
			membershipKind: "participant",
			policy: { visibility: "listed", entry: "open", speaking: "open" },
			members: [],
			topic: null,
			lineBytes: null,
		}],
	});
	const old = [...page.projection.get().convs.values()][0];
	if (old == null) throw new Error("persistent-ID test did not create the original room");
	store.deliver(page.projection, old.key, store.chatItem(page.projection, "bo", "old history", false));
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
	const current = [...page.projection.get().convs.values()];
	assertEquals(current.length, 1);
	assertEquals(current[0]?.type, "dm");
	assertEquals(current[0]?.id, "bo");
	assertEquals(current[0]?.dir, newDirectory);
	assertEquals(store.historyOf(page.projection, current[0]!.key).length, 0);
	store.forgetConv(page.projection, current[0]!.key);
	store.forgetDir(page.projection, oldDirectory);
	store.forgetDir(page.projection, newDirectory);
});
