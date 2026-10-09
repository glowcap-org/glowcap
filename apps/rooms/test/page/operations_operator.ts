// The Rooms operator pane and its room-authority lifecycle.

import type { Page } from "playwright";
import { removeCapability, takeCapability } from "./capability_set.ts";
import { fail } from "./harness.ts";
import { namedRoomRow } from "../support/conversation_row.ts";

export async function runOperatorScene(tab: Page, operatorSwiss: string): Promise<void> {
	// Make one room whose moderator capability is definitely unissued, then take the
	// Rooms operator. Its pane must expose the complete lifecycle as
	// capabilities: give creates a copyable moderator sturdyref; revoke asks for
	// explicit confirmation and leaves the row present but unissued.
	await tab.click("#settingsClose");
	// The home directory address selects the authority this operator owns,
	// independently of the foreign directory the Operations rail last showed.
	await tab.goto(new URL("/directory", tab.url()).href);
	await tab.waitForSelector('#roomAbout[aria-label="About this directory"]');
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "operator-proof");
	await tab.press("#newRoomInput", "Enter");
	await namedRoomRow(tab, "operator-proof", true).waitFor({ timeout: 10_000 });
	await tab.click("#settingsBtn");
	await tab.click("#holdingsTab");
	await takeCapability(tab, "#opsOperatorToggle", operatorSwiss);
	await tab.waitForSelector("#opsBtn");
	await tab.click("#opsBtn");
	await tab.waitForFunction(() => location.pathname === "/ops/directory");
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
	if (await reset.getByText("This operator connection remains so the action can answer.").count() !== 1) {
		fail("operator reset does not state why its own connection remains");
	}
	if (await reset.getByRole("button", { name: "Disconnect other peer sessions…" }).count() !== 1) {
		fail("operator reset implies it can disconnect its own answering connection");
	}
	const operated = tab.locator("#roomModerationCapabilities .entry", { hasText: "operator-proof" });
	await operated.waitFor({ timeout: 10_000 });
	await operated.getByRole("button", { name: "Grant moderator capability" }).click();
	await operated.locator(".copy-field").waitFor({ timeout: 10_000 });
	const moderatorLink = await operated.locator(".copy-field-text").textContent();
	if (moderatorLink === null || !moderatorLink.startsWith("ocapn://")) {
		fail(`the operator did not expose a copyable moderator sturdyref: "${moderatorLink}"`);
	}
	await operated.getByRole("button", { name: "Rotate…" }).click();
	if (await operated.getByText("Every old copy stops moderating this room immediately").count() !== 1) {
		fail("the revoke affordance did not say that live old holders lose authority");
	}
	await operated.getByRole("button", { name: "Revoke old moderator capability" }).click();
	await operated.getByRole("button", { name: "Grant moderator capability" }).waitFor({ timeout: 10_000 });
	if (await operated.locator(".copy-field").count() !== 0) {
		fail("a revoked moderator capability still exposed its old copyable capability");
	}
	await operated.getByRole("button", { name: "Grant moderator capability" }).click();
	await operated.locator(".copy-field").waitFor({ timeout: 10_000 });
	const rotatedModeratorLink = await operated.locator(".copy-field-text").textContent();
	if (rotatedModeratorLink === null || rotatedModeratorLink === moderatorLink) {
		fail("moderator reissue did not mint a fresh generation");
	}
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
	await linked.getByRole("button", { name: "Remove…" }).click();
	await linked.getByRole("button", { name: "Remove room entry link" }).click();
	await linked.waitFor({ state: "detached", timeout: 10_000 });
	await operated.getByRole("button", { name: "Grant moderator capability" }).waitFor({ timeout: 10_000 });
	await operated.getByRole("button", { name: "Grant moderator capability" }).click();
	await operated.locator(".copy-field").waitFor({ timeout: 10_000 });
	const reissuedAfterRoomRevoke = await operated.locator(".copy-field-text").textContent();
	if (reissuedAfterRoomRevoke === null || reissuedAfterRoomRevoke === rotatedModeratorLink) {
		fail("revoking a room link prevented a fresh room and moderator generation");
	}
	const reissuedLink = tab.locator("#operatorRoomLinks .entry", { hasText: "operator-proof" });
	await reissuedLink.waitFor({ timeout: 10_000 });
	await reissuedLink.getByRole("button", { name: "Remove…" }).click();
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

	// Operator actions are deliberately worded, so the narrow content cell must
	// give them a line of their own instead of letting a long label widen the page.
	await tab.setViewportSize({ width: 390, height: 844 });
	const mobileLayout = await tab.evaluate(() => {
		const panel = document.getElementById("directoryOpsPanel");
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
