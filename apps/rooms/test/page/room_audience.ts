// A mention is public text. Remembering it is private to this session and room.
import type { Browser, Page } from "playwright";
import { joinAs } from "../support/join.ts";
import { namedRoomRow } from "../support/conversation_row.ts";
import { openLineMenu, say, waitForPostedLine } from "./harness.ts";

const room = "mirror-one";
const kept = (page: Page) => page.locator("#savedMentions");

async function received(page: Page, message: string, names: readonly string[]) {
	const bubble = page.locator(".bubble").filter({ hasText: message }).last();
	await bubble.waitFor();
	const mentions = await bubble.locator(".mention").allTextContents();
	if (JSON.stringify(mentions) !== JSON.stringify(names.map((name) => "@" + name))) {
		throw new Error("The mentions on the received message differed from those the sender chose.");
	}
}
export async function proveRoomAudience(browser: Browser, port: number, sender: Page, mirror: Page) {
	const first = await joinAs(browser, port, "researcher", { room });
	try {
		const second = await joinAs(browser, port, "reviewer", { room });
		try {
			if (await kept(sender).count()) throw new Error("An untouched room showed a saved mention.");
			await first.locator("#members .member-face").filter({ has: first.locator('.name[title="researcher"]') })
				.click();
			await first.getByRole("button", { name: "Introduce yourself" }).click();
			await first.getByLabel("Member type").selectOption("bot");
			await first.getByLabel("Introduction", { exact: true }).fill("Checks citations");
			await first.getByRole("button", { name: "Save profile" }).click();
			await first.locator(".member-introduction").getByText("Checks citations", { exact: true }).waitFor();
			await first.keyboard.press("Escape");
			await say(first, "The citation is ready.");
			const wide = sender.viewportSize();
			await sender.setViewportSize({ width: 390, height: 720 });
			const reply = sender.locator(".row.them .bubble").filter({ hasText: "The citation is ready." });
			await reply.hover();
			await reply.getByRole("button", { name: /^More/ }).click();
			await sender.getByRole("menuitem", { name: "About researcher" }).click();
			await sender.locator(".member-introduction").getByText("Checks citations", { exact: true }).waitFor();
			await sender.keyboard.press("Escape");

			await say(sender, "@researcher @reviewer Check the sources.");
			for (const peer of [first, second]) await received(peer, "Check the sources.", ["researcher", "reviewer"]);
			if (await kept(sender).count()) throw new Error("A one-time mention became a preference.");
			await waitForPostedLine(sender, "Check the sources.");
			const message = sender.locator(".row.mine .bubble").filter({ hasText: "Check the sources." });
			await openLineMenu(message);
			const keep = sender.getByRole("menuitem", { name: "Keep mentioning these members" });
			await keep.focus();
			await keep.press("Enter");
			await kept(sender).getByText("@researcher, @reviewer").waitFor();
			await sender.waitForFunction(() => document.activeElement?.matches(".line-acts > button"));
			await kept(mirror).getByText("@researcher, @reviewer").waitFor();
			await say(mirror, "What needs review?");
			for (const peer of [first, second]) await received(peer, "What needs review?", ["researcher", "reviewer"]);
			await say(sender, "@researcher Check the original.");
			await received(first, "Check the original.", ["researcher"]);
			await say(sender, "/mentions @reviewer");
			await kept(mirror).getByText("@reviewer", { exact: true }).waitFor();
			await say(sender, "/mentions");
			await sender.getByText("Automatic mentions: @reviewer", { exact: true }).last().waitFor();
			if (await first.getByText("Automatic mentions: @reviewer", { exact: true }).count()) {
				throw new Error("A private command reply reached a different member.");
			}
			if (wide) await sender.setViewportSize(wide);
			await namedRoomRow(sender, "mirror-two").click();
			await kept(sender).waitFor({ state: "detached" });
			await namedRoomRow(sender, room).click();
			await kept(sender).getByText("@reviewer", { exact: true }).waitFor();
			await say(second, "/leave");
			await sender.locator('#members .name[title="reviewer"]').waitFor({ state: "detached" });
			await say(sender, "Please check again.");
			await sender.getByText("reviewer is offline.", { exact: false }).last().waitFor();
			await kept(sender).getByRole("button", { name: "Stop automatic mentions" }).click();
			await kept(mirror).waitFor({ state: "detached" });
			await sender.waitForFunction(() => document.activeElement?.id === "line");
			if (await sender.locator("#line").inputValue() !== "Please check again.") {
				throw new Error("Clearing saved mentions discarded the draft.");
			}
			await sender.locator("#line").press("Enter");
			await received(first, "Please check again.", []);
		} finally {
			await second.context().close();
		}
	} finally {
		await first.context().close();
	}
}
