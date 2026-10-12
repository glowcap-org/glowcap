// Leaving through each product control must permit a fresh join in the same tab.
import type { Page } from "playwright";
import { confirmTitleLeave, fail, fillSettled, say, waitForPostedLine } from "./harness.ts";

export async function proveRoomDepartures(tab: Page, room: string): Promise<void> {
	const row = () => tab.locator("#roomList li").filter({ has: tab.locator(".rname", { hasText: room }) });
	for (const leave of ["title", "sidebar", "command"] as const) {
		if (leave === "title") await confirmTitleLeave(tab);
		else if (leave === "sidebar") await row().locator(".room-leave").click();
		else await say(tab, "/leave");
		await row().waitFor({ state: "detached", timeout: 10_000 });
		await tab.locator("#joinBtn:enabled").waitFor({ timeout: 10_000 });
		await tab.locator("dialog[open][aria-labelledby=convcardTitle]").waitFor({ state: "detached" });
		if (await tab.locator(".row-failure, .session-effect-notice").count()) {
			fail(`${leave} leave retained an error: ${await tab.locator("body").innerText()}`);
		}
		await fillSettled(tab, "#room", room);
		await tab.click("#joinBtn");
		await tab.waitForFunction(
			(room) =>
				document.getElementById("roomName")?.textContent?.trim() === room &&
				(document.getElementById("line") as HTMLTextAreaElement | null)?.disabled === false,
			room,
			{ timeout: 15_000 },
		).catch(async () => fail(`${leave} leave prevented rejoin: ${await tab.locator("body").innerText()}`));
		const text = `Confirmed rejoin after ${leave} leave`;
		await say(tab, text);
		await waitForPostedLine(tab, text);
	}
}
