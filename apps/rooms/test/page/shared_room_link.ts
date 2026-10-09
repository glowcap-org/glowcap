/// <reference lib="dom" />

// A room sturdyref pasted into an attached view remains room authority. The
// durable workspace, not that browser, owns the directory session and the room
// membership; every attached view receives the resulting conversation.

import type { Page } from "playwright";
import { Directory, Room } from "../../lib/room/client.ts";
import { fail } from "./harness.ts";
import { namedRoomRow } from "../support/conversation_row.ts";

const ROOM = "mirror-linked";

export async function proveSharedRoomLink(directory: Directory, views: readonly Page[]): Promise<void> {
	const managed = await directory.openManaged(ROOM);
	const witness = await Room.subscribe(directory.session, managed.room, "witness");
	try {
		const joining = views.at(-1);
		if (joining == null) throw new Error("the shared room-link proof needs an attached view");
		await joining.click("#newRoomBtn");
		await joining.fill("#newRoomInput", ROOM);
		await joining.focus("#newRoomElsewhere");
		await joining.press("#newRoomElsewhere", "Enter");
		await joining.waitForSelector("#joinForm", { state: "visible" });
		await joining.fill("#room", ROOM);
		await joining.fill("#locator", managed.roomLink);
		await joining.fill("#nick", "durable-member");
		await joining.click("#joinBtn");
		for (const view of views) {
			await namedRoomRow(view, ROOM).waitFor({ timeout: 30_000 })
				.catch(async () => {
					const states = await Promise.all(views.map((page) => page.evaluate(() => document.body.innerText)));
					fail(
						`a room link pasted in an attached view did not reach the shared workspace: ${
							JSON.stringify(states)
						}`,
					);
				});
		}
	} finally {
		await witness.leave();
	}
}
