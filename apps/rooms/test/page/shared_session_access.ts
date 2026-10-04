// Session access is a consequential authority choice. All three levels and
// their consequences remain visible together when the modal has room, then
// become a clean reading-order stack before their prose is squeezed.
//
// What a link is worth once it is issued belongs here too: what a read-only
// one holds its browser to, what revoking it does to a browser already using
// it, and what a browser already attached to the session does with a second
// link to it.

import type { Browser, Page } from "playwright";
import { namedRoomRow } from "../support/conversation_row.ts";
import { proveAttachedSessionHolding } from "./holdings.ts";
import { fail } from "./harness.ts";
import { cannotSendReadOnly } from "../../lib/text/conversation.ts";

/** Sent while the shared link has its access, to establish that a line reaches
 * the browser holding it at all. */
const LIVE_LINE = "said while the link had access";
/** Sent while the same link is paused. It must reach nobody. */
const PAUSED_LINE = "said while the link was paused";
/** How long a paused view is watched for a line it must never be given. */
const PAUSED_SILENCE = 10_000;
/** Created while the link is paused, so what a paused view is answered with is
 * visibly the session now rather than the session it last saw. */
const PAUSED_ERA_ROOM = "paused-era";

/** What the composer says it cannot do, read where a reader reads it: the line
 * under the field, which stays put while a draft covers the placeholder. */
function composerSaid(page: Page): Promise<string> {
	return page.locator("#composerAvailability").textContent({ timeout: 30_000 })
		.then((said) => said?.trim() ?? "", () => "");
}

interface AccessLayout {
	readonly container: { left: number; right: number };
	readonly choices: { left: number; right: number; top: number; bottom: number }[];
	readonly columns: { left: number; right: number; top: number; bottom: number }[];
}

async function layout(page: Page): Promise<AccessLayout | null> {
	return await page.evaluate(() => {
		const choices = document.querySelector<HTMLElement>(".choices");
		if (choices == null) return null;
		const container = choices.getBoundingClientRect();
		return {
			container: { left: container.left, right: container.right },
			choices: [...choices.querySelectorAll<HTMLElement>(":scope > .choice")].map((choice) => {
				const bounds = choice.getBoundingClientRect();
				return { left: bounds.left, right: bounds.right, top: bounds.top, bottom: bounds.bottom };
			}),
			columns: [...document.querySelectorAll<HTMLElement>(".session-access-column")].map((column) => {
				const bounds = column.getBoundingClientRect();
				return { left: bounds.left, right: bounds.right, top: bounds.top, bottom: bounds.bottom };
			}),
		};
	});
}

async function proveSharedSessionAccessLayout(page: Page): Promise<void> {
	const wide = await layout(page);
	if (
		wide == null || wide.choices.length !== 3 || wide.columns.length !== 2 ||
		Math.abs(wide.columns[0].top - wide.columns[1].top) > 1 ||
		wide.columns[0].right >= wide.columns[1].left ||
		wide.choices.some((choice, at) =>
			Math.abs(choice.left - wide.container.left) > 1 ||
			Math.abs(choice.right - wide.container.right) > 1 ||
			(at > 0 && choice.top <= wide.choices[at - 1].bottom)
		)
	) fail(`Session access did not show creation and inventory columns: ${JSON.stringify(wide)}`);

	const prior = page.viewportSize();
	await page.setViewportSize({ width: 390, height: 720 });
	const narrow = await layout(page);
	if (
		narrow == null || narrow.choices.length !== 3 || narrow.columns.length !== 2 ||
		narrow.columns[1].top <= narrow.columns[0].bottom ||
		narrow.choices.some((choice, at) =>
			Math.abs(choice.left - narrow.container.left) > 1 ||
			Math.abs(choice.right - narrow.container.right) > 1 ||
			(at > 0 && choice.top <= narrow.choices[at - 1].bottom)
		)
	) fail(`Session access did not become a clean phone stack: ${JSON.stringify(narrow)}`);
	if (prior != null) await page.setViewportSize(prior);
}

