// The directory conversation's composer is a command line: slash commands run,
// their results stay in this view, and ordinary chat has nowhere to go.

import type { Page } from "playwright";
import { fail } from "./harness.ts";

export async function proveDirectoryCommands(tab: Page): Promise<void> {
	await tab.waitForSelector("#line:not([disabled])", { timeout: 10_000 })
		.catch(() => fail("the directory conversation did not enable its command line"));
	const placeholder = await tab.getAttribute("#line", "placeholder");
	if (placeholder == null || !placeholder.toLowerCase().includes("command")) {
		fail(`the directory composer still reads as a chat: ${JSON.stringify(placeholder)}`);
	}
	await tab.fill("#line", "/help");
	await tab.press("#line", "Enter");
	await tab.waitForFunction(
		() => {
			const said = [...document.querySelectorAll(".sys-line")].map((line) => line.textContent ?? "").join("\n");
			return said.includes("You can use:") && said.includes("/join:") && !said.includes("/me:");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("/help on a directory did not list the commands this view holds"));
	await tab.fill("#line", "/list");
	await tab.press("#line", "Enter");
	await tab.waitForFunction(
		() => {
			const said = [...document.querySelectorAll(".sys-line")].map((line) => line.textContent ?? "").join("\n");
			return /#lobby:/.test(said);
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("/list on a directory did not say what this directory advertises"));
	await tab.fill("#line", "hello");
	await tab.press("#line", "Enter");
	await tab.waitForFunction(
		() => {
			const said = [...document.querySelectorAll(".sys-line")].map((line) => line.textContent ?? "").join("\n");
			return said.includes("does not carry messages");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("plain text on a directory vanished instead of refusing"));
	const leftover = await tab.inputValue("#line");
	if (leftover !== "hello") {
		fail(`a refused line was cleared as if it had sent: ${JSON.stringify(leftover)}`);
	}
	await tab.fill("#line", "");
}
