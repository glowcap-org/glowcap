// Session setup is a second React tree, drawn before any session exists.
// The page still owns the projection (error detail, showError), so that tree
// must wrap it. Omitting the provider crashes first paint and detach. The
// projection also says when this browser's saved session can't be read, and
// setup then shuts every act that opens it, each described by a notice that
// offers a separate workspace and preserves the original.

/// <reference lib="dom" />

import "../support/match_media.ts";
import { createElement, isValidElement, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { assertEquals } from "../assert.ts";
import { browserFailure } from "../support/browser_failure.ts";
import { SESSION_STATE_UNREADABLE, SESSION_UNREACHABLE } from "../../lib/error_codes.ts";
import { LocalRefusal } from "../../lib/text/failure.ts";
import {
	separateWorkspace,
	sessionDeleteCommit,
	sessionDeleteSay,
	sessionResetSay,
	sessionUnreadableSay,
} from "../../lib/text/session.ts";
import type { PageProjection } from "../../web/ui/store/projection.ts";
import type { RoomsBrowserController } from "../../web/ui/controller/browser.ts";
const { SessionSetup, SessionUnreadable, SetupAdvanced } = await import("../../web/ui/panes/SessionSetup.tsx");
const { noteSessionOpenFailure } = await import("../../web/ui/store/chrome.ts");
const { RoomsProjectionProvider } = await import("../../web/ui/hooks.ts");
const { RoomsBrowserProvider } = await import("../../web/ui/controller/browser.ts");
const { ModalProvider } = await import("../../web/ui/modal.ts");
const { PageProjection: Projection } = await import("../../web/ui/store/projection.ts");

const browser = new Proxy({} as RoomsBrowserController, {
	get: () => () => {},
});

const { SavedWorkspaces } = await import("../../web/ui/panes/SavedWorkspaces.tsx");

function setupTree(projection: PageProjection | null, choices?: string[]): ReactNode {
	const inner = createElement(
		RoomsBrowserProvider,
		{ value: browser },
		createElement(
			ModalProvider,
			null,
			createElement(SessionSetup, {
				renderSavedWorkspaces: choices &&
					((disabled: boolean, primary: boolean) =>
						createElement(SavedWorkspaces, {
							choices,
							pin: choices[0],
							initialError: "",
							disabled,
							primary,
						})),
			}),
		),
	);
	return projection == null ? inner : createElement(RoomsProjectionProvider, { value: projection }, inner);
}

Deno.test("session setup renders under the page projection", () => {
	const html = renderToStaticMarkup(setupTree(new Projection()));
	if (!html.includes("sessionSetup")) {
		throw new Error("session setup did not render");
	}
});

Deno.test("session setup refuses to render without the page projection", () => {
	try {
		renderToStaticMarkup(setupTree(null));
	} catch (error) {
		if (error instanceof Error && error.message.includes("outside its provider")) return;
		throw error;
	}
	throw new Error("session setup rendered without the page projection");
});

/** Whether setup offers a separate workspace after opening this browser's saved session
 * failed with `error`. Setup draws its notice from this fact, and a static
 * render reads a store's first state, so the fact is read from the page. */
function offeredAfter(error: unknown): boolean {
	const projection = new Projection();
	noteSessionOpenFailure(projection, error, "this-browser");
	return projection.get().savedSessionUnreadable;
}

/** The press of the control `id` in `node`, or null when none is drawn. */
function pressOf(node: ReactNode, id: string): (() => void) | null {
	if (Array.isArray(node)) {
		for (const child of node) {
			const press = pressOf(child, id);
			if (press != null) return press;
		}
		return null;
	}
	if (!isValidElement<{ id?: unknown; onClick?: unknown; children?: ReactNode }>(node)) return null;
	const { id: own, onClick, children } = node.props;
	if (own === id && typeof onClick === "function") return () => onClick();
	return pressOf(children, id);
}

/** Run `draw` on a page whose focus rests on nothing, as a confirmation reads it when it opens. */
function withDocument<T>(draw: () => T): T {
	const prior = {
		document: Object.getOwnPropertyDescriptor(globalThis, "document"),
		HTMLElement: Object.getOwnPropertyDescriptor(globalThis, "HTMLElement"),
	};
	Object.defineProperty(globalThis, "document", { configurable: true, value: { activeElement: null } });
	Object.defineProperty(globalThis, "HTMLElement", { configurable: true, value: class {} });
	try {
		return draw();
	} finally {
		for (const [name, descriptor] of Object.entries(prior)) {
			if (descriptor != null) Object.defineProperty(globalThis, name, descriptor);
			else Reflect.deleteProperty(globalThis, name);
		}
	}
}

Deno.test("unreadable saved data offers a separate workspace", () => {
	if (!offeredAfter(browserFailure(-12, "unreadable", SESSION_STATE_UNREADABLE))) {
		throw new Error("setup offered no separate workspace for saved data it can't read");
	}
	const html = renderToStaticMarkup(createElement(SessionUnreadable, { busy: false, onSeparate() {} }));
	const say = renderToStaticMarkup(createElement("p", { id: "sessionUnreadableSay" }, sessionUnreadableSay));
	if (!html.includes(say)) throw new Error("the notice does not say what happened");
	if (!/<button[^>]* id="sessionUnreadableSeparate"[^>]* aria-describedby="sessionUnreadableSay"/.test(html)) {
		throw new Error("the workspace choice is not described by what happened");
	}
	if (!html.includes(`>${separateWorkspace}</button>`)) {
		throw new Error("the notice does not name the separate workspace");
	}
});

/** Setup's acts and what describes each, drawn under a page whose saved
 * session is unreadable or not. */
function doors(unreadable: boolean) {
	const projection = new Projection();
	if (unreadable) {
		noteSessionOpenFailure(projection, browserFailure(-12, "unreadable", SESSION_STATE_UNREADABLE), "this-browser");
	}
	// A static render reads a store's first state, so it is told the current one.
	projection.api.getInitialState = projection.api.getState;
	const html = renderToStaticMarkup(setupTree(projection));
	const door = (id: string) => {
		const tag = new RegExp(`<button[^>]* id="${id}"[^>]*>`).exec(html)?.[0];
		if (tag == null) throw new Error(`setup drew no ${id}`);
		return {
			disabled: /\sdisabled=""/.test(tag),
			describedBy: /aria-describedby="([^"]*)"/.exec(tag)?.[1] ?? null,
		};
	};
	// The notice every shut act is described by is drawn with them.
	const notice = html.includes(
		renderToStaticMarkup(createElement("p", { id: "sessionUnreadableSay" }, sessionUnreadableSay)),
	);
	return {
		notice,
		local: door("sessionUseLocal"),
		attach: door("sessionAttach"),
		reset: door("sessionResetAsk"),
		delete: door("sessionDeleteAsk"),
	};
}