export async function issueReadOnlySessionAccess(page: Page): Promise<string> {
	await page.click("#sessionAccessOpen");
	const modal = page.locator(".session-access-modal");
	await proveSharedSessionAccessLayout(page);
	await modal.getByLabel("Who or what is this for?").fill("Read-only display");
	await modal.getByRole("radio", { name: /Read only/ }).check();
	await modal.getByRole("button", { name: "Create access link" }).click();
	const grant = modal.locator(".session-grant").filter({ hasText: "Read-only display" });
	await grant.waitFor();
	const revokeOnHeading = await grant.evaluate((entry) => {
		const revoke = [...entry.querySelectorAll("button")].find((button) => button.textContent?.includes("Revoke"));
		const copy = entry.querySelector(".copy-field");
		const name = entry.querySelector(".entry-name");
		if (revoke == null || copy == null || name == null) return null;
		const act = revoke.getBoundingClientRect();
		const named = name.getBoundingClientRect();
		return {
			beforeTheLink: Boolean(revoke.compareDocumentPosition(copy) & Node.DOCUMENT_POSITION_FOLLOWING),
			// The act shares the name's line rather than folding under it. A
			// column too narrow to hold both wraps instead, which puts a
			// destructive act on a line of its own with a hole beside it.
			onTheNamesLine: act.top < named.bottom && named.top < act.bottom,
		};
	});
	if (revokeOnHeading == null || !revokeOnHeading.beforeTheLink) {
		fail("an active access link did not keep its revoke control on the heading row");
	}
	if (!revokeOnHeading.onTheNamesLine) {
		fail("an active access link folded its revoke control onto a line below the name it acts on");
	}
	// The history question was left unticked, and a link that was not given that
	// authority does not wear the mark that says it has it. Reading everything
	// recorded before a link existed is its own answer rather than something that
	// arrives with an access level.
	if (await grant.getByText("Earlier messages").count() !== 0) {
		fail("a link issued without the earlier-messages question answered claimed it anyway");
	}
	const sturdyref = (await grant.locator(".copy-field-text").textContent())?.trim() ?? "";
	if (!sturdyref.startsWith("ocapn://") || !sturdyref.includes("/s/")) {
		fail(`Session access returned no sturdyref: ${JSON.stringify(sturdyref)}`);
	}
	await modal.getByRole("button", { name: "Close" }).click();
	return sturdyref;
}

/** A read-only link, in a browser of its own, holds that browser to what it
 * says: it can read the workspace and change nothing in it, administer
 * nothing, and replace nothing. Then the administering browser revokes it,
 * and the reading browser is told rather than left wondering. */
