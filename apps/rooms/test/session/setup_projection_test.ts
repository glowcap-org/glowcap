// Session setup is a second React tree, drawn before any session exists.
// The page still owns the projection (error detail, showError), so that tree
// must wrap it. Omitting the provider crashes first paint and detach.

/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({
		matches: false,
		addEventListener() {},
		removeEventListener() {},
	}),
});

import { createElement, type ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { PageProjection } from "../../web/ui/store/core.ts";
import type { RoomsBrowserController } from "../../web/ui/controller/browser.ts";
const { SessionSetup } = await import("../../web/ui/SessionSetup.tsx");
const { RoomsProjectionProvider } = await import("../../web/ui/hooks.ts");
const { RoomsBrowserProvider } = await import("../../web/ui/controller/browser.ts");
const { ModalProvider } = await import("../../web/ui/modal.ts");
const { PageProjection: Projection } = await import("../../web/ui/store/core.ts");

const browser = new Proxy({} as RoomsBrowserController, {
	get: () => () => {},
});

function setupTree(projection: PageProjection | null): ReactNode {
	const inner = createElement(
		RoomsBrowserProvider,
		{ value: browser },
		createElement(ModalProvider, null, createElement(SessionSetup, null)),
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
