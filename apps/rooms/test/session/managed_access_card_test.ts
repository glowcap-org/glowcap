// A card opened on a held access while the page lets go of that access: the
// person removing it from the card, a share letting go of the new access it
// made, and a share's new access failing for good when it is held again. The
// card draws nothing once its access is gone, and drawing it throws nothing.
import "../support/match_media.ts";
import { assert, assertEquals } from "../assert.ts";
import { lostForGood, type Page, page } from "../support/held_access_page.ts";
import { closedClean, refused, relink } from "../support/held_access_gestures.ts";
import { made, prepareShare } from "../support/share_gestures.ts";
import { createElement as h } from "react";
import { renderToStaticMarkup } from "react-dom/server";

const { HeldCard } = await import("../../web/ui/settings/SessionAccess.tsx");
const { ManagedSessionProvider } = await import("../../web/ui/session/managed/context.tsx");
const { RoomsBrowserProvider } = await import("../../web/ui/controller/browser.ts");
const { createRoomsBrowserController } = await import("../../web/ui/controller/create_browser.ts");
const { ModalProvider } = await import("../../web/ui/modal.ts");
const { CommitmentProvider } = await import("../../web/ui/commitment.tsx");
const { RoomsPage } = await import("../../web/ui/page.ts");

/** The markup of the Manage card a door opened on the access held as `id`. */
function manageCard(f: Page, id: string): string {
	const controller = createRoomsBrowserController(
		new RoomsPage(),
		() => {},
		() => "/",
		() => Promise.resolve({ session: f.session, local: true }),
	);
	return renderToStaticMarkup(
		h(
			RoomsBrowserProvider,
			{ value: controller },
			h(
				ModalProvider,
				null,
				h(
					CommitmentProvider,
					null,
					h(
						ManagedSessionProvider,
						{ value: f.session },
						h(HeldCard, { door: { kind: "manage", id }, open: true, onClose() {}, onGone() {} }),
					),
				),
			),
		),
	);
}

/** Open the card on `id`, let `release` let go of its access, and hold that
 * the card drew while the access was held and draws nothing after. */
async function cardCloses(f: Page, id: string, release: () => Promise<unknown>): Promise<void> {
	assert(manageCard(f, id).includes("session-grant-edit-modal"), "the card shows the held access");
	await release();
	assertEquals(
		[f.management.held.some((control) => control.id === id), manageCard(f, id)],
		[false, ""],
		"the access is let go of, and its card draws nothing",
	);
}

Deno.test("a card whose access the person removes draws nothing once it is removed", async () => {
	const f = await page();
	await cardCloses(f, "source", () => f.management.forget(f.sourceRow()));
	assertEquals(f.reports, []);
	await closedClean(f);
});

Deno.test("a card on a share's unsaved new access draws nothing once the share lets go of it", async () => {
	const f = await page();
	await prepareShare(f);
	await f.management.submitIssue();
	const id = made(f).id;
	// The next link cannot reach the source again, so nothing can ask for the
	// new access again, and the share ends and lets go of it.
	f.plan.sources.push(lostForGood);
	await cardCloses(f, id, () => relink(f));
	assertEquals(f.management.issue?.phase, "lost");
	await closedClean(f);
});

Deno.test("a card on a share's new access draws nothing once holding it again fails for good", async () => {
	const f = await page();
	await prepareShare(f);
	await f.management.submitIssue();
	const id = made(f).id;
	await cardCloses(f, id, async () => {
		// The new access loses its connection, which is its source's, so the
		// share asks the source for it again once the source is reached, and
		// the access it answers with reads as gone.
		f.plan.cut = "made";
		await refused(() => f.management.refresh(made(f)));
		await f.moved();
		f.plan.read = "final";
		await refused(() => f.management.reachAgain(f.sourceRow()));
		await f.moved();
	});
	assertEquals(f.management.issue?.phase, "lost");
	await closedClean(f);
});
