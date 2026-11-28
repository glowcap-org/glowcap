// Two independent peers read the addressed line. Both attached operator windows
// share the preference, including on the first message after switching rooms.
import type { Browser, Page } from "playwright";
import { joinAs } from "../support/join.ts";
import { namedRoomRow } from "../support/conversation_row.ts";
import { say } from "./harness.ts";

const room = "mirror-one";
const address = (page: Page) => page.locator(".room-audience > button");
const picker = (page: Page) => page.getByRole("dialog", { name: "Address messages in #" + room });
async function recipients(page: Page, ...names: string[]) {
	await address(page).click();
	const dialog = picker(page);
	const clear = dialog.getByRole("button", { name: "Clear selection" });
	if (await clear.isEnabled()) await clear.click();
	for (const name of names) await dialog.getByRole("checkbox", { name, exact: true }).check();
	await dialog.getByRole("button", { name: "Save", exact: true }).click();
	await dialog.waitFor({ state: "hidden" });
}
async function received(page: Page, message: string, names: readonly string[]) {
	const bubble = page.locator(".bubble").filter({ hasText: message }).last();
	await bubble.waitFor();
	const mentions = await bubble.locator(".mention").allTextContents();
	if (JSON.stringify(mentions) !== JSON.stringify(names.map((name) => "@" + name))) {
		throw new Error("The message's recipients differed at the peer.");
	}
}
export async function proveRoomAudience(browser: Browser, port: number, sender: Page, mirror: Page) {
	const first = await joinAs(browser, port, "researcher", { room });
	try {
		const second = await joinAs(browser, port, "reviewer", { room });
		try {
			await first.locator("#members .member-face").filter({ has: first.locator('.name[title="researcher"]') })
				.click();
			await first.getByRole("button", { name: "Introduce yourself" }).click();
			await first.getByLabel("Member type").selectOption("bot");
			await first.getByLabel("Introduction", { exact: true }).fill("Checks citations");
			await first.getByRole("button", { name: "Save profile" }).click();
			await first.locator(".member-introduction").getByText("Checks citations", { exact: true }).waitFor();
			await first.keyboard.press("Escape");
			const wide = sender.viewportSize();
			await sender.setViewportSize({ width: 390, height: 720 });
			const opener = address(sender);
			await opener.focus();
			await opener.press("Enter");
			const dialog = picker(sender);
			await dialog.getByRole("checkbox", { name: "reviewer", exact: true }).waitFor();
			const specialist = dialog.getByRole("checkbox", { name: "researcher", exact: true });
			const search = dialog.getByRole("searchbox", { name: "Find a member" });
			await search.fill("citations");
			await specialist.waitFor();
			if (
				!(await specialist.getAttribute("aria-describedby")) || await dialog.getByRole("checkbox").count() !== 1
			) {
				throw new Error("The room introduction did not identify the intended recipient.");
			}
			await search.fill("Bot");
			await specialist.waitFor();
			await search.fill("reviewer");
			await dialog.getByRole("checkbox", { name: "reviewer", exact: true }).waitFor();
			await search.fill("");
			const selectAll = dialog.getByRole("button", { name: "Select everyone online" });
			await selectAll.focus();
			await sender.keyboard.press("Space");
			for (const name of ["researcher", "reviewer"]) {
				if (!await dialog.getByRole("checkbox", { name, exact: true }).isChecked()) {
					throw new Error("Select everyone missed " + name);
				}
			}
			const save = dialog.getByRole("button", { name: "Save", exact: true });
			const fits = await save.evaluate((button) => {
				const { left, right } = button.getBoundingClientRect();
				return left >= 0 && right <= globalThis.innerWidth;
			});
			if (!fits) throw new Error("The audience save button overflowed the phone viewport.");
			await save.focus();
			await sender.keyboard.press("Enter");
			await dialog.waitFor({ state: "hidden" });
			await sender.waitForFunction(() => document.activeElement?.matches(".room-audience > button"));
			if (wide) await sender.setViewportSize(wide);
			await address(mirror).filter({ hasText: "@reviewer" }).waitFor();
			await say(mirror, "What needs review?");
			for (const peer of [first, second]) await received(peer, "What needs review?", ["researcher", "reviewer"]);
			await address(mirror).click();
			await picker(mirror).waitFor();
			await recipients(sender, "reviewer");
			await picker(mirror).getByText("Another window changed these recipients.", { exact: false }).waitFor();
			if (await picker(mirror).getByRole("button", { name: "Save", exact: true }).isEnabled()) {
				throw new Error("An older audience editor could overwrite the newer selection.");
			}
			await mirror.keyboard.press("Escape");
			await picker(mirror).waitFor({ state: "hidden" });
			await say(sender, "Please walk me through it.");
			await received(second, "Please walk me through it.", ["reviewer"]);
			await say(sender, "@researcher Check the original.");
			await received(first, "Check the original.", ["researcher"]);
			await namedRoomRow(sender, "mirror-two").click();
			await address(sender).filter({ hasText: "Room" }).waitFor();
			await namedRoomRow(sender, room).click();
			await address(sender).filter({ hasText: "@reviewer" }).waitFor();
			await say(second, "/leave");
			await sender.locator('#members .name[title="reviewer"]').waitFor({ state: "detached" });
			await say(sender, "Please check again.");
			await sender.waitForFunction(() =>
				document.querySelector<HTMLTextAreaElement>("#line")?.value === "Please check again."
			);
			await sender.getByText("reviewer is offline.", { exact: false }).last().waitFor();
			await address(sender).click();
			const offline = dialog.getByRole("checkbox", { name: "reviewer Offline" });
			if (!await offline.isChecked()) throw new Error("The saved offline recipient disappeared.");
			await selectAll.click();
			if (!await offline.isChecked() || !await dialog.getByRole("checkbox", { name: "researcher" }).isChecked()) {
				throw new Error("Adding everyone online displaced an offline selection.");
			}
			await sender.keyboard.press("Escape");
			await dialog.waitFor({ state: "hidden" });
			await recipients(sender);
			await say(sender, "Open question for this room.");
			await received(first, "Open question for this room.", []);
		} finally {
			await second.context().close();
		}
	} finally {
		await first.context().close();
	}
}