Deno.test("an unreadable saved session shuts every act that opens it, each described by the notice", () => {
	const shut = { disabled: true, describedBy: "sessionUnreadableSay" };
	assertEquals(doors(true), {
		notice: true,
		local: shut,
		attach: shut,
		reset: shut,
		delete: { disabled: false, describedBy: null },
	});
});

Deno.test("a known unreadable workspace offers a fresh one before retrying", () => {
	const projection = new Projection();
	noteSessionOpenFailure(projection, browserFailure(-12, "unreadable", SESSION_STATE_UNREADABLE), "this-browser");
	projection.api.getInitialState = projection.api.getState;
	const html = renderToStaticMarkup(setupTree(projection, ["saved", "other"]));
	const resume = html.match(/<button[^>]*>Resume workspace<\/button>/)?.[0];
	const separate = html.match(/<button[^>]*id="sessionUnreadableSeparate"[^>]*>/)?.[0];
	if (
		!resume?.includes('disabled=""') || !resume.includes('data-variant="quiet"') ||
		!separate?.includes('data-variant="primary"') || !html.includes('value="other"')
	) {
		throw new Error("setup led back into an unreadable workspace or hid the alternatives");
	}
});

Deno.test("a readable saved session leaves the local door open and the attach door waiting for a link", () => {
	const open = { disabled: false, describedBy: null };
	assertEquals(doors(false), {
		notice: false,
		local: open,
		attach: { disabled: true, describedBy: null },
		reset: open,
		delete: open,
	});
});

Deno.test("a confirmation to forget rooms and settings asked before saved data proved unreadable is not drawn", () => {
	const draw = (unreadable: boolean) =>
		withDocument(() =>
			renderToStaticMarkup(createElement(SetupAdvanced, {
				open: true,
				asking: "reset",
				busy: null,
				unreadable,
				onToggle() {},
				onAsk() {},
				onKeep() {},
				onCommit() {},
			}))
		);
	const asks = (html: string) => html.includes(renderToStaticMarkup(createElement("p", null, sessionResetSay)));
	if (!asks(draw(false))) throw new Error("a readable session's reset asked nothing");
	const html = draw(true);
	if (asks(html)) throw new Error("the reset's confirmation stayed open");
	const reset = /<button[^>]* id="sessionResetAsk"[^>]*>/.exec(html)?.[0] ?? "";
	if (!/\sdisabled=""/.test(reset)) throw new Error("the reset stayed open");
});

Deno.test("other open failures do not show the unreadable notice", () => {
	for (
		const error of [
			browserFailure(-12, "unreachable", SESSION_UNREACHABLE),
			new LocalRefusal("session-startup-failed"),
			new Error("the session's saved data is in a form this version of Rooms can't read"),
		]
	) {
		if (offeredAfter(error)) throw new Error(`setup showed the unreadable notice for ${String(error)}`);
	}
});

Deno.test("deleting all browser data still requires the advanced disclosure's confirmation", () => {
	const asked: string[] = [];
	const closed = SetupAdvanced({
		open: false,
		asking: null,
		busy: null,
		unreadable: false,
		onToggle() {},
		onAsk: (act) => asked.push(act),
		onKeep() {},
		onCommit() {},
	});
	pressOf(closed, "sessionDeleteAsk")?.();
	const act = asked[0];
	if (act !== "delete") throw new Error(`the notice asked ${act}`);
	const html = withDocument(() =>
		renderToStaticMarkup(createElement(SetupAdvanced, {
			open: true,
			asking: act,
			busy: null,
			unreadable: false,
			onToggle() {},
			onAsk() {},
			onKeep() {},
			onCommit() {},
		}))
	);
	const say = renderToStaticMarkup(createElement("p", null, sessionDeleteSay));
	if (!html.startsWith("<details") || !/^<details[^>]* open=""/.test(html)) {
		throw new Error("the disclosure holding the confirmation stayed shut");
	}
	if (!html.includes(say) || !html.includes(sessionDeleteCommit)) {
		throw new Error("the disclosure did not show the deletion's confirmation");
	}
});
