// Reading saved messages and changing recording policy require different access.
/// <reference lib="dom" />
import "../support/match_media.ts";
import { createElement as h } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { assert, assertEquals } from "@std/assert";
import { fixture } from "../support/managed_controller.ts";
import { viewer } from "../support/managed_viewer.ts";
import { HistorySettings, standingReply } from "../../web/ui/settings/History.tsx";
import { SessionSettings } from "../../web/ui/settings/Session.tsx";
import { RoomsSessionProvider } from "../../web/ui/controller/session.ts";
import { RoomsBrowserProvider } from "../../web/ui/controller/browser.ts";
import { createRoomsBrowserController } from "../../web/ui/controller/create_browser.ts";
import { RoomsProjectionProvider } from "../../web/ui/hooks.ts";
import { ManagedSessionProvider } from "../../web/ui/session/managed/context.tsx";
import { ModalProvider } from "../../web/ui/modal.ts";
import { CommitmentProvider } from "../../web/ui/commitment.tsx";
import { LocalRefusal, refusalText } from "../../lib/text/failure.ts";
import {
	historyKeptBy,
	historyKeptByOff,
	historyReadAgain,
	historyTitle,
	sessionSettingsLocation,
} from "../../lib/text/session_settings.ts";
import { historyPeerUnavailable } from "../../lib/text/settings.ts";
import { managedSessionText } from "../../lib/text/managed_session.ts";

for (
	const status of [
		"idle",
		"connecting",
		"connected",
		"unavailable",
	] satisfies import("../../web/ui/archive_model.ts").ArchiveTargetView["status"][]
) {
	Deno.test(`history retry is offered only for failed reads: ${status}`, () => {
		const f = fixture();
		try {
			const html = renderToStaticMarkup(h(
				RoomsSessionProvider,
				{ value: f.controller },
				h(HistorySettings, {
					canConfigure: false,
					canRead: true,
					keepHistory: false,
					archiveTarget: { kind: "owned", status, error: "" },
				}),
			));
			assertEquals(html.includes("historyReadAgain"), status === "unavailable");
			assert(!html.includes("keepHistoryToggle"));
		} finally {
			f.close();
		}
	});
}

Deno.test("an attached reader can retry saved history without changing recording", async () => {
	const f = fixture();
	const session = viewer({});
	f.page.controllerSelection.set({ kind: "attached", sturdyref: "session-link" });
	f.page.projection.set({ managedAccess: { status: "active", effective: { permissions: ["history"] } } });
	// Server rendering reads the fixture state as its initial snapshot.
	f.page.projection.api.getInitialState = f.page.projection.api.getState;
	const browser = createRoomsBrowserController(
		f.page,
		() => {},
		() => "/",
		() => Promise.resolve({ session, local: false }),
	);
	try {
		const html = renderToStaticMarkup(
			h(
				RoomsProjectionProvider,
				{ value: f.page.projection },
				h(
					RoomsBrowserProvider,
					{ value: browser },
					h(
						RoomsSessionProvider,
						{ value: f.controller },
						h(
							ManagedSessionProvider,
							{ value: session },
							h(
								ModalProvider,
								null,
								h(
									CommitmentProvider,
									null,
									h(SessionSettings, {
										keepHistory: false,
										archiveTarget: { kind: "owned", status: "unavailable", error: "offline" },
									}),
								),
							),
						),
					),
				),
			),
		);
		assert(html.includes("historyReadAgain"), "read-only attached access needs the recovery action");
		assert(html.includes("offline"), "the retry control must show the read failure that made it available");
		assert(!html.includes("keepHistoryToggle"), "read access cannot change shared recording policy");
	} finally {
		f.close();
		await session.close();
	}
});

Deno.test("history refusals name the available action and its Settings location", () => {
	for (
		const key of [
			"archive-invalid",
			"history-unavailable",
		] satisfies import("../../lib/text/local_refusals.ts").LocalRefusalKey[]
	) {
		const said = refusalText(new LocalRefusal(key));
		assert(said.includes(historyReadAgain));
		assert(said.includes(sessionSettingsLocation));
	}
});

Deno.test("an archive this access may not read shows its reason and offers no retry", async () => {
	const f = fixture();
	const session = viewer({});
	const browser = createRoomsBrowserController(
		f.page,
		() => {},
		() => "/",
		() => Promise.resolve({ session, local: false }),
	);
	try {
		const html = renderToStaticMarkup(h(
			RoomsBrowserProvider,
			{ value: browser },
			h(
				RoomsSessionProvider,
				{ value: f.controller },
				h(
					ModalProvider,
					null,
					h(HistorySettings, {
						canConfigure: false,
						canRead: true,
						keepHistory: true,
						archiveTarget: {
							kind: "peer",
							status: "denied",
							label: "Archive peer",
							error: "not permitted here",
						},
					}),
				),
			),
		));
		assert(html.includes("not permitted here"));
		assert(!html.includes("is unavailable"), "a peer this access may not read is not reported as unreachable");
		assert(html.includes(historyKeptBy("Archive peer")), "the reader is told who keeps the messages");
		assert(!html.includes(historyKeptByOff.split(".")[0]), "no advice about a switch this reader is not shown");
		assert(!html.includes("historyReadAgain"), "a retry cannot change what this access permits");
	} finally {
		f.close();
		await session.close();
	}
});

Deno.test("every archive-unavailable sentence names the retry control and where it is", () => {
	for (const said of [managedSessionText.archiveUnavailable, historyPeerUnavailable]) {
		assert(said.includes(historyReadAgain));
		assert(said.includes(historyTitle));
		assert(said.includes(sessionSettingsLocation));
	}
});

Deno.test("a retry's reply leaves the card once a later read changes the status", () => {
	const reply = { text: "choose the retry", under: "unavailable" } as const;
	assertEquals(standingReply(reply, "unavailable"), "choose the retry");
	assertEquals(standingReply(reply, "connected"), "", "the retry control is gone, so its advice goes too");
	assertEquals(
		standingReply({ text: "the switch failed", under: null }, "connected"),
		"the switch failed",
		"a read settling does not answer the switch",
	);
});
