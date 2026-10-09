// Conversation traffic updates its own store slice without replacing the application shell projection.
/// <reference lib="dom" />
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { RoomsBrowserController } from "../../web/ui/controller/browser.ts";
import type { RoomsSessionController } from "../../web/ui/controller/session.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({
		matches: false,
		addEventListener() {},
		removeEventListener() {},
	}),
});

const store = await import("../../web/ui/store.ts");
const projection = new store.PageProjection();
const { dirId } = await import("../../web/ui/types.ts");
const { Foot } = await import("../../web/ui/sidebar/Foot.tsx");
const { RoomsBrowserProvider } = await import("../../web/ui/controller/browser.ts");
const { RoomsSessionProvider } = await import("../../web/ui/controller/session.ts");

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

function shellSame(
	before: ReturnType<typeof store.appShellState>,
	after: ReturnType<typeof store.appShellState>,
): boolean {
	for (const key of Object.keys(before) as (keyof typeof before)[]) {
		if (before[key] !== after[key]) return false;
	}
	return Object.keys(after).length === Object.keys(before).length;
}

Deno.test("a line does not replace the shell projection or the open conversation", () => {
	projection.reset();
	const open = store.ensureRoom(projection, dirId("test-dir"), "open-room");
	const other = store.ensureRoom(projection, dirId("test-dir"), "other-room");
	projection.set({ activeKey: open.key });
	const shell = store.appShellState(projection.get());
	const active = store.activeConvOf(projection.get());
	assert(active != null, "the open conversation was missing");
	assert(!("convs" in shell), "the shell projection still carried the conversation map");
	store.deliver(projection, other.key, store.chatItem(projection, "ada", "elsewhere", false));
	assert(store.activeConvOf(projection.get()) === active, "a line in another room replaced the open conversation");
	assert(shellSame(shell, store.appShellState(projection.get())), "a line in another room replaced a shell field");
	assert(store.unreadTotal(projection.get()) > 0, "the other room's line was not counted unread");
	store.deliver(projection, open.key, store.chatItem(projection, "ada", "here", false));
	assert(store.activeConvOf(projection.get()) === active, "a line in the open room replaced the conversation");
	assert(shellSame(shell, store.appShellState(projection.get())), "a line in the open room replaced a shell field");
	assert(store.historyOf(projection, open.key).length > 0, "the open room's line was not recorded");
});

Deno.test("the rail foot reads the health of the directory granting its displayed name", () => {
	const view = new store.PageProjection();
	const home = dirId("home");
	const foreign = dirId("foreign");
	store.openDir(view, foreign, "foreign-route");
	store.openDir(view, home, "home-route");
	store.patchDir(view, home, { nick: "ada", session: "connected" });
	store.patchDir(view, foreign, { nick: "bo", session: "reconnecting" });
	const render = () =>
		renderToStaticMarkup(createElement(
			RoomsBrowserProvider,
			{ value: {} as RoomsBrowserController },
			createElement(
				RoomsSessionProvider,
				{ value: {} as RoomsSessionController },
				createElement(Foot, { dirs: view.get().dirs, home, standing: "", canInteract: true }),
			),
		));
	assert(render().includes('title="here"'), "a foreign outage replaced the home name's standing");
	store.patchDir(view, home, { session: "reconnecting" });
	store.patchDir(view, foreign, { session: "connected" });
	assert(render().includes('title="reconnecting…"'), "another directory hid the home name's outage");
	store.patchDir(view, home, { nick: "" });
	assert(render().includes('title="here"'), "the fallback name did not use its own directory's health");
});
