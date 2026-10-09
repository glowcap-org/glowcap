// Attached media projection starts only the bounded automatic fetches its policy permits.
/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedLineProjection } = await import("../../web/ui/session/line_projection.ts");
const store = await import("../../web/ui/store.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { dirId } = await import("../../web/ui/types.ts");
const { assertEquals } = await import("../assert.ts");

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
	const directory = dirId("image-directory");
	store.openDir(page.projection, directory, "127.0.0.1:8");
	const openedRoom = store.ensureRoom(page.projection, directory, "images", { persistId: "image-room" });
	store.patchDir(page.projection, directory, { nick: "ada", session: "connected" });
	store.switchTo(page.projection, openedRoom.key);
	const projection = new AttachedLineProjection(
		(id) => store.convByPersistId(page.projection, id)?.key ?? null,
		files as unknown as import("../../web/ui/session/attached_files.ts").AttachedSessionFiles,
		page,
	);
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
	projection.apply(event(1, "said", "first.png", 1));
	projection.apply(event(2, "refiled", "replacement.png", 1));
	assertEquals(opened.length, 2);
	page.projection.set({ ignored: new Set(["bo"]) });
	projection.apply(event(3, "said", "silenced.png", 2));
	assertEquals(opened.length, 2);
	const room = [...page.projection.get().convs.values()].find((conversation) =>
		conversation.type !== "directory" && conversation.persistId === "image-room"
	);
	if (room != null) store.forgetConv(page.projection, room.key);
	store.forgetDir(page.projection, directory);
	page.projection.set({ ignored: new Set() });
});
