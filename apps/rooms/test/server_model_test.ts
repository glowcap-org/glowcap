// What the page says a Rooms server is for: how this browser is reached. A
// directory needs it only when its address has no browser route, so no line
// says directories need one flatly.

import { assertEquals } from "./assert.ts";
import { serverAskLead, sessionServerLead, sessionServerNone } from "../lib/text/session.ts";
import { serverChangeLead, serverNone, serverRemoveSaid, settingsBrowserNoServer } from "../lib/text/settings.ts";

const flat = /\bdirector(y|ies)\b[^.]*\bneeds?\b|reaches (shared sessions and )?directories/i;

Deno.test("every line that explains the Rooms server ties it to how this browser is reached", () => {
	const lines = [
		sessionServerNone,
		sessionServerLead,
		serverAskLead,
		serverChangeLead,
		serverNone,
		serverRemoveSaid(false),
		settingsBrowserNoServer,
	];
	for (const line of lines) {
		assertEquals(flat.test(line.replace(/whose address has no browser route/, "")), false, line);
	}
	for (const line of [sessionServerNone, serverNone]) {
		assertEquals(line.includes("Links you issue, direct messages, and an archive peer need one"), true, line);
	}
	assertEquals(serverNone.includes("a directory whose address has no browser route"), true);
});
