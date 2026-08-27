// A directory's lifecycle at its edges: nothing open on it, leaving it, and
// reaching it again. Holding a directory is a live session, a name registered
// on it, and everything reachable through that name, so the rail has to show a
// row for a directory with no rooms, letting one go has to end all of it, and
// the same directory has to be reachable again from its own row.
//
// Those three are what this file proves. The fourth thing that can happen to a
// directory — going away without being left — is `gone.ts`, which this hands
// the page to when it is done with it.
//
// The tail of the two-directories conversation in `directories.ts`; it runs
// with that page's state and returns the restarted foreign server, if the
// scenario minted one.

import type { Locator, Page } from "playwright";
import { namedRoomRow } from "../support/conversation_row.ts";
import { fail } from "./harness.ts";
import { run as goneRun } from "./gone.ts";

export async function run(
	tab: Page,
	foreignLocator: string,
	foreignRoom: Deno.ChildProcess,
	foreignRoomPort: number,
	homeRoomPort: number,
	aboutOf: (room: string) => Locator,
): Promise<void> {
	// A directory with nothing open on it is still a directory this tab is on: a
	// live session, and a name registered on it that nobody else can take. Leaving
	// the last room on one used to leave exactly that, with no row anywhere saying
	// so — a connection nobody could see and therefore nobody could end. So it
	// keeps a row of its own, the same shape a room gets, because it is the same
	// kind of thing: somewhere you are.
	const before = namedRoomRow(tab, "elsewhere");
	await before.hover();
	await before.locator(".room-leave").click();
	await tab.waitForFunction(
		() => {
			const named = [...document.querySelectorAll("#roomList .rname")].map((el) => el.textContent?.trim());
			return !named.includes("elsewhere");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("leaving the last room on a directory did not take the room out of the rail"));
	const stranded = await tab.evaluate((port) => {
		const row = [...document.querySelectorAll("#roomList li.dirrow")]
			.find((candidate) => (candidate.querySelector(".rname")?.textContent ?? "").includes(port));
		if (row === undefined) return null;
		// This row's line says why the directory is here rather than which
		// directory it is, because the name above it has already said that, so it
		// is the one line in the rail that carries no little glyph. Its words are
		// still centered on the line the way that line's words are, which with
		// nothing beside them means centered in the row: a lone span left to flow
		// would sit against one edge of its own rectangle, and a rectangle with
		// its words jammed into a corner reads as a mistake rather than as the
		// quiet line it is.
		const said = row.querySelector(".rwhere-said");
		const line = row.querySelector(".rwhere");
		return {
			named: row.querySelector(".rname")?.textContent?.trim() ?? "",
			said: line?.textContent?.trim() ?? "",
			canLeave: row.querySelector(".room-leave") !== null,
			underTheName: said === null || line === null ? Number.NaN : (() => {
				const w = said.getBoundingClientRect(), c = line.getBoundingClientRect();
				return Math.abs((w.left - c.left) - (c.right - w.right));
			})(),
		};
	}, String(foreignRoomPort));
	if (stranded === null) {
		fail("a directory with nothing open on it left no row, so its session could not be seen or ended");
	} else if (!stranded.canLeave || stranded.named === "") {
		fail(`the row for a directory with nothing on it is unusable: ${JSON.stringify(stranded)}`);
	} else if (!(stranded.underTheName <= 1)) {
		fail(
			`the line under a stranded directory's name is not centered on its own rectangle: ` +
				`out by ${stranded.underTheName.toFixed(1)}px`,
		);
	}
	// And it is the same directory, reachable again from its own row.
	await tab.click("#roomList li.dirrow .room-open");
	await tab.waitForSelector("#joinForm", { timeout: 10_000 })
		.catch(() => fail("a directory with nothing on it did not offer a way to join a room on it"));
	// Filled with the directory's own identity rather than with what was once
	// typed, so the check is that it names that peer, not that it matches a
	// spelling of it.
	const aimed = await tab.inputValue("#locator");
	if (!aimed.includes(String(foreignRoomPort))) {
		fail(`joining from a directory's own row aimed at ${JSON.stringify(aimed)} rather than that directory`);
	}
	await tab.fill("#room", "elsewhere");
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("a room could not be joined from the row of a directory with nothing on it"));

	// Leaving a directory, which is the other end of reaching one. Holding a
	// directory is a live session, a name registered on it, and everything
	// reachable through that name, so letting it go has to be all of that. A row
	// removed from a list while the session went on running is the failure worth
	// checking for, and it does not look like a failure at the moment it happens:
	// it looks like it worked, and then the directory comes back on its own.
	await (aboutOf("elsewhere")).click();
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 });
	await tab.click("#dircardLeaveAsk");
	// Asked before it is done, and asked with the cost in it: a reader who is
	// about to lose a room should be told how many.
	const asked = (await tab.textContent("#dircardLeaveSaid"))?.trim() ?? "";
	if (!asked.includes("1 room")) {
		fail(`leaving did not say what it would close; it said ${JSON.stringify(asked)}`);
	}
	await tab.click("#dircardLeave");
	await tab.waitForFunction(() => {
		const said = document.getElementById("dircardLeaveSaid");
		const layer = said?.closest("dialog") as HTMLDialogElement | null;
		return layer !== null && layer.isConnected && !layer.open && layer.inert &&
			!layer.matches(":modal") && said?.textContent?.includes("1 room") === true;
	}).catch(() => fail("the directory card did not remain inert with its complete facts through the exit transition"));
	await tab.waitForSelector("#dircardTitle", { state: "detached", timeout: 10_000 })
		.catch(() => fail("leaving a directory left its card open"));
	await tab.waitForFunction(
		() => {
			const named = [...document.querySelectorAll("#roomList .rname")].map((el) => el.textContent?.trim());
			return !named.includes("elsewhere") && named.includes("lobby");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("leaving a directory did not take its rooms with it, or took the other directory's too"));
	// And it stays left. A session that was dropped from the list without being
	// released still has a reconnect timer, and that timer opens the directory
	// again a second or two later — the tell is a row that comes back by itself.
	await tab.waitForTimeout(4000);
	const cameBack = await tab.evaluate(() =>
		[...document.querySelectorAll("#roomList .rname")].some((el) => el.textContent?.trim() === "elsewhere")
	);
	if (cameBack) fail("a directory that was left dialled itself back and returned to the rail");
	// With one directory left there is nothing to tell apart, so the rail stops
	// naming directories on its rows at all.
	const stillNaming = await tab.locator("#roomList .rwhere, #dmList .rwhere").count();
	if (stillNaming !== 0) {
		fail(`the rail went on naming directories with only one left; ${stillNaming} rows still say which`);
	}

	// The name goes back, which is the part of leaving that nothing on screen can
	// show and the part most likely to be got wrong. A directory grants a name for
	// the length of a connection; if leaving drops the row but leaves the session
	// running, the directory is still holding that name and hands out a suffixed
	// one to whoever asks next — including us, walking back in. So this walks back
	// in, and the name it is given is the whole answer.
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "elsewhere");
	await tab.focus("#newRoomElsewhere");
	await tab.press("#newRoomElsewhere", "Enter");
	await tab.waitForSelector("#joinForm", { timeout: 10_000 });
	// Pressing "change directory" is the reader saying they are about to name
	// another one, so it leaves them in the field that names it. With a room
	// open this press is also what puts the card there, and the caret has to
	// wait for that; the same hand-over from the menu's last row, where the
	// card is already up, is proved in `opening.ts`.
	if (await tab.evaluate(() => document.activeElement?.id ?? "") !== "locator") {
		fail("changing directory from the rail left the reader in front of the card with the caret nowhere");
	}
	await tab.fill("#locator", foreignLocator);
	await tab.fill("#nick", "bo");
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("a directory that had been left could not be reached again"));
	await (aboutOf("elsewhere")).click();
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 });
	const grantedAgain = await tab.evaluate(() => {
		const rows = [...document.querySelectorAll(".modal .dirfacts dt")];
		const which = rows.find((dt) => dt.textContent?.trim() === "Your name here");
		return which?.nextElementSibling?.textContent?.trim() ?? "";
	});
	if (grantedAgain !== "bo") {
		fail(
			`walking back into a directory that was left was granted ${JSON.stringify(grantedAgain)} rather ` +
				"than the name it gave up, so leaving did not hand the name back",
		);
	}
	await tab.keyboard.press("Escape");

	// This page's own directory is the same as any other: leaving it gives the
	// session and the granted name back, and the join card still knows the
	// locator, so walking back in under a new name does not need a reload.
	await (aboutOf("lobby")).click();
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 })
		.catch(() => fail("the caption on this page's own directory did not open its card"));
	await tab.click("#dircardLeaveAsk");
	await tab.click("#dircardLeave");
	await tab.waitForSelector("#dircardTitle", { state: "detached", timeout: 10_000 })
		.catch(() => fail("leaving this page's own directory left its card open"));
	await tab.waitForFunction(
		() => {
			const named = [...document.querySelectorAll("#roomList .rname")].map((el) => el.textContent?.trim());
			return !named.includes("lobby") && named.includes("elsewhere");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("leaving this page's own directory did not take its rooms, or took the other directory's too"));
	await tab.waitForTimeout(4000);
	const homeCameBack = await tab.evaluate(() =>
		[...document.querySelectorAll("#roomList .rname")].some((el) => el.textContent?.trim() === "lobby")
	);
	if (homeCameBack) fail("this page's own directory dialled itself back after it was left");
	// The other directory is still held, so the join card is not already up.
	// The rail's elsewhere line is how a reader names a directory they are not
	// on; picking "this directory" there is walking back into the one they left.
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "lobby");
	await tab.focus("#newRoomElsewhere");
	await tab.press("#newRoomElsewhere", "Enter");
	await tab.waitForSelector("#joinForm", { timeout: 10_000 })
		.catch(() => fail("leaving this page's own directory did not offer a way back through the join card"));
	await tab.click("#joinLocator");
	await tab.waitForSelector(".locator-picks [role=menuitemradio]", { timeout: 5_000 })
		.catch(() => fail("the join card did not offer this page's own directory after it was left"));
	await tab.getByRole("menuitemradio", { name: "this directory", exact: true }).click();
	await tab.fill("#nick", "cam");
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("this page's own directory could not be reached again after it was left"));
	await (aboutOf("lobby")).click();
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 });
	const homeAgain = await tab.evaluate(() => {
		const rows = [...document.querySelectorAll(".modal .dirfacts dt")];
		const which = rows.find((dt) => dt.textContent?.trim() === "Your name here");
		return which?.nextElementSibling?.textContent?.trim() ?? "";
	});
	if (homeAgain !== "cam") {
		fail(
			`walking back into this page's own directory was granted ${JSON.stringify(homeAgain)} rather ` +
				"than the name it gave up, so leaving did not hand the name back",
		);
	}
	await tab.keyboard.press("Escape");

	// Back on the foreign room so the rail field names that directory: empty
	// locator means this page's own, and this check is that the other one fills.
	await namedRoomRow(tab, "elsewhere").locator(".room-open").click();
	await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 })
		.catch(() => fail("could not return to the room on the directory that was not left"));

	// The join card offers the addresses already in hand. A locator is forty
	// characters nobody retypes, and every one of these was pasted once already,
	// so the field can be filled from what the tab is holding instead. Leaving it
	// empty means this page's own directory, so that one clears rather than fills
	// — the two directions are different actions and both are checked.
	// Named in the rail's own field, which is aimed at the directory of the room
	// being read, so the card it opens is aimed there without anybody picking a
	// directory: standing in a room has one reading of where the next one goes,
	// and stepping out to an address this tab does not hold carries that answer
	// with it.
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "wherever");
	await tab.focus("#newRoomElsewhere");
	await tab.press("#newRoomElsewhere", "Enter");
	await tab.waitForSelector("#joinForm", { timeout: 10_000 });
	const kept = await tab.inputValue("#locator");
	if (!kept.includes(String(foreignRoomPort))) {
		fail(
			`the join card did not keep the directory the rail's field was naming; it holds ${JSON.stringify(kept)}`,
		);
	}
	await tab.click("#joinLocator");
	await tab.waitForSelector(".locator-picks [role=menuitemradio]", { timeout: 5_000 })
		.catch(() => fail("the join card's directory mark did not open the held addresses"));
	const offered = await tab.evaluate(() =>
		[...document.querySelectorAll(".locator-picks [role=menuitemradio]")].map((b) => b.textContent?.trim() ?? "")
	);
	if (!offered.includes("this directory")) {
		fail(`the join card did not offer this page's own directory; it offered ${JSON.stringify(offered)}`);
	}
	if (offered.length < 2) {
		fail(`the join card offered nothing but this directory while the tab held another: ${JSON.stringify(offered)}`);
	}
	const other = offered.find((name) => name !== "this directory");
	if (other === undefined) {
		fail(`the join card offered no held directory beside this one: ${JSON.stringify(offered)}`);
	}
	await tab.getByRole("menuitemradio", { name: other, exact: true }).click();
	const filled = await tab.inputValue("#locator");
	if (filled === "") fail("pressing a held directory did not fill the locator field");
	// And fills it with the exact address sharing hands out — the route this
	// tab dialed, hints and all — not the bare authority the store keys by. The
	// directory card's copy field is the sharing answer, so the two are compared
	// directly rather than against any expectation about the route's shape.
	await (aboutOf("elsewhere")).click();
	await tab.waitForSelector("#dircardLocator", { timeout: 10_000 })
		.catch(() => fail("the held directory's card did not open to compare its shared address"));
	const shared = ((await tab.textContent("#dircardLocator")) ?? "").trim();
	if (shared === "" || shared !== filled) {
		fail(`the picker filled ${JSON.stringify(filled)} while sharing hands out ${JSON.stringify(shared)}`);
	}
	await tab.keyboard.press("Escape");
	await tab.click("#joinLocator");
	await tab.waitForSelector(".locator-picks [role=menuitemradio]", { timeout: 5_000 })
		.catch(() => fail("the join card's directory mark did not open again to clear the field"));
	await tab.getByRole("menuitemradio", { name: "this directory", exact: true }).click();
	const cleared = await tab.inputValue("#locator");
	if (cleared !== "") {
		fail(`pressing "this directory" left ${JSON.stringify(cleared)} in the field instead of clearing it`);
	}

	await goneRun(tab, foreignRoom, foreignRoomPort, homeRoomPort, aboutOf);
}
