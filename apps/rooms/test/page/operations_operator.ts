// The Rooms operator pane and its room-authority lifecycle.

import type { Page } from "playwright";
import { removeCapability, takeCapability } from "./capability_set.ts";
import { fail } from "../support/fail.ts";
import { fillSettled } from "./harness.ts";
import { namedRoomRow } from "../support/conversation_row.ts";
import { titleAboutDirectory } from "../../lib/text/conversation.ts";
import { homeDirectoryName } from "../../lib/text/directory.ts";
import {
	operatorForgetRoom,
	operatorForgetRoomAsk,
	operatorIssueManager,
	operatorIssueModerator,
	operatorLinkRemove,
	operatorManagerPart,
	operatorManagerRevoke,
	operatorModeratorPart,
	operatorModeratorRevoke,
	operatorModeratorRevokeEffect,
	operatorRemoveAsk,
	operatorResetLead,
	operatorResetSessions,
	operatorRevokeAsk,
	operatorRoomLinksOpen,
} from "../../lib/text/operator.ts";
import { modalClose } from "../../lib/text/controls.ts";

export async function runOperatorScene(tab: Page, operatorSwiss: string): Promise<void> {
	// Make one room whose moderator capability is definitely unissued, then take the
	// Rooms operator. Its pane must expose the complete lifecycle as
	// capabilities: give creates a copyable moderator sturdyref; revoke asks for
	// explicit confirmation and leaves the row present but unissued.
	await tab.click("#settingsClose");
	// The home directory address selects the authority this operator owns,
	// independently of the foreign directory the Operations rail last showed.
	await tab.goto(new URL("/directory", tab.url()).href);
	await tab.waitForSelector(`#roomAbout[aria-label="${titleAboutDirectory(homeDirectoryName)}"]`);
	await tab.click("#newRoomBtn");
	await fillSettled(tab, "#newRoomInput", "operator-proof");
	await tab.press("#newRoomInput", "Enter");
	await namedRoomRow(tab, "operator-proof", true).waitFor({ timeout: 10_000 });
	await tab.click("#settingsBtn");
	await tab.click("#holdingsTab");
	await takeCapability(tab, "#opsOperatorToggle", operatorSwiss);
	await tab.waitForSelector("#opsBtn");
	await tab.click("#opsBtn");
	await tab.waitForFunction(() => location.pathname === "/ops/operator");
	const moderationSection = tab.locator("#operatorRoomModeration");
	const sectionShape = await moderationSection.evaluate((section) => {
		const title = section.querySelector(":scope > #roomModerationTitle");
		const well = section.querySelector(":scope > #roomModerationCapabilities");
		return {
			titleOutsideWell: title !== null && well !== null && !well.contains(title),
			wellBorder: well === null ? "0px" : getComputedStyle(well).borderTopWidth,
		};
	});
	if (!sectionShape.titleOutsideWell || sectionShape.wellBorder === "0px") {
		fail(`room moderation is not one titled, bounded section: ${JSON.stringify(sectionShape)}`);
	}
	for (
		const section of [
			"#operatorRoomLinks",
			"#operatorNames",
			"#operatorSessions",
			"#operatorRooms",
			"#operatorTrouble",
			"#operatorReset",
		]
	) {
		if (await tab.locator(section).count() !== 1) fail(`the Rooms operator is missing ${section}`);
	}
	const reset = tab.locator("#operatorReset");
	if (
		await reset.getByText(operatorResetLead).count() !== 1
	) {
		fail("operator reset does not state why its own connection remains");
	}
	if (await reset.getByRole("button", { name: `${operatorResetSessions.label}…` }).count() !== 1) {
		fail("operator reset implies it can disconnect its own answering connection");
	}
	// With a directory named, the section and the links card are photographed
	// in each of their states for a design read: the list, the maker's manager
	// link beside an unissued moderator link, both issued, a revoke asked, and
	// the phone layout.
	const shots = Deno.env.get("GLOWCAP_OPERATOR_SCREENSHOTS");
	const shot = async (name: string, subject = moderationSection) => {
		if (shots == null) return;
		await subject.screenshot({ path: `${shots}/${name}.png` });
	};
	const room = tab.locator("#roomModerationCapabilities .entry", { hasText: "operator-proof" });
	await room.waitFor({ timeout: 10_000 });
	// The room's maker holds its manager link, so the row says so before any
	// link is issued here.
	if (await room.locator(".tag", { hasText: operatorManagerPart }).count() !== 1) {
		fail("the row does not say the maker's manager link stands");
	}
	if (await room.locator(".tag", { hasText: operatorModeratorPart }).count() !== 0) {
		fail("the row says a moderator link stands before one is issued");
	}
	await shot("authority-list");
	await room.getByRole("button", { name: operatorRoomLinksOpen }).click();
	const card = tab.locator(".operator-room-links");
	const operated = card.locator('[data-part="moderator"]');
	await operated.waitFor({ timeout: 10_000 });
	await shot("authority-card-maker-holds-manager", card);
	await operated.getByRole("button", { name: operatorIssueModerator }).click();
	await operated.locator(".copy-field").waitFor({ timeout: 10_000 });
	const moderatorLink = await operated.locator(".copy-field-text").textContent();
	if (moderatorLink === null || !moderatorLink.startsWith("ocapn://")) {
		fail(`the operator did not expose a copyable moderator sturdyref: "${moderatorLink}"`);
	}
	await shot("authority-card-both-issued", card);
	await tab.setViewportSize({ width: 390, height: 844 });
	await shot("authority-card-phone", card);
	// Two full links and their acts fit a phone's width without a sideways
	// scroll anywhere in the card. A compact copy field clips its value with
	// an ellipsis on purpose, so a node that hides its overflow is not a
	// sideways scroll; one that shows or scrolls it is.
	const overflowing = await card.evaluate((root) =>
		[root, ...root.querySelectorAll("*")]
			.filter((node) =>
				node.scrollWidth > node.clientWidth + 1 &&
				!["hidden", "clip"].includes(getComputedStyle(node).overflowX)
			)
			.map((node) =>
				`${node.tagName.toLowerCase()}${node.id === "" ? "" : `#${node.id}`}.${
					[...node.classList].join(".")
				} ${node.scrollWidth}>${node.clientWidth}`
			)
	);
	if (overflowing.length !== 0) {
		fail(`${overflowing.length} parts of the links card overflow a phone's width: ${overflowing.join(", ")}`);
	}
	await tab.setViewportSize({ width: 1280, height: 800 });
	await operated.getByRole("button", { name: operatorRevokeAsk }).click();
	if (await operated.getByText(operatorModeratorRevokeEffect).count() !== 1) {
		fail("the revoke affordance did not say that live old holders lose authority");
	}
	await shot("authority-card-revoke-asked", card);
	await operated.getByRole("button", { name: operatorModeratorRevoke }).click();
	await operated.getByRole("button", { name: operatorIssueModerator }).waitFor({ timeout: 10_000 });
	if (await operated.locator(".copy-field").count() !== 0) {
		fail("a revoked moderator capability still exposed its old copyable capability");
	}
	await operated.getByRole("button", { name: operatorIssueModerator }).click();
	await operated.locator(".copy-field").waitFor({ timeout: 10_000 });
	const rotatedModeratorLink = await operated.locator(".copy-field-text").textContent();
	if (rotatedModeratorLink === null || rotatedModeratorLink === moderatorLink) {
		fail("moderator reissue did not mint a fresh generation");
	}
	// The row shows that link without the card: the card changes the list.
	await room.locator(".tag", { hasText: operatorModeratorPart }).waitFor({ timeout: 10_000 });
	// The card shows the maker's manager link first. Revoking it stops the
	// maker's copy, and issuing mints a new one.
	const manager = card.locator('[data-part="manager"]');
	await manager.locator(".copy-field").waitFor({ timeout: 10_000 });
	const makersLink = await manager.locator(".copy-field-text").textContent();
	if (makersLink === null || !makersLink.startsWith("ocapn://")) {
		fail(`the operator did not expose the maker's manager link: "${makersLink}"`);
	}
	await manager.getByRole("button", { name: operatorRevokeAsk }).click();
	await manager.getByRole("button", { name: operatorManagerRevoke }).click();
	await manager.getByRole("button", { name: operatorIssueManager }).waitFor({ timeout: 10_000 });
	if (await manager.locator(".copy-field").count() !== 0) {
		fail("a revoked manager link still exposed its old copyable link");
	}
	await manager.getByRole("button", { name: operatorIssueManager }).click();
	await manager.locator(".copy-field").waitFor({ timeout: 10_000 });
	const managerLink = await manager.locator(".copy-field-text").textContent();
	if (managerLink === null || managerLink === makersLink) {
		fail("manager reissue did not mint a fresh link");
	}
	await shot("authority-card-reissued", card);
	await card.getByRole("button", { name: modalClose }).click();
	await card.waitFor({ state: "hidden", timeout: 10_000 });
	await shot("authority-list-both");
	// The search is over the directory, not over the page: it narrows every
	// inventory at once and its counts are the directory's own. Then the bulk
	// act on exactly what it found, which is the whole reason to search from an
	// operator seat.
	await tab.fill("#operatorSearch", "operator-proof");
	await tab.waitForFunction(
		() =>
			document.getElementById("operatorSearchSaid")?.textContent?.includes("operator-proof") === true &&
			[...document.querySelectorAll("#operatorRooms .entry")].length === 1,
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("the operator search did not narrow the rooms inventory to its match"));
	const searched = await tab.evaluate(() => ({
		rooms: document.querySelector("#operatorRooms .ops-section-count")?.textContent ?? "",
		names: document.querySelector("#operatorNames .ops-section-count")?.textContent ?? "",
	}));
	if (searched.rooms !== "1") fail(`a search counted ${JSON.stringify(searched.rooms)} rooms rather than one`);
	// An inventory with nothing in it says so in its well; a chip reading zero
	// beside every empty section is the same word twice down the page.
	if (searched.names !== "") {
		fail(`an inventory matching nothing still drew the count ${JSON.stringify(searched.names)}`);
	}
	await tab.fill("#operatorSearch", "no-such-row-anywhere");
	await tab.waitForFunction(
		() =>
			document.querySelector("#operatorRooms .ops-section-count") === null &&
			document.querySelector("#operatorRooms .empty") !== null,
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("a search matching nothing still counted rows"));
	if (await tab.locator("#operatorSweepAsk-rooms").count() !== 0) {
		fail("a search matching nothing still offered to retire every match");
	}
	await tab.click("#operatorSearchClear");
	await tab.waitForFunction(
		() => (document.getElementById("operatorSearch") as HTMLInputElement | null)?.value === "",
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("clearing the operator search did not empty it"));

	const linked = tab.locator("#operatorRoomLinks .entry", { hasText: "operator-proof" });
	await linked.getByRole("button", { name: operatorRemoveAsk }).click();
	await linked.getByRole("button", { name: operatorLinkRemove }).click();
	await linked.waitFor({ state: "detached", timeout: 10_000 });
	// Removing the room's entry link rotates the room, so the moderator link
	// issued for the ended generation is gone from the card too.
	await room.getByRole("button", { name: operatorRoomLinksOpen }).click();
	await operated.getByRole("button", { name: operatorIssueModerator }).waitFor({ timeout: 10_000 });
	await operated.getByRole("button", { name: operatorIssueModerator }).click();
	await operated.locator(".copy-field").waitFor({ timeout: 10_000 });
	const reissuedAfterRoomRevoke = await operated.locator(".copy-field-text").textContent();
	if (reissuedAfterRoomRevoke === null || reissuedAfterRoomRevoke === rotatedModeratorLink) {
		fail("revoking a room link prevented a fresh room and moderator generation");
	}
	await card.getByRole("button", { name: modalClose }).click();
	await card.waitFor({ state: "hidden", timeout: 10_000 });
	const reissuedLink = tab.locator("#operatorRoomLinks .entry", { hasText: "operator-proof" });
	await reissuedLink.waitFor({ timeout: 10_000 });
	await reissuedLink.getByRole("button", { name: operatorRemoveAsk }).click();
	await reissuedLink.getByRole("button", { name: "Remove room entry link" }).click();
	await reissuedLink.waitFor({ state: "detached", timeout: 10_000 });
	// Retire the room through the search rather than through its own row: the
	// bulk act names how many match and takes exactly those.
	await tab.fill("#operatorSearch", "operator-proof");
	await tab.waitForSelector("#operatorSweepAsk-rooms", { timeout: 10_000 })
		.catch(() => fail("a search with matches did not offer to retire them"));
	if ((await tab.textContent("#operatorSweepAsk-rooms"))?.includes("all 1 matching") !== true) {
		fail("the bulk retire did not name how many rows it would take");
	}
	await tab.click("#operatorSweepAsk-rooms");
	await tab.click("#operatorSweepGo-rooms");
	await tab.waitForFunction(
		() =>
			document.querySelector("#operatorRooms .ops-section-count") === null &&
			document.querySelector("#operatorRooms .empty") !== null,
		undefined,
		{ timeout: 20_000 },
	).catch(() => fail("the bulk retire left its matching room owner standing"));
	await tab.click("#operatorSearchClear");
	// The room's maker still holds its manager link, so the room keeps its
	// row with nobody in it. Forgetting the room from its card is the one act
	// that takes the row away, and the card closes with it.
	await room.locator(".tag", { hasText: operatorManagerPart }).waitFor({ timeout: 10_000 });
	await room.getByRole("button", { name: operatorRoomLinksOpen }).click();
	const forget = card.locator('[data-part="forget"]');
	await forget.getByRole("button", { name: operatorForgetRoomAsk }).click();
	await shot("authority-card-forget-asked", card);
	await forget.getByRole("button", { name: operatorForgetRoom, exact: true }).click();
	await room.waitFor({ state: "detached", timeout: 10_000 });
	await card.waitFor({ state: "hidden", timeout: 10_000 });
	await shot("authority-list-forgotten");

	// Operator actions are worded, so the narrow content cell must
	// give them a line of their own instead of letting a long label widen the page.
	await tab.setViewportSize({ width: 390, height: 844 });
	const mobileLayout = await tab.evaluate(() => {
		const panel = document.getElementById("operatorOpsPanel");
		if (panel === null) return null;
		const bounds = panel.getBoundingClientRect();
		const actions = [...panel.querySelectorAll<HTMLButtonElement>(".entry-head .button")];
		return {
			overflows: document.documentElement.scrollWidth > innerWidth + 1,
			inside: actions.every((button) => {
				const rect = button.getBoundingClientRect();
				return rect.left >= bounds.left - 1 && rect.right <= bounds.right + 1;
			}),
			wide: [...document.querySelectorAll<HTMLElement>("body *")].flatMap((element) => {
				const rect = element.getBoundingClientRect();
				return rect.right > innerWidth + 1 || rect.left < -1
					? [{
						tag: element.tagName.toLowerCase(),
						id: element.id,
						className: element.className,
						left: Math.round(rect.left),
						right: Math.round(rect.right),
						scrollWidth: element.scrollWidth,
					}]
					: [];
			}).slice(0, 12),
		};
	});
	if (mobileLayout === null || mobileLayout.overflows || !mobileLayout.inside) {
		fail(`the operator actions do not fit the phone content cell: ${JSON.stringify(mobileLayout)}`);
	}
	await tab.setViewportSize({ width: 1280, height: 800 });
	await tab.click("#settingsBtn");
	await tab.click("#holdingsTab");
	await removeCapability(tab, "#opsOperatorToggle");
}
