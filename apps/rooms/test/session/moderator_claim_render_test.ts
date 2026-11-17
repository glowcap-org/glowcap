// The Issue moderator link button asks only the held room manager. Joined
// membership is not part of that operation, so the button stays offered while a
// room reconnects. This is render eligibility only: it proves neither an
// in-flight busy state nor a click. The controller and Rust proofs cover issuance.
/// <reference lib="dom" />
import "../support/match_media.ts";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { assert } from "../assert.ts";
import { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { RoomsManagedApplication, RoomsManagedWorkspace } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { RoomsBrowserController } from "../../web/ui/controller/browser.ts";
import type { RoomsSessionController } from "../../web/ui/controller/session.ts";
import { roomModeratorIssue } from "../../lib/text/room_authority.ts";

const store = await import("../../web/ui/store.ts");
const { dirId } = await import("../../web/ui/directory.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { RoomsProjectionProvider } = await import("../../web/ui/hooks.ts");
const { RoomsSessionProvider } = await import("../../web/ui/controller/session.ts");
const { RoomsBrowserProvider } = await import("../../web/ui/controller/browser.ts");
const { CommitmentProvider } = await import("../../web/ui/commitment.tsx");
const { ManagedSessionProvider } = await import("../../web/ui/session/managed/context.tsx");
const { RoomCapabilities } = await import("../../web/ui/cards/RoomCapabilities.tsx");

type Membership = "joining" | "joined" | "unavailable";

function claimButton(
	membership: Membership,
	available: boolean,
	facts: { manager: boolean; moderator: boolean },
): string | null {
	const page = new RoomsPage();
	store.openDir(page.projection, dirId("directory"), "");
	const room = store.ensureRoom(page.projection, dirId("directory"), "room", { persistId: "room", key: "room:room" });
	assert(room.type === "room", "fixture room");
	const grants = new Set(room.grants);
	if (facts.moderator) grants.add("steward");
	// The managed projection sets the moderator token and the steward grant from
	// one row fact, and the manager token from the held control.
	const conv = {
		...room,
		membership,
		grants,
		...(facts.manager ? { managerToken: "manager-token" } : {}),
		...(facts.moderator ? { stewardToken: "moderator-token" } : {}),
	};
	store.put(page.projection, conv);
	const held = {
		snapshot: () => Promise.resolve(undefined),
		free() {},
	} as unknown as RoomsManagedWorkspace;
	const managed = new ManagedRoomsSession(
		{ close: () => Promise.resolve(), free() {} } as unknown as RoomsManagedApplication,
		held,
		held,
		() => {},
	);
	managed.permits = () => true;
	const html = renderToStaticMarkup(
		createElement(
			RoomsProjectionProvider,
			{ value: page.projection },
			createElement(
				RoomsSessionProvider,
				{ value: {} as RoomsSessionController },
				createElement(
					RoomsBrowserProvider,
					{ value: {} as RoomsBrowserController },
					createElement(
						CommitmentProvider,
						null,
						createElement(
							ManagedSessionProvider,
							{ value: managed },
							createElement(RoomCapabilities, { conv, available, authoritySource: "local" }),
						),
					),
				),
			),
		),
	);
	return html.match(/<button[^>]*id="convcardStewardClaim"[^>]*>[^<]*<\/button>/)?.[0] ?? null;
}

for (
	const [membership, available] of [["joining", false], ["unavailable", false], ["joined", true]] as const
) {
	Deno.test(`a held manager without a moderator offers the claim while membership is ${membership}`, () => {
		const button = claimButton(membership, available, { manager: true, moderator: false });
		assert(button != null, "the claim button is missing");
		assert(button.includes(roomModeratorIssue), "the claim button has another label");
		assert(!/\sdisabled/.test(button), "the claim button is disabled with no authority act running");
	});
	Deno.test(`no held manager hides the claim while membership is ${membership}`, () => {
		assert(
			claimButton(membership, available, { manager: false, moderator: false }) == null,
			"the claim shows without a manager",
		);
	});
	Deno.test(`a held moderator hides the claim while membership is ${membership}`, () => {
		assert(
			claimButton(membership, available, { manager: true, moderator: true }) == null,
			"the claim shows over a held moderator",
		);
	});
}