export async function proveObserveGrantIsAttenuatedThenRevoked(
	browser: Browser,
	httpPort: number,
	observeSturdyref: string,
	administering: Page,
): Promise<void> {
	const observingContext = await browser.newContext();
	const observing = await observingContext.newPage();
	await observing.goto(`http://127.0.0.1:${httpPort}/`);
	await observing.waitForSelector("#sessionSetup");
	await observing.fill("#sessionSetupCapability", observeSturdyref);
	await Promise.all([
		observing.waitForNavigation({ waitUntil: "domcontentloaded" }),
		observing.click("#sessionAttach"),
	]);
	await observing.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await namedRoomRow(observing, "mirror-one").waitFor();
	if (await composerSaid(observing) !== cannotSendReadOnly) {
		fail(`an observe grant painted a composer that claimed it could send: ${await composerSaid(observing)}`);
	}
	if (
		await observing.locator(
			"#newRoomBtn:visible, #newDmBtn:visible, #leaveBtn:visible, #roomList .room-leave:visible, #members .dm-btn:visible",
		).count() !== 0
	) {
		fail("an observe grant painted conversation mutation controls");
	}
	if (
		!await observing.locator("#roomStanding").isDisabled() || !await observing.locator("#standingBtn").isDisabled()
	) {
		fail("an observe grant offered a standing mutation");
	}
	await observing.click("#roomAbout");
	if (await observing.locator("#convcardCapabilitiesTab, #convcardLeaveAsk").count() !== 0) {
		fail("an observe grant painted room authority controls");
	}
	if (await observing.locator("#convcardTabs").count() !== 0) {
		fail("an observe grant drew a one-item tab bar with no choice to make");
	}
	if (await observing.getAttribute("#convcardAboutPanel", "role") !== null) {
		fail("a room with no tab choice kept an orphaned tabpanel role");
	}
	await observing.click("#convcardClose");
	await observing.click("#settingsBtn");
	await observing.click("#sessionTab");
	await observing.getByText("This capability is read only.", { exact: false }).waitFor();
	if (await observing.locator("#sessionAccessOpen").count() !== 0) {
		fail("an observe grant could open session administration");
	}
	if (await observing.locator("#holdingsTab").count() !== 0) {
		fail("an observe grant exposed authority holdings it cannot administer");
	}
	await observing.click("#reachabilityTab");
	if (
		await observing.locator("#directoryLocator").count() !== 1 ||
		await observing.locator("#dmSettingsForm").count() !== 0
	) {
		fail("an observe grant did not separate network addresses from connection mutations");
	}
	await observing.click("#sessionTab");
	await observing.click("#sessionDataOpen");
	if (await observing.locator("#stateImport").count() !== 0) {
		fail("an observe grant could replace the durable checkpoint");
	}
	await observing.locator(".session-data-modal").getByRole("button", { name: "Close" }).click();
	await observing.click("#settingsClose");

	// Calibration for the silence later in this phase. While the link has its
	// access, a line sent into the room reaches the browser holding it, and it
	// reaches it about as fast as it reaches the sender. Without this, a paused
	// view that received nothing would be equally consistent with a view that had
	// quietly stopped receiving anything at all, and the check would be a finding
	// about itself.
	await namedRoomRow(administering, "mirror-one").locator(".room-open").click();
	await administering.fill("#line", LIVE_LINE);
	const sentAt = Date.now();
	await administering.press("#line", "Enter");
	await observing.locator(`#log .bubble:has-text("${LIVE_LINE}")`).waitFor({ timeout: 30_000 })
		.catch(() => fail("a live access link was not being sent the room to begin with"));
	// How long that took is what makes the wait below mean anything. A line
	// reaches an entitled view in well under a second here, so a paused one that
	// has not been given the same line after PAUSED_SILENCE has not been given
	// it. If this machine ever got slow enough for those two numbers to meet,
	// the silence would stop being evidence and start being the clock, so the
	// margin is asserted rather than assumed.
	const liveDelivery = Date.now() - sentAt;
	if (liveDelivery * 5 > PAUSED_SILENCE) {
		fail(`a line took ${liveDelivery}ms to reach a live view, leaving no margin under ${PAUSED_SILENCE}ms`);
	}

	await administering.click("#settingsBtn");
	await administering.click("#holdingsTab");
	await administering.click("#sessionAccessOpen");
	const grantToRevoke = administering.locator(".session-grant").filter({ hasText: "Read-only display" });

	// Pausing a link reaches the browser already holding it. That is the whole
	// point of it being the ledger's answer rather than the link's: the moment
	// anyone wants to pause access is the moment somebody is using it, and a
	// pause that waited for them to reconnect would be no pause at all. The
	// reason travels with it, because a window that has gone quiet and cannot say
	// why is indistinguishable from one that has broken.
	await grantToRevoke.getByRole("button", { name: "Edit…" }).click();
	const editing = administering.locator(".session-grant-edit-modal");
	await editing.waitFor();
	await administering.click("#sessionGrantPause");
	await administering.fill("#sessionGrantNote", "Back on Monday");
	await administering.click("#sessionGrantPauseCommit");
	await observing.waitForFunction(
		() =>
			document.getElementById("composerAvailability")?.textContent?.trim() ===
				"You cannot send while your access is paused.",
		undefined,
		{ timeout: 30_000 },
	).catch(async () => fail(`a paused link left the browser holding it saying ${await composerSaid(observing)}`));

	// Said where a reader will see it, and for as long as it is true. A toast is
	// an event, and a pause is a standing fact: whoever looked away, reloaded, or
	// arrived afterwards would otherwise get a workspace they cannot use with no
	// account of why.
	await observing.locator(".session-paused-notice").getByText("Back on Monday", { exact: false })
		.waitFor({ timeout: 30_000 })
		.catch(() => fail("a paused link said so nowhere a reader would see it"));

	// And what it can see goes with the access. A holder that keeps the rooms,
	// the directories, and who is in them has read the session, whether or not it
	// may also act in it.
	await observing.waitForFunction(() => document.querySelectorAll("#roomList li .rname").length === 0, undefined, {
		timeout: 30_000,
	}).catch(async () =>
		fail(
			`a paused link kept rooms it may no longer read: ${
				JSON.stringify(await observing.locator("#roomList li").allTextContents())
			}`,
		)
	);

	// The session carries on without it, and that is the part a reload used to
	// give away. A browser holding a paused link only looks frozen: it has
	// stopped being sent anything, but a reload asks again, and what it was
	// answered with was the session as it stands now — including this room,
	// created while it was paused.
	await editing.getByRole("button", { name: "Close" }).click();
	await editing.waitFor({ state: "detached" });
	await administering.locator(".session-access-modal").getByRole("button", { name: "Close" }).click();
	await administering.click("#settingsClose");
	await administering.click("#newRoomBtn");
	await administering.fill("#newRoomInput", PAUSED_ERA_ROOM);
	await administering.press("#newRoomInput", "Enter");
	await namedRoomRow(administering, PAUSED_ERA_ROOM, true).waitFor({ timeout: 30_000 });
	await namedRoomRow(administering, "mirror-one").locator(".room-open").click();
	// The new room is what this browser is looking at now, so the switch back has
	// to land before anything is typed into the composer under it.
	await administering.waitForFunction(
		() => document.getElementById("roomName")?.textContent?.trim() === "mirror-one",
		undefined,
		{ timeout: 30_000 },
	);
	await administering.fill("#line", PAUSED_LINE);
	await administering.press("#line", "Enter");
	await administering.locator(`#log .bubble:has-text("${PAUSED_LINE}")`).waitFor({ timeout: 30_000 });
	const leaked = await observing.locator(`#log .bubble:has-text("${PAUSED_LINE}")`)
		.waitFor({ timeout: PAUSED_SILENCE }).then(() => true, () => false);
	if (leaked) fail("a paused link was still being sent the room");
	// Nor does the room itself arrive, on the page as it stands. The reload below
	// asks what a returning browser is answered with; this asks what the one
	// already open is told, and they fail differently: a view that is still being
	// sent the session shows the new room without being asked for anything.
	if (await namedRoomRow(observing, PAUSED_ERA_ROOM).count() !== 0) {
		fail("a paused link was shown a room created while it was paused");
	}

	await observing.reload();
	await observing.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await observing.locator(".session-paused-notice").getByText("Back on Monday", { exact: false })
		.waitFor({ timeout: 30_000 })
		.catch(() => fail("a paused link came back from a reload with nothing saying it was paused"));
	// And it is not keeping the session anywhere either. The rail and the roster
	// say what is on screen; this is what the browser would come back to on its
	// own, before the session has answered a returning tab at all.
	const stored = await observing.evaluate(() => {
		const saved = JSON.parse(localStorage.getItem("rooms.workspace-state") ?? "null");
		const session = saved?.session ?? null;
		return session === null ? null : {
			directories: (session.directories ?? []).length,
			conversations: (session.conversations ?? []).map((row: { name: string }) => row.name),
			standing: session.standing ?? "",
			active: session.active,
		};
	});
	if (
		stored === null || stored.directories !== 0 || stored.conversations.length !== 0 ||
		stored.standing !== "" || stored.active !== null
	) {
		fail(`a paused link kept the session on this device: ${JSON.stringify(stored)}`);
	}
	const holding = await observing.evaluate(() => ({
		rooms: [...document.querySelectorAll("#roomList li .rname")].map((row) => row.textContent?.trim() ?? ""),
		directs: [...document.querySelectorAll("#dmList li .rname")].map((row) => row.textContent?.trim() ?? ""),
		// What the rail says when it is holding nothing, which is a claim of its
		// own: a paused view is not reaching for anything.
		said: [...document.querySelectorAll("#roomList li.empty, #dmList li.empty")]
			.map((row) => row.textContent?.trim() ?? ""),
		// The phone's shortcut to the rooms screen. CSS hides it on a wide window,
		// so this asks the page whether it drew one at all rather than whether one
		// is visible here.
		browse: document.querySelectorAll("#browseRoomsBtn").length,
		// The questions on that card, which cannot be answered. Drawn at full
		// strength they invite three answers under a lead that has just said none
		// of them will be taken.
		fields: (() => {
			const group = document.querySelector(".join-fields");
			if (group == null) return null;
			return { inert: group.hasAttribute("inert"), opacity: getComputedStyle(group).opacity };
		})(),
	}));
	if (holding.rooms.length !== 0 || holding.directs.length !== 0) {
		fail(`a paused link came back from a reload still holding the session: ${JSON.stringify(holding)}`);
	}
	// And what the empty rail says is its own claim. Left to the ordinary empty
	// texts it read "Reaching a directory…", which is work in progress that is
	// not happening, and the direct list offered a message the reader cannot send.
	if (holding.browse !== 0) {
		fail("a paused link was offered a way to browse live rooms it cannot see");
	}
	if (holding.fields === null || !holding.fields.inert || Number(holding.fields.opacity) >= 1) {
		fail(
			`a paused link was shown a join form drawn as if it would take an answer: ${
				JSON.stringify(holding.fields)
			}`,
		);
	}
	if (holding.said.some((said) => !said.includes("paused"))) {
		fail(`a paused link's empty rail claimed something else was going on: ${JSON.stringify(holding.said)}`);
	}

	// And the window is still the workspace's, empty or not. A bar above the
	// conversation takes a row of its own, and the row the conversation holds is
	// the one bounded row at the end; a bar added without a row for it lands in
	// an implicit row instead, which is `auto`, and the log adds no height of its
	// own because it is positioned inside its column. The page then ends where
	// the composer does, with bare paper under it for the rest of the window.
	const filled = await observing.evaluate(() => {
		const content = document.getElementById("content");
		if (content == null) return -1;
		return globalThis.innerHeight - content.getBoundingClientRect().bottom;
	});
	if (filled < 0 || filled > 2) {
		fail(`a paused link left ${filled}px of the window under the workspace`);
	}
	// Two surfaces, two jobs. The bar carries the state and whatever reason came
	// with it, and the composer says only what it cannot do. One sentence on both,
	// one directly above the other, reads as the page repeating itself rather than
	// as each answering for what it owns.
	if (await composerSaid(observing) !== "You cannot send while your access is paused.") {
		fail(`a paused link came back from a reload saying ${await composerSaid(observing)}`);
	}

	// And Settings says which capability this is. Read only is what the last arm
	// of that sentence means, so a capability carrying nothing falls into it and
	// the page tells a paused reader they are holding a read-only link — which is
	// what they will be holding again, and is not what they hold.
	await observing.click("#settingsBtn");
	await observing.click("#sessionTab");
	await observing.getByText("This capability is paused.", { exact: false }).waitFor({ timeout: 30_000 })
		.catch(async () =>
			fail(
				`a paused link was told in Settings that it is ${
					JSON.stringify(await observing.locator("#currentSessionLegend ~ * .launch").textContent())
				}`,
			)
		);
	await observing.click("#settingsClose");

	// A browser meeting the link for the first time while it is paused lands in
	// the same place, rather than failing to attach. Attaching hands this
	// browser's own workspace over the moment the session says it will take one,
	// and this holder's would be refused — so a paused link has to say that door
	// is shut, or handing somebody a link you have paused gives them an error
	// instead of the reason.
	const arrivingContext = await browser.newContext();
	const arriving = await arrivingContext.newPage();
	await arriving.goto(`http://127.0.0.1:${httpPort}/`);
	await arriving.waitForSelector("#sessionSetup");
	await arriving.fill("#sessionSetupCapability", observeSturdyref);
	await Promise.all([
		arriving.waitForNavigation({ waitUntil: "domcontentloaded" }),
		arriving.click("#sessionAttach"),
	]).catch(async () =>
		fail(
			`a browser handed an already-paused link could not attach with it: ${
				JSON.stringify(await arriving.textContent("#sessionSetup"))
			}`,
		)
	);
	await arriving.waitForSelector("#boot", { state: "detached", timeout: 60_000 });
	await arriving.locator(".session-paused-notice").getByText("Back on Monday", { exact: false })
		.waitFor({ timeout: 30_000 })
		.catch(() => fail("a browser handed an already-paused link was not told why it has nothing"));
	await arrivingContext.close();

	// Letting it back in restores what it was issued with, without anyone having
	// to remember what that was, and hands back the session as it stands now.
	// That makes the emptiness above a refusal rather than a
	// browser that had lost the session for good.
	await administering.click("#settingsBtn");
	await administering.click("#holdingsTab");
	await administering.click("#sessionAccessOpen");
	await grantToRevoke.getByRole("button", { name: "Edit…" }).click();
	await editing.waitFor();
	await administering.click("#sessionGrantResume");
	await namedRoomRow(observing, PAUSED_ERA_ROOM).waitFor({ timeout: 30_000 })
		.catch(() => fail("a resumed link was not given back the session it may read again"));
	await observing.waitForFunction(
		(readOnly) => document.getElementById("composerAvailability")?.textContent?.trim() === readOnly,
		cannotSendReadOnly,
		{ timeout: 30_000 },
	).catch(async () =>
		fail(`lifting a pause did not give back the access it was issued with: ${await composerSaid(observing)}`)
	);
	await editing.getByRole("button", { name: "Close" }).click();
	await editing.waitFor({ state: "detached" });

	await grantToRevoke.getByRole("button", { name: "Revoke…" }).click();
	await grantToRevoke.getByRole("button", { name: "Revoke access" }).click();
	await observing.getByText("This session capability was revoked.", { exact: false }).waitFor();
	await observingContext.close();
	await administering.locator(".session-access-modal").getByRole("button", { name: "Close" }).click();
	await administering.click("#settingsClose");
}

