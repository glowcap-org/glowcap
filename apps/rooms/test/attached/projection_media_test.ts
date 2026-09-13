// Attached media projection starts only the bounded automatic fetches its policy permits.
/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionProjection } = await import("../../web/ui/session/projection.ts");
const { emptyRoomsSessionState } = await import("../../lib/rooms_state.ts");
const store = await import("../../web/ui/store.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { dirId } = await import("../../web/ui/types.ts");
const { assertEquals } = await import("../assert.ts");
const { adminSessionView } = await import("../support/session_snapshot.ts");

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
		...adminSessionView(),
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
		previewUrls: [],
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
