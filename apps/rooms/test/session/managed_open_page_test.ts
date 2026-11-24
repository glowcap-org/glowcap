// A page attached to a session elsewhere opens even when its link is lost while
// it opens and stays away past the wait a first send allows: the page shows the
// session as attached and its link's notice, and the session's link arrives once
// the link answers. A page that does not open closes its session, so nothing
// dials behind the page that says so. A read of the session's link that
// fails for another reason says why where the link would show, with Try now to
// read it again.
import "../support/match_media.ts";
import { createElement as h } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { assert, assertEquals } from "../assert.ts";
import { closed, FakeClock, linkedWorkspace, relinking } from "../support/managed_link.ts";
import { timedOut } from "../support/held_access_plan.ts";
import { refusalText } from "../../lib/text/failure.ts";
import { holdingsLinkUnread } from "../../lib/text/session_settings.ts";
import { sessionTryNow } from "../../lib/text/page.ts";
import { deferred, viewer } from "../support/managed_viewer.ts";
import { settle, until } from "../support/wait.ts";
import { LINK_WAIT_MS } from "../../web/ui/session/managed/link.ts";
import { ControllerSelection } from "../../web/ui/controller/selection.ts";
import { openOver, presentSession } from "../../web/ui/session/managed/open.ts";
const { PageProjection } = await import("../../web/ui/store/projection.ts");
const { SessionLinkHolding } = await import("../../web/ui/settings/Holdings.tsx");
const { RoomsBrowserProvider } = await import("../../web/ui/controller/browser.ts");
const { createRoomsBrowserController } = await import("../../web/ui/controller/create_browser.ts");
const { ModalProvider } = await import("../../web/ui/modal.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");

Deno.test("a page whose link is lost while it opens, and stays away past the wait, opens and shows the session's link once it answers", async () => {
	const first = linkedWorkspace("first", [], { effects: () => first.park() });
	first.polling(() => {
		first.lose();
		return Promise.reject(closed());
	});
	const second = linkedWorkspace("second", [], {
		effects: () => Promise.resolve([]),
		publish: () => Promise.resolve("ocapn://the-session"),
	});
	const back = deferred<void>();
	const clock = new FakeClock();
	const reports: unknown[] = [];
	const session = viewer(
		first.workspace,
		(_source, error) => reports.push(error),
		{ relink: () => back.promise.then(() => second.workspace) },
		false,
		clock,
	);
	const page = { projection: new PageProjection(), controllerSelection: new ControllerSelection() };
	await session.start();
	const stop = presentSession(page, session, (_source, error) => reports.push(error));
	assertEquals(
		[page.controllerSelection.getSnapshot(), session.link?.live],
		[{ kind: "attached", sturdyref: null }, false],
		"the page shows the session as attached while its link is away",
	);
	clock.advance(LINK_WAIT_MS);
	await settle();
	assertEquals(page.controllerSelection.getSnapshot(), { kind: "attached", sturdyref: null });
	back.resolve();
	await until(
		() => page.controllerSelection.getSnapshot().kind === "attached" && session.link?.live === true,
		"the link to answer",
	);
	await until(() => {
		const shown = page.controllerSelection.getSnapshot();
		return shown.kind === "attached" && shown.sturdyref === "ocapn://the-session";
	}, "the session's link once the link answers");
	assertEquals(reports, [], "the link's notice says why the page waited, so nothing more is reported");
	stop();
	await session.close();
});

Deno.test("a session link read still under way when the link is replaced is read again over the new link", async () => {
	const gate = deferred<string>();
	const first = linkedWorkspace("first", [], { effects: () => Promise.resolve([]), publish: () => gate.promise });
	const second = linkedWorkspace("second", [], {
		effects: () => Promise.resolve([]),
		publish: () => Promise.resolve("ocapn://the-session"),
	});
	const { session } = relinking(first.workspace, second.workspace);
	await session.start();
	const page = { projection: new PageProjection(), controllerSelection: new ControllerSelection() };
	const stop = presentSession(page, session, () => {});
	first.lose();
	await until(() => session.link?.live === true && first.state.freed === 1, "the new link");
	gate.reject(closed());
	await until(() => {
		const shown = page.controllerSelection.getSnapshot();
		return shown.kind === "attached" && shown.sturdyref === "ocapn://the-session";
	}, "the session's link, read over the new link");
	stop();
	await session.close();
});

Deno.test("a page that does not open closes its session, so its link dials no more", async () => {
	const first = linkedWorkspace("first", [], { effects: () => Promise.resolve([]) });
	const second = linkedWorkspace("second", []);
	const { session, dials } = relinking(first.workspace, second.workspace);
	await session.start();
	const page = { projection: new PageProjection(), controllerSelection: new ControllerSelection() };
	let stopped = 0;
	const stop = presentSession(page, session, () => {});
	const failure = new Error("the page did not render");
	const opened = await openOver(session, () => {
		stopped++;
		stop();
	}, () => Promise.reject(failure)).then(() => null, (error: unknown) => error);
	first.lose();
	await settle();
	assertEquals([opened, stopped, dials()], [failure, 1, 0]);
});

Deno.test("a session link read that fails for a reason other than a lost connection says why, and Try now reads it again", async () => {
	const failure = timedOut();
	const answers = [() => Promise.reject(failure), () => Promise.resolve("ocapn://the-session")];
	const first = linkedWorkspace("first", [], {
		effects: () => Promise.resolve([]),
		publish: () => (answers.shift() ?? (() => Promise.reject(new Error("read more than twice"))))(),
	});
	const { session } = relinking(first.workspace, linkedWorkspace("second", []).workspace);
	await session.start();
	const reports: unknown[] = [];
	const page = { projection: new PageProjection(), controllerSelection: new ControllerSelection() };
	const stop = presentSession(page, session, (_source, error) => reports.push(error));
	await until(() => {
		const shown = page.controllerSelection.getSnapshot();
		return shown.kind === "attached" && shown.unread != null;
	}, "the failed read to show");
	const shown = page.controllerSelection.getSnapshot();
	assert(shown.kind === "attached" && shown.unread != null, "the failed read shows");
	assertEquals([shown.sturdyref, shown.unread.failure, reports], [null, failure, [failure]]);
	const html = renderToStaticMarkup(
		h(
			RoomsBrowserProvider,
			{
				value: createRoomsBrowserController(
					new RoomsPage(),
					() => {},
					() => "/",
					() => Promise.resolve({ session, local: false }),
				),
			},
			h(ModalProvider, null, h(SessionLinkHolding, { shared: shown })),
		),
	);
	const said = renderToStaticMarkup(h("p", null, holdingsLinkUnread(refusalText(failure)))).slice(3, -4);
	assert(html.includes(said), "the page says why the link could not be read");
	assert(
		new RegExp(`<button[^>]* id="currentSessionLinkTryNow"[^>]*>(<[^>]*>)*${sessionTryNow}<`).test(html),
		"the page offers Try now for the read",
	);
	await shown.unread.readAgain();
	assertEquals(page.controllerSelection.getSnapshot(), { kind: "attached", sturdyref: "ocapn://the-session" });
	stop();
	await session.close();
});
