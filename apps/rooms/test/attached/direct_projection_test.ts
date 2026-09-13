// Attached direct conversations retain liveness, notification, and line identity across checkpoint projection.
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
const { registrationId } = await import("../support/registration.ts");

const adminView = adminSessionView();

Deno.test("an attached direct message becomes live and uses the local notification gate", () => {
	const page = new RoomsPage();
	const projection = new AttachedSessionProjection(page);
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
	page.projection.set({ notifyOn: true, visible: false });
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
			previewUrls: [],
			attachments: [],
			system: false,
		});
		const conv = [...page.projection.get().convs.values()][0];
		assertEquals(conv?.type === "dm" ? conv.line : null, "live");
		assertEquals(notifications, ["bo"]);
	} finally {
		Object.defineProperty(globalThis, "Notification", { configurable: true, value: priorNotification });
		page.projection.set({ notifyOn: false, visible: true });
		store.forgetConv(page.projection, "dm:1");
		store.forgetDir(page.projection, directory);
	}
});

Deno.test("attached projection preserves a live direct line across checkpoint updates", () => {
	const page = new RoomsPage();
	const projection = new AttachedSessionProjection(page);
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
	const conversation = [...page.projection.get().convs.values()][0];
	if (conversation?.type !== "dm") throw new Error("live direct projection did not create a DM");
	store.setDmLine(page.projection, conversation.key, "live");
	apply(2);
	const current = page.projection.get().convs.get(conversation.key);
	assertEquals(current?.type === "dm" ? current.line : null, "live");
	store.forgetConv(page.projection, conversation.key);
	store.forgetDir(page.projection, dirId("direct-live"));
});
