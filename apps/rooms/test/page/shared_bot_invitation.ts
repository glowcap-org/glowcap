// The operator accepts the room under the same session access that registered
// the nickname. A separate collaborator runs the bot after that browser closes.
import type { Browser, Page } from "playwright";
import { joinAs } from "../support/join.ts";
import { makeRoom } from "../support/private_room_page.ts";
import { readAnnounced } from "../support/announce.ts";
import { spawnOwned, stopOwned } from "../support/children.ts";
import { BOT, ROOT } from "../support/paths.ts";
import { say } from "./harness.ts";

export async function provePrivateBotInvitation(
	browser: Browser,
	operator: Page,
	httpPort: number,
	state: string,
	botLink: string,
) {
	const inviter = await joinAs(browser, httpPort, "inviter");
	try {
		await makeRoom(inviter, "member-review", true);
		await say(inviter, "/invite scout");
		await operator.locator(".inviterow .room-open").click({ timeout: 30_000 });
		await inviter.locator('#members li:has-text("scout")').waitFor({ timeout: 30_000 });
		await operator.context().close();

		const link = state + "/bot-link";
		await Deno.writeTextFile(link, botLink, { mode: 0o600 });
		// Only the model is scripted. The installed bot still has to attach,
		// receive the mention and deliver the final answer with its own grant.
		const answer = "Private handoff confirmed.";
		const result = JSON.stringify({ type: "result", subtype: "success", is_error: false, result: answer });
		await Deno.writeTextFile(state + "/claude", `#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '${result}'\n`, {
			mode: 0o700,
		});
		// This turn posts only its final answer. Any attempted shell action fails.
		const action = state + "/glowcap";
		await Deno.writeTextFile(action, "#!/bin/sh\nexit 1\n", { mode: 0o700 });
		const request = {
			verb: "serve",
			state: state + "/bot",
			named: { link: [link], harness: ["claude"], glowcap: [action] },
			arguments: [],
		};
		const bot = spawnOwned(BOT, {
			args: ["control", JSON.stringify(request)],
			cwd: ROOT,
			env: { PATH: state + ":" + Deno.env.get("PATH"), HOME: state },
			stdout: "piped",
			stderr: "piped",
		});
		try {
			await readAnnounced(bot, { token: "ROOMS-BOT-SERVING", who: "private room bot" });
			await say(inviter, "@scout please confirm");
			await inviter.locator(".bubble").filter({ hasText: answer }).first().waitFor({ timeout: 20_000 });
		} finally {
			await stopOwned(bot);
		}
	} finally {
		await inviter.context().close();
	}
}