/** Changing which capability a browser holds for the session it is already in.
 * Both links name one peer, and a Host keeps one session per partner, so a
 * browser that opens a session to check the second link meets that rule
 * instead of the session it is already talking through, and the refusal it
 * hands back reads as a complaint about the paste. Settings is where a reader
 * has just been issued the link, so it is where they try it. */
export async function proveSecondAccessLinkForTheSamePeer(
	administering: Page,
	moving: Page,
	attachThroughSettings: (page: Page, capability: string, what: string) => Promise<void>,
	heldSturdyref: string,
	revokedSturdyref: string,
): Promise<void> {
	// A revoked link names the same peer as the one in hand, so it takes the
	// same path as a live one and is the likeliest stale thing a reader has:
	// this modal is where revoked links come from. It has to be refused here,
	// while the working link is still in hand, rather than accepted and found
	// out on the reload that has already dropped it.
	await moving.click("#settingsBtn");
	await moving.waitForSelector("#settingsTitle");
	await moving.click("#sessionTab");
	await moving.click("#sessionAttachOpen");
	await moving.waitForSelector("#sessionAttachTitle");
	await moving.fill("#sharedSessionCapability", revokedSturdyref);
	await moving.click("#sessionAttachGo");
	const refusal = moving.locator('.session-attach-modal .said[data-kind="failure"]');
	await refusal.waitFor({ timeout: 30_000 })
		.catch(() => fail("a revoked capability for the attached peer was taken without a word"));
	// What it says matters as much as that it says something: the paste was
	// fine, so sending a reader back to check it is the wrong errand.
	const said = (await refusal.innerText()).replace(/\s+/g, " ");
	if (!said.includes("does not know this capability")) {
		fail(`a revoked capability was refused with the wrong reason: ${JSON.stringify(said)}`);
	}
	// The refused link is still in the field, so leaving is a discard like any
	// other unfinished edit.
	await moving.locator(".session-attach-modal").getByRole("button", { name: "Close" }).click();
	await moving.click("#settingsUnsavedDiscard");
	await moving.click("#settingsClose");
	if (await moving.locator("#line:not([disabled])").count() !== 1) {
		fail("a refused capability cost this browser the session it was already using");
	}

	await administering.click("#settingsBtn");
	await administering.click("#holdingsTab");
	await administering.click("#sessionAccessOpen");
	const spareGrant = administering.locator(".session-access-modal");
	await spareGrant.getByLabel("Who or what is this for?").fill("Spare display");
	// Administering, so the moved browser still draws the holdings that name
	// the capability it is now using, and the move can be read rather than
	// inferred from the absence of a complaint.
	await spareGrant.getByRole("radio", { name: /Can administer/ }).check();
	await spareGrant.getByRole("button", { name: "Create access link" }).click();
	const spare = spareGrant.locator(".session-grant").filter({ hasText: "Spare display" });
	await spare.waitFor();
	const spareSturdyref = (await spare.locator(".copy-field-text").textContent())?.trim() ?? "";
	await spareGrant.getByRole("button", { name: "Close" }).click();
	await administering.click("#settingsClose");
	if (spareSturdyref === heldSturdyref || !spareSturdyref.startsWith("ocapn://")) {
		fail(`the second access link was not a distinct capability: ${JSON.stringify(spareSturdyref)}`);
	}
	await attachThroughSettings(moving, spareSturdyref, "an attached browser moving to a second access link");
	await moving.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() =>
			fail("an attached browser could not move to a second access link for the session it was already in")
		);
	await moving.click("#settingsBtn");
	await moving.click("#holdingsTab");
	await proveAttachedSessionHolding(moving, spareSturdyref);
	await moving.click("#settingsClose");
}
