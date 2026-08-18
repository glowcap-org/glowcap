// A directory's lifecycle at its edges: nothing open on it, leaving it, and
// reaching it again. Holding a directory is a live session, a name registered
// on it, and everything reachable through that name, so the rail has to show
// a row for a directory with no rooms, letting one go has to end all of it,
// and the same directory has to be reachable again from its own row.
//
// The tail of the two-directories conversation in `directories.ts`; it runs
// with that page's state and returns the restarted foreign server, if the
// scenario minted one.

import type { Locator, Page } from "playwright";
import { fail, ROOT } from "./harness.ts";

export async function run(
	tab: Page,
	foreignLocator: string,
	foreignRoom: Deno.ChildProcess,
	foreignRoomPort: number,
	captionOf: (room: string) => Locator,
): Promise<Deno.ChildProcess | null> {
	let foreignAgain: Deno.ChildProcess | null = null;
	// A directory with nothing open on it is still a directory this tab is on: a
	// live session, and a name registered on it that nobody else can take. Leaving
	// the last room on one used to leave exactly that, with no row anywhere saying
	// so — a connection nobody could see and therefore nobody could end. It also
	// kept every other row wearing a directory caption, to tell rooms apart from
	// rooms on a directory that was not on screen at all.
	const before = tab.locator("#roomList li").filter({ has: tab.locator('.rname:text-is("elsewhere")') });
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
	const stranded = await tab.evaluate(() => {
		const row = [...document.querySelectorAll("#roomList li.dirrow")][0];
		if (row === undefined) return null;
		// This row's caption says why the directory is here rather than where it
		// is, so it is the one caption in the rail that carries no little glyph.
		// Its words are still centred on the line the way a caption's are, which
		// with nothing beside them means centred in the row: a lone span left to
		// flow would sit against one edge of its own rectangle, and a rectangle
		// with its words jammed into a corner reads as a mistake rather than as
		// the quiet line it is.
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
	});
	if (stranded === null) {
		fail("a directory with nothing open on it left no row, so its session could not be seen or ended");
	} else if (!stranded.canLeave || stranded.named === "") {
		fail(`the row for a directory with nothing on it is unusable: ${JSON.stringify(stranded)}`);
	} else if (!(stranded.underTheName <= 1)) {
		fail(
			`the line under a stranded directory's name is not centred on its own rectangle: ` +
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
	await (captionOf("elsewhere")).click();
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
	// naming directories at all.
	const stillNaming = await tab.locator("#roomList .rwhere").count();
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
	await tab.fill("#locator", foreignLocator);
	await tab.fill("#nick", "bo");
	await tab.click("#joinBtn");
	await tab.waitForSelector("#line:not([disabled])", { timeout: 60_000 })
		.catch(() => fail("a directory that had been left could not be reached again"));
	await (captionOf("elsewhere")).click();
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
	await (captionOf("lobby")).click();
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
	await (captionOf("lobby")).click();
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
	await tab.click('#roomList li:has(.rname:text-is("elsewhere")) .room-open');
	await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 })
		.catch(() => fail("could not return to the room on the directory that was not left"));

	// The join card offers the addresses already in hand. A locator is forty
	// characters nobody retypes, and every one of these was pasted once already,
	// so the field can be filled from what the tab is holding instead. Leaving it
	// empty means this page's own directory, so that one clears rather than fills
	// — the two directions are different actions and both are checked.
	await tab.click("#newRoomBtn");
	await tab.fill("#newRoomInput", "wherever");
	await tab.focus("#newRoomElsewhere");
	await tab.press("#newRoomElsewhere", "Enter");
	await tab.waitForSelector("#joinForm", { timeout: 10_000 });
	const kept = await tab.inputValue("#locator");
	if (!kept.includes(String(foreignRoomPort))) {
		fail(
			`the join card did not keep the directory the new-room line was naming; it holds ${JSON.stringify(kept)}`,
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
	await tab.click(`#roomList li:has(.rwhere:has-text("127.0.0.1")) .rwhere`);
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

	// A directory going away, while another is still up. "Reconnecting…" is the
	// whole message when there is one directory it could be about and a riddle
	// when there are two: the rooms on the other one are still live, and a reader
	// watching one of those go quiet cannot tell whether this is about them. Last
	// in the run, because it ends the second server for good.
	const nameOfForeign = await tab.evaluate(() => {
		const row = [...document.querySelectorAll("#roomList li")]
			.find((li) => (li.querySelector(".rwhere")?.textContent ?? "").includes("127.0.0.1"));
		return (row?.querySelector(".rwhere")?.textContent ?? "").replace(/^in\s+/, "").trim();
	});
	if (nameOfForeign === "") fail("no room in the rail said it was on the second server");
	// Said into that room as the server goes, so there is a line in flight when
	// the session dies. This is how an ordinary reader meets a failed send: not
	// by typing into a dead page, which the composer already refuses, but by
	// having said something a moment before the ground moved.
	await tab.click(`#roomList li:has(.rwhere:has-text("127.0.0.1")) .room-open`);
	await tab.waitForSelector("#line:not([disabled])", { timeout: 30_000 })
		.catch(() => fail("the room on the second server would not take a line before that server went"));
	// And a file posted into it while it was up. A file reference is only good on
	// the connection it arrived over, so this one is about to become unfetchable
	// while its row stays on screen offering to fetch it.
	await tab.setInputFiles("#filePick", {
		name: "before.txt",
		mimeType: "text/plain",
		buffer: Buffer.from("posted while the second server was up"),
	});
	await tab.waitForSelector('.composer-file:has-text("before.txt")', { timeout: 10_000 })
		.catch(() => fail("the file for the second server was not attached to the composer"));
	await tab.click("#sendBtn");
	await tab.waitForSelector('.row.mine .attach-file:has-text("before.txt") .icon-button', { timeout: 60_000 })
		.catch(() => fail("a file posted to the room on the second server never landed"));
	// Uploaded, not merely announced. The row is drawn from the optimistic bubble
	// the moment Send is pressed, so waiting for it proves nothing; the bubble
	// stops saying it is sending when the last byte is on the room. Killing the
	// server before that is a different scenario, an upload cut off mid-flight.
	// This one is about a file the room has.
	await tab.waitForFunction(
		() => {
			const bubble = [...document.querySelectorAll(".bubble")]
				.find((candidate) => (candidate.textContent ?? "").includes("before.txt"));
			return bubble !== undefined && !(bubble.textContent ?? "").includes("Sending");
		},
		undefined,
		{ timeout: 60_000 },
	).catch(() => fail("a file posted to the room on the second server never finished uploading"));

	// And a line said while it was up, which the room answers with the reference
	// that governs it. That reference came over this connection, so what happens
	// to the pencil and the close beside it when the connection goes is the point
	// of the pair of checks below.
	const keptLine = "said while the second server was up";
	await tab.fill("#line", keptLine);
	await tab.press("#line", "Enter");
	// The room's echo first, because that is this scenario's barrier: everything
	// below turns on the server going away at a known moment, and a wait that can
	// be satisfied by the bubble this tab painted for itself is no barrier at all.
	await tab.waitForFunction(
		(text) => {
			const bubble = [...document.querySelectorAll(".row.mine .bubble")]
				.find((candidate) => (candidate.textContent ?? "").includes(text));
			return bubble !== undefined && !bubble.classList.contains("sending");
		},
		keptLine,
		{ timeout: 30_000 },
	).catch(() => fail("the room on the second server never confirmed a line said into it"));
	await tab.waitForFunction(
		(text) => {
			const bubble = [...document.querySelectorAll(".row.mine .bubble")]
				.find((candidate) => (candidate.textContent ?? "").includes(text));
			return bubble !== undefined && bubble.querySelector(".line-acts") !== null;
		},
		keptLine,
		{ timeout: 30_000 },
	).catch(() => fail("a line posted to the room on the second server was never offered a way to change it"));

	// Stopped before the line is said, killed after it is drawn. A stopped server
	// answers nothing while its connection stays up, so the line below is
	// accepted, painted, and genuinely waiting on an answer — which is what this
	// whole passage is about. Killing across the press instead is a race with two
	// losing sides: the composer refuses the moment the session goes, and a server
	// that answers first leaves nothing in flight. Both have happened.
	const inFlight = "said as the second server went away";
	try {
		foreignRoom.kill("SIGSTOP");
	} catch {
		// already gone
	}
	await tab.fill("#line", inFlight);
	await tab.press("#line", "Enter");
	await tab.waitForFunction(
		(text) => [...document.querySelectorAll(".bubble")].some((b) => (b.textContent ?? "").includes(text)),
		inFlight,
		{ timeout: 30_000 },
	).catch(() => fail("a line said to a server that had stopped answering was never even drawn"));
	try {
		foreignRoom.kill("SIGKILL");
	} catch {
		// already gone
	}
	// Back to the room on this page's own directory. Pressing the room you are
	// already in is how a reader puts the rail away, so leaving the tab in this
	// one would turn the next press on its row — the one below, which expects to
	// open it — into a press that closes the rail instead.
	await tab.click('.room-open:has-text("lobby")');
	await tab.waitForFunction(
		() => (document.querySelector(".banner")?.textContent ?? "").includes("Reconnecting"),
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("a directory going away while another was up said nothing at all"));
	const announced = (await tab.textContent(".banner"))?.trim() ?? "";
	if (!announced.includes(nameOfForeign)) {
		fail(
			`the reconnect notice does not say which directory it is about: ${JSON.stringify(announced)} ` +
				`while holding one named ${JSON.stringify(nameOfForeign)}`,
		);
	}

	// And the field a reader would type into says so itself. Opening a room on
	// the directory that went away leaves the composer unusable, and a control
	// that refuses without saying why is a dead box under an invitation to type
	// in it. The banner and the rail's foot both carry the news, but the banner
	// goes away and the foot is at the far corner of a wide screen and a
	// different screen entirely on a phone — and with two directories held it is
	// answering about the page while this field is refusing for one of them.
	// A room on the directory that went away is still a room this tab is in, and
	// opening it has to show it. Gating that on a live session put a reader in
	// front of a form asking them to join a room they were already in, with the
	// history they came for behind it — so this asserts the conversation opens
	// before it asks what the field says.
	await tab.click(`#roomList li:has(.rwhere:has-text("127.0.0.1")) .room-open`);
	await tab.waitForFunction(
		() => (document.getElementById("roomName")?.textContent ?? "") !== "No room yet",
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("opening a room on a directory that had gone away showed no conversation, only the join card"));
	const refusing = await tab.evaluate(() => {
		const line = document.getElementById("line") as HTMLTextAreaElement | null;
		return line === null ? null : {
			disabled: line.disabled,
			said: line.placeholder,
			// What the rail and the header actually hold, so a wrong answer names
			// the state it was taken in rather than leaving it to be guessed at.
			open: document.getElementById("roomName")?.textContent ?? "(none)",
			rows: [...document.querySelectorAll("#roomList li")].map((li) =>
				(li.querySelector(".rname")?.textContent ?? "?") + "/" +
				(li.querySelector(".rwhere")?.textContent ?? "-")
			).join(", "),
		};
	});
	if (refusing === null) fail("the conversation on a directory that went away drew no composer at all");
	else if (!refusing.disabled) {
		fail("the composer stayed usable on a directory that had gone away");
	} else if (refusing.said === "" || /^Message\b/.test(refusing.said)) {
		fail(
			`a composer that cannot be used still invites typing: it says ${JSON.stringify(refusing.said)} ` +
				`rather than what the directory is doing, with ${JSON.stringify(refusing.open)} open and the ` +
				`rail holding ${JSON.stringify(refusing.rows)}`,
		);
	}

	// And the card that exists to answer "what is wrong with this one" says what.
	// The banner goes away, the foot speaks for whichever directory is on screen,
	// and this card is where a reader goes when one of two is misbehaving — so
	// the phase word on its own is the single thing they already knew.
	await tab.click(`#roomList li:has(.rwhere:has-text("127.0.0.1")) .rwhere`);
	await tab.waitForSelector("#dircardTitle", { timeout: 10_000 })
		.catch(() => fail("the line under a room on a directory that went away no longer opens its card"));
	await tab.waitForFunction(
		() => {
			const dt = [...document.querySelectorAll(".modal .dirfacts dt")]
				.find((row) => row.textContent?.trim() === "Connection");
			const said = dt?.nextElementSibling?.textContent?.trim() ?? "";
			return /reach|retry/i.test(said);
		},
		undefined,
		{ timeout: 60_000 },
	).catch(async () => {
		const said = await tab.evaluate(() => {
			const dt = [...document.querySelectorAll(".modal .dirfacts dt")]
				.find((row) => row.textContent?.trim() === "Connection");
			return dt?.nextElementSibling?.textContent?.trim() ?? "(no connection row)";
		});
		fail(`the card for a directory that went away says only ${JSON.stringify(said)}`);
	});
	await tab.keyboard.press("Escape");

	{
		// The line that was in flight when the server went. It is not sent, it says
		// so, and — unlike one typed into a conversation that closed for good — it
		// carries the way to send it again, because a session is a thing that comes
		// back.
		const unsent = await tab.waitForSelector(".delivery-failure", { timeout: 60_000 })
			.catch(async () => {
				// What the log holds instead. A line that was confirmed before the
				// server went and a line that vanished are different failures, and
				// this used to report neither.
				const shown = await tab.evaluate(() => ({
					mine: [...document.querySelectorAll(".row.mine .bubble")].map((bubble) =>
						(bubble.textContent ?? "").slice(0, 60)
					),
					banner: document.querySelector(".banner")?.textContent?.trim() ?? "",
				}));
				fail(
					`a line in flight when its server went was never marked unsent: ${inFlight}; ` +
						`the log holds ${JSON.stringify(shown)}`,
				);
			});
		// Named by the line it is about. A conversation can hold more than one
		// unsent message, and they do not all carry the same answer: this one is
		// a line a session took with it, and the file beside it is a transfer
		// nothing can resume.
		const carried = await tab.evaluate((text) => {
			const row = [...document.querySelectorAll(".row.mine")]
				.find((candidate) => (candidate.textContent ?? "").includes(text));
			const failure = row?.querySelector(".delivery-failure");
			return failure == null ? null : {
				said: failure.textContent?.trim() ?? "",
				retries: failure.querySelectorAll("button").length,
			};
		}, inFlight);
		if (carried === null || carried.retries !== 1) {
			fail(`a line that could be sent again offers ${JSON.stringify(carried)} rather than one retry`);
		}
		void unsent;

		// Pressed while the server is still away. The control is live — it is in
		// the bubble, not in the composer the directory disables — so a reader can
		// and will press it, and it cannot work yet. What it must not do is
		// nothing: a press that changes nothing reads as a broken button rather
		// than as a room that is not back.
		await tab.click(".delivery-failure button");
		await tab.waitForFunction(
			() => (document.getElementById("log")?.textContent ?? "").includes("Not in this room at the moment"),
			undefined,
			{ timeout: 30_000 },
		).catch(async () => {
			const log = await tab.evaluate(() => (document.getElementById("log")?.textContent ?? "").slice(-200));
			fail(`retrying before the room was back said nothing: ${JSON.stringify(log)}`);
		});
		if (await tab.locator(".delivery-failure").count() !== 1) {
			fail("a retry that could not go left the message looking sent");
		}

		// The file that was posted before the server went. The room may well still
		// hold its bytes; what ended was the connection they were offered over, and
		// no later press can get them back. So the press says that, once, and the
		// row then stops offering. A control that cannot succeed invites a reader
		// to keep pressing for as long as they are willing to believe it might.
		const fileRow = '.row.mine .attach-file:has-text("before.txt")';
		if (await tab.locator(`${fileRow} .icon-button`).count() !== 1) {
			fail("the file posted before the server went lost its control before it was ever pressed");
		}
		await tab.click(`${fileRow} .icon-button`);
		const saidOfFile = () =>
			tab.evaluate(() => {
				const row = [...document.querySelectorAll(".attach-file")]
					.find((candidate) => (candidate.textContent ?? "").includes("before.txt"));
				return row === undefined ? "(no row)" : row.querySelector(".sub")?.textContent ?? "(no reason)";
			});
		await tab.waitForFunction(
			() => {
				const row = [...document.querySelectorAll(".attach-file")]
					.find((candidate) => (candidate.textContent ?? "").includes("before.txt"));
				return (row?.querySelector(".sub")?.textContent ?? "").includes("earlier connection");
			},
			undefined,
			{ timeout: 15_000 },
		).catch(async () => {
			fail(`asking for a file whose connection had ended said ${JSON.stringify(await saidOfFile())}`);
		});
		if (await tab.locator(`${fileRow} .icon-button`).count() !== 0) {
			fail("a file that can never be fetched again still offers a control that fetches it");
		}

		// And the line that was posted while the server was up. Changing or
		// withdrawing one is holding the reference the room answered with, and a
		// reference cannot outlive the connection it came over. What was said is
		// still there; what could be done to it is not, so the controls go rather
		// than staying to refuse.
		const kept = tab.locator(`.row.mine .bubble:has-text("${keptLine}")`).last();
		if (await kept.count() === 0) fail("the line said before the server went was lost with it");
		await kept.hover();
		await kept.getByLabel(/More for this message/).click();
		const stillOffered = await tab.locator(".line-menu [role=menuitem]").allTextContents();
		await tab.keyboard.press("Escape");
		if (stillOffered.some((item) => /Edit|Delete/.test(item))) {
			fail(
				`a line whose governing reference died with its connection still offers to change it: ${
					JSON.stringify(stillOffered)
				}`,
			);
		}
		// Its words are still there to take, which is the half that does not depend
		// on a connection at all.
		if (!stillOffered.some((item) => item.includes("Copy"))) {
			fail(`a line nobody can change is also refusing to be copied: ${JSON.stringify(stillOffered)}`);
		}

		// Stand the server back up and press it. Pressing is the point: a control
		// that draws and cannot be reached is the failure this page has had before,
		// and only a press tells the two apart.
		foreignAgain = new Deno.Command("deno", {
			args: [
				"run",
				"--allow-ffi",
				"--allow-read",
				"--allow-net",
				"--allow-env",
				`${ROOT}apps/rooms/server/main.ts`,
				String(foreignRoomPort),
			],
			cwd: ROOT,
			stdout: "null",
			stderr: "inherit",
		}).spawn();
		// The page dials on its own with a backoff, and re-enters the rooms it
		// holds. Waited for by the room's own welcome rather than by the composer
		// coming back: the composer answers for the directory, which reconnects
		// first, and a retry pressed in that gap has no membership to post
		// through. What this is here to prove is that a reader who waits and then
		// presses gets their line sent, so it presses when the room is back.
		await tab.waitForFunction(
			() => ((document.getElementById("log")?.textContent ?? "").match(/welcome bo\b/g) ?? []).length >= 2,
			undefined,
			{ timeout: 90_000 },
		).catch(() => fail("the page never re-entered the room on the second server after it came back"));
		await tab.click(".delivery-failure button");
		await tab.waitForFunction(
			(text) => {
				const failed = document.querySelector(".delivery-failure");
				const drawn = [...document.querySelectorAll(".bubble")].some((b) =>
					(b.textContent ?? "").includes(text)
				);
				return failed === null && drawn;
			},
			inFlight,
			{ timeout: 60_000 },
		).catch(async () => {
			const state = await tab.evaluate(() => ({
				failure: document.querySelector(".delivery-failure")?.textContent?.trim() ?? "(none)",
				log: (document.getElementById("log")?.textContent ?? "").slice(-160),
			}));
			fail(`pressing retry did not send the line: ${JSON.stringify(state)}`);
		});
	}

	return foreignAgain;
}
