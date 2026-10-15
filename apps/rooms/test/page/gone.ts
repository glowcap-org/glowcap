// A directory that goes away while another is still up, and then comes back.
//
// One directory being unreachable says nothing about the others, so everything
// here is about saying which one it is about. The rooms held on the directory
// that went say so on their own rows and the rooms on the other one stay quiet,
// the composer under a room that cannot be reached says what is wrong rather
// than refusing in silence, and the card about that directory answers what a
// row's caption line has no room for.
//
// Then this page's own room server is taken down and stood back up while the
// second one is still away, because a directory coming back must not clear the
// one notice the page has for all of them and erase an outage that is still
// true.
//
// A line in flight preserves its uncertain delivery receipt after connection
// loss. Reconnection cannot authorize a new post from the old message text.
// Files already recorded in the archive retain their bytes. Live line-edit
// authority retires with its connection. Both are checked after restart.
//
// The last phase of the two-directories conversation, run by `leaving.ts` with
// that page's state. It ends the second server for good, and returns the one it
// stands back up.

import type { Locator, Page } from "playwright";
import { waitForFiniteAnimations } from "../support/animations.ts";
import { fail, openDirectoryCardFromCaption, ROOT, SERVER, waitForPostedLine } from "./harness.ts";
import { proveRecoveryDialogLayout } from "./recovery_layout.ts";
import { inkContrast } from "../ink_contrast.ts";
import { spawnOwned } from "../support/children.ts";
import { namedRoomRow } from "../support/conversation_row.ts";

/** Longer than the page's own reconnect ceiling, which is five seconds. A
 * standing read once, straight after a session dies, cannot tell one filed
 * against the directory that died from one filed against the directory the
 * reader happens to be standing in: at that moment they are the same directory,
 * and they come apart only as the retries run. */
const PAST_THE_RECONNECT_CEILING_MS = 8_000;

/** What every row in the rooms rail is saying about its directory: which one
 * the room is on, and how that directory is doing.
 *
 * Read as a whole rail rather than a row at a time, because every claim below
 * is about which rows say it and which stay quiet. `home` is the mark the page's
 * own directory wears. Every other directory wears a slot in the ramp. */
function railStandings(tab: Page) {
	return tab.evaluate(() =>
		[...document.querySelectorAll("#roomList li")].map((row) => ({
			room: row.querySelector(".rname")?.textContent?.trim() ?? "",
			mark: row.getAttribute("data-dir") ?? "",
			where: row.querySelector(".rwhere-said")?.textContent?.trim() ?? "",
			how: row.querySelector(".rwhere-how")?.textContent?.trim() ?? "",
		}))
	);
}

export async function run(
	tab: Page,
	foreignRoom: Deno.ChildProcess,
	foreignState: string,
	foreignRoomPort: number,
	homeRoomPort: number,
	aboutOf: (room: string) => Locator,
): Promise<void> {
	// "Reconnecting…" is the whole message when there is one directory it could be
	// about and a riddle when there are two: the rooms on the other one are still
	// live, and a reader watching one of those go quiet cannot tell whether this is
	// about them. So the news is said on the rows it is about, beside the name of
	// the directory those rooms are on, and that name is read off the rail first
	// while that directory is still there to name.
	const nameOfForeign = await tab.evaluate(() => {
		const row = [...document.querySelectorAll("#roomList li")]
			.find((li) => (li.querySelector(".rwhere-said")?.textContent ?? "").includes("127.0.0.1"));
		return (row?.querySelector(".rwhere-said")?.textContent ?? "").replace(/^in\s+/, "").trim();
	});
	if (nameOfForeign === "") fail("no row in the rail said it was on the second server");
	// Said into that room as the server goes, so there is a line in flight when
	// the session dies. This is how an ordinary reader meets a failed send: not
	// by typing into a dead page, which the composer already refuses, but by
	// having said something a moment before the ground moved.
	await namedRoomRow(tab, "elsewhere").locator(".room-open").click();
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
	await waitForPostedLine(tab, keptLine);
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
	// accepted, painted, and waiting on an answer. This is the state
	// the whole passage exercises. Killing across the press instead has two losing
	// sides: the composer refuses the moment the session goes, and a server
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
	// The optimistic bubble precedes durable admission. Require the receipt and
	// its retained executor before killing the server. The recovery notice hides
	// running work, so without an older failure it opens only after the bounded
	// observation stops. That receipt says unknown but remains resumable through
	// the exact execution; neither state permits another dispatch.
	await tab.click("#sessionEffectReview");
	await tab.getByRole("dialog", { name: /^Unfinished change/ }).waitFor();
	const retainedExecution =
		'dialog[open] [data-operation][data-resumable="true"]:is([data-status="pending"], [data-status="unknown"])';
	await tab.waitForSelector(retainedExecution, { timeout: 30_000 })
		.catch(() => fail("the send to the stopped server never retained an admitted execution"));
	const originalPending = await tab.locator(retainedExecution).last()
		.getAttribute("data-operation");
	if (originalPending == null) fail("the admitted send lost its receipt identity");
	const originalReceipt = tab.locator(`dialog[open] [data-operation="${originalPending}"]`);
	const observationStopped = await originalReceipt.getAttribute("data-status") === "unknown";
	try {
		foreignRoom.kill("SIGKILL");
	} catch {
		// already gone
	}
	// Resume only the retained observation when its bounded worker has stopped.
	// Its earlier execution must settle terminally without dispatching a new post.
	if (observationStopped) await originalReceipt.getByRole("button", { name: "Pick back up", exact: true }).click();
	await tab.waitForSelector(
		`dialog[open] [data-operation="${originalPending}"][data-status="unknown"][data-resumable="false"]`,
		{
			timeout: 30_000,
		},
	).catch(() => fail("the open recovery dialog never reported the original send's unknown outcome"));
	await proveRecoveryDialogLayout(tab);
	await tab.keyboard.press("Escape");
	// Exercise the exact terminal receipt before later admissions can evict it
	// from the bounded inventory. Its inline unknown delivery must outlive it.
	await openRetainedChanges(tab);
	const releasedRow = tab.locator(`dialog[open] [data-operation="${originalPending}"]`);
	await releasedRow.getByRole("button", { name: "Let go…" }).click();
	await releasedRow.getByRole("button", { name: "Let go", exact: true }).click();
	await releasedRow.waitFor({ state: "detached", timeout: 30_000 });
	await closeRetainedChanges(tab);
	// Back to the room on this page's own directory. Pressing the room you are
	// already in is how a reader puts the rail away, so leaving the tab in this
	// one would turn the next press on its row, the one below, which expects to
	// open it, into a press that closes the rail instead.
	await tab.click('.room-open:has-text("lobby")');

	// ── The news lands on the rooms it is about ──────────────────────────
	// A room whose directory is away is a room this reader cannot reach, which
	// is a fact about that row. So every row on the directory that went says so,
	// beside the name of the directory it is on, and every row on the one still
	// up says nothing.
	//
	// Read while the reader stands in a room on the healthy directory, because
	// that is the state a page-level value cannot tell apart: one value is
	// filed by whichever directory acted last, and at the moment a session dies
	// the reader is usually still in the room it died under.
	await tab.waitForFunction(
		() =>
			[...document.querySelectorAll("#roomList li")].some((row) =>
				row.getAttribute("data-dir") !== "home" &&
				(row.querySelector(".rwhere-how")?.textContent ?? "").trim() !== ""
			),
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("a directory going away while another was up said nothing at all"));
	const whileAway = await railStandings(tab);
	const untouched = whileAway.filter((row) => row.mark === "home" && row.how !== "");
	if (untouched.length > 0) {
		fail(
			`one directory going away was reported on rooms held on another: ${JSON.stringify(untouched)} ` +
				`while the rail held ${JSON.stringify(whileAway)}`,
		);
	}
	const reporting = whileAway.filter((row) => row.mark !== "home" && row.how !== "");
	if (reporting.length === 0 || !reporting.every((row) => row.where.includes(nameOfForeign))) {
		fail(
			`the rooms on the directory that went away do not name it: ${JSON.stringify(reporting)} ` +
				`while holding one named ${JSON.stringify(nameOfForeign)}`,
		);
	}
	// And there is nothing left on the page that could carry one directory's news
	// over rooms held on another.
	if (await tab.locator(".banner").count() !== 0) {
		fail("the page still holds one notice over the conversation for whichever directory acted last");
	}

	// Measured where it is on screen, which is only here. The rail's own sweep
	// runs with every directory connected, so this line is not drawn for it to
	// reach, and a selector it cannot find reads exactly like a selector that
	// passed. Both appearances, on the rail's own fill, at rest.
	{
		const wasTheme = await tab.getAttribute("html", "data-theme");
		await tab.mouse.move(0, 0);
		await tab.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
		const tooFaint: string[] = [];
		for (const appearance of ["light", "dark"] as const) {
			await tab.evaluate((t) => document.documentElement.setAttribute("data-theme", t), appearance);
			await waitForFiniteAnimations(tab);
			const measured = await inkContrast(tab, "#roomList li:not(.here) .rwhere-how");
			if (measured === null) tooFaint.push(`how a directory is doing could not be measured in ${appearance}`);
			else if (measured.ratio < 4.5) {
				tooFaint.push(`how a directory is doing is ${measured.ratio.toFixed(2)}:1 in ${appearance}`);
			}
		}
		await tab.evaluate((t) => {
			if (t === null) document.documentElement.removeAttribute("data-theme");
			else document.documentElement.setAttribute("data-theme", t);
		}, wasTheme);
		if (tooFaint.length > 0) {
			fail(`a room's line saying its directory is away does not clear 4.5 to 1: ${tooFaint.join("; ")}`);
		}
	}

	// ── One coming back leaves the other's outage standing ───────────────
	// This page's own room server is supervised, so taking it down puts the home
	// directory away and `serve.ts` stands it back up on its own while the second
	// server is still gone. That recovery is the arithmetic a single page-level
	// value got wrong: the writer that cleared the notice on a successful open
	// cleared it for every directory, so a directory coming back erased an outage
	// that was still true.
	// Pause the replacement server itself: this also holds recovery when the
	// workspace's connector is hosted outside this browser tab.
	const pattern = `${SERVER.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")} .*--port=${homeRoomPort}( |$)`;
	const serverPid = async () => {
		const found = await new Deno.Command("pgrep", { args: ["-f", pattern] }).output();
		const pids = new TextDecoder().decode(found.stdout).trim().split(/\s+/).filter(Boolean).map(Number);
		return pids.length === 1 ? pids[0] : null;
	};
	const original = await serverPid();
	if (original == null) fail("could not identify this page's own room server");
	Deno.kill(original, "SIGTERM");
	let replacement: number | null = null;
	for (let attempt = 0; attempt < 200; attempt++) {
		const pid = await serverPid();
		if (pid != null && pid !== original) {
			Deno.kill(pid, "SIGSTOP");
			replacement = pid;
			break;
		}
		await new Promise((resolve) => setTimeout(resolve, 25));
	}
	if (replacement == null) fail("the supervised home server did not restart");
	await tab.waitForFunction(
		() =>
			[...document.querySelectorAll('#roomList li[data-dir="home"]')].some((row) =>
				(row.querySelector(".rwhere-how")?.textContent ?? "").trim() !== ""
			),
		undefined,
		{ timeout: 60_000 },
	).catch(async () =>
		fail(
			`this page's own directory going away was never said on the rooms held on it: ` +
				JSON.stringify(await railStandings(tab)),
		)
	).finally(() => {
		Deno.kill(replacement!, "SIGCONT");
	});
	await tab.waitForFunction(
		() =>
			document.querySelectorAll('#roomList li[data-dir="home"]').length > 0 &&
			[...document.querySelectorAll('#roomList li[data-dir="home"]')].every((row) =>
				(row.querySelector(".rwhere-how")?.textContent ?? "").trim() === ""
			),
		undefined,
		{ timeout: 90_000 },
	).catch(async () =>
		fail(
			`this page's own directory never came back after its room server was restarted: ` +
				JSON.stringify(await railStandings(tab)),
		)
	);

	// Watched rather than read once, past the reconnect ceiling. Two right
	// readings prove only that the rail was right twice. What has to hold is that
	// the recovered directory's rooms stay quiet and the away one's go on saying
	// so, through every retry either of them makes.
	{
		let drifted: string | null = null;
		const until = Date.now() + PAST_THE_RECONNECT_CEILING_MS;
		while (Date.now() < until && drifted === null) {
			const now = await railStandings(tab);
			const away = now.filter((row) => row.mark !== "home");
			if (away.length === 0 || away.some((row) => row.how === "")) {
				drifted = `a directory coming back cleared the outage on rooms held elsewhere: ${JSON.stringify(now)}`;
			} else if (now.some((row) => row.mark === "home" && row.how !== "")) {
				drifted = `a recovered directory's rooms took on another directory's standing: ${JSON.stringify(now)}`;
			}
			await tab.waitForTimeout(250);
		}
		if (drifted !== null) fail(drifted);
	}

	// And the field a reader would type into says so itself. Opening a room on
	// the directory that went away leaves the composer unusable, and a control
	// that refuses without saying why is a dead box under an invitation to type
	// in it. The room's own row in the rail carries the news too, but the rail
	// goes away on a phone and the foot beneath it is about the reader rather
	// than about what they hold. The status beside the field owns that answer;
	// the placeholder keeps naming the room instead of repeating the refusal.
	// A room on the directory that went away is still a room this tab is in, and
	// opening it has to show it. Gating that on a live session put a reader in
	// front of a form asking them to join a room they were already in, with the
	// history they came for behind it, so this asserts the conversation opens
	// before it asks what the field says.
	await namedRoomRow(tab, "elsewhere").locator(".room-open").click();
	await tab.waitForFunction(
		() => (document.getElementById("roomName")?.textContent ?? "") !== "No room yet",
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("opening a room on a directory that had gone away showed no conversation, only the join card"));
	const refusing = await tab.evaluate(() => {
		const line = document.getElementById("line") as HTMLTextAreaElement | null;
		const availability = document.getElementById("composerAvailability");
		const typing = document.getElementById("typing");
		const availabilityStyle = availability == null ? null : getComputedStyle(availability);
		const typingStyle = typing == null ? null : getComputedStyle(typing);
		return line === null ? null : {
			disabled: line.disabled,
			said: line.placeholder,
			detail: availability?.textContent?.trim() ?? "",
			statusStyle: availabilityStyle == null || typingStyle == null ? null : {
				availability: {
					color: availabilityStyle.color,
					fontSize: availabilityStyle.fontSize,
					fontStyle: availabilityStyle.fontStyle,
					fontWeight: availabilityStyle.fontWeight,
				},
				typing: {
					color: typingStyle.color,
					fontSize: typingStyle.fontSize,
					fontStyle: typingStyle.fontStyle,
					fontWeight: typingStyle.fontWeight,
				},
			},
			// What the rail and the header actually hold, so a wrong answer names
			// the state it was taken in rather than leaving it to be guessed at.
			open: document.getElementById("roomName")?.textContent ?? "(none)",
			rows: [...document.querySelectorAll("#roomList li")].map((row) =>
				(row.querySelector(".rname")?.textContent ?? "?") + " " +
				(row.querySelector(".rwhere-said")?.textContent ?? "-")
			).join(", "),
		};
	});
	if (refusing === null) fail("the conversation on a directory that went away drew no composer at all");
	else if (!refusing.disabled) {
		fail("the composer stayed usable on a directory that had gone away");
	} else if (refusing.said !== "") {
		// A field that cannot be sent from does not invite a message, and does not
		// carry the reason either: whatever the reader had already typed covers a
		// placeholder, and the reason has to be readable then. It goes below the
		// control, once.
		fail(
			`a disabled composer still put ${JSON.stringify(refusing.said)} in the field, with ` +
				`${JSON.stringify(refusing.open)} open and the ` +
				`rail holding ${JSON.stringify(refusing.rows)}`,
		);
	} else if (refusing.detail === "") {
		fail(
			`a disabled composer said nothing about what the directory is doing, with ` +
				`${JSON.stringify(refusing.open)} open and the ` +
				`rail holding ${JSON.stringify(refusing.rows)}`,
		);
	} else if (
		refusing.statusStyle == null ||
		JSON.stringify(refusing.statusStyle.availability) !== JSON.stringify(refusing.statusStyle.typing)
	) {
		fail(`composer availability did not keep the typing line's quiet treatment: ${JSON.stringify(refusing)}`);
	}
	const priorViewport = tab.viewportSize();
	await tab.setViewportSize({ width: 390, height: 720 });
	await tab.waitForFunction(
		() => {
			const status = document.getElementById("composerAvailability");
			const text = status?.querySelector(".said-clamp");
			if (text == null || text.clientHeight === 0) return false;
			const clipped = text.scrollHeight > text.clientHeight + 1 || text.scrollWidth > text.clientWidth + 1;
			return status?.classList.contains("said-more") === clipped;
		},
		undefined,
		{ timeout: 10_000 },
	)
		.catch(() => fail("the composer detail control did not match the failure text's actual clipping"));
	const availabilityBounds = await tab.evaluate(() => {
		const status = document.querySelector<HTMLElement>(".composer-status");
		const availability = document.getElementById("composerAvailability");
		if (status == null || availability == null) return null;
		const outer = status.getBoundingClientRect();
		const inner = availability.getBoundingClientRect();
		return { left: inner.left - outer.left, right: outer.right - inner.right };
	});
	if (availabilityBounds == null || availabilityBounds.left < 14 || availabilityBounds.right < 14) {
		fail(`the phone composer's Show affordance escaped its status inset: ${JSON.stringify(availabilityBounds)}`);
	}
	if (priorViewport != null) await tab.setViewportSize(priorViewport);

	// And the card that exists to answer "what is wrong with this one" says what.
	// The row's caption carries the phase, which is all a narrow line has room
	// for beside the name it also carries, and pressing that caption opens the
	// directory, whose title opens this. So the phase word on its own here would
	// be the single thing the reader already knew.
	await openDirectoryCardFromCaption(tab, aboutOf("elsewhere"));
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
	await tab.waitForSelector("#dircardTitle", { state: "detached", timeout: 10_000 });
	await namedRoomRow(tab, "elsewhere").locator(".room-open").click();
	await tab.waitForFunction(
		() => (document.getElementById("roomName")?.textContent ?? "").includes("elsewhere"),
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("returning from the directory did not put the room back"));

	{
		// A lost reply is unknown delivery. Only the original receipt may recover
		// it; a new membership cannot prove that the previous post was absent.
		const pendingRow = tab.locator(`.row.mine:has-text("${inFlight}")`);
		await pendingRow.locator(".delivery-failure:has-text('Not confirmed')").waitFor({ timeout: 60_000 });
		if (await pendingRow.locator(".delivery-failure button").count() !== 0) {
			fail("an unknown delivery offered a fresh resend");
		}

		// The file that was posted before the server went was also retained by this
		// session's archive. Its live occurrence died with the connection, but the
		// digest reconciles the same drawn attachment onto durable byte custody. The
		// original press therefore still completes, and the downloaded object stays
		// available for another press independently of the dead transport.
		const fileRow = '.row.mine .attach-file:has-text("before.txt")';
		if (await tab.locator(`${fileRow} .icon-button`).count() !== 1) {
			fail("the file posted before the server went lost its control before it was ever pressed");
		}
		const downloaded = tab.waitForEvent("download", { timeout: 30_000 });
		await tab.click(`${fileRow} .icon-button`);
		const file = await downloaded.catch(() =>
			fail("durable file custody did not answer after the live connection ended")
		);
		if (file.suggestedFilename() !== "before.txt") {
			fail(`the recovered download was named ${JSON.stringify(file.suggestedFilename())}`);
		}
		if (await tab.locator(`${fileRow} .icon-button`).count() !== 1) {
			fail("a downloaded durable file stopped offering its now-local bytes");
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
		spawnOwned(SERVER, {
			args: ["--transport=tcp", `--port=${foreignRoomPort}`, `--state=${foreignState}`],
			cwd: ROOT,
			stdout: "null",
			stderr: "inherit",
		});
		// The page dials on its own with a backoff, and re-enters the rooms it
		// holds. Waited for by the room's own roster line rather than by the composer
		// coming back: the composer answers for the directory, which reconnects
		// first. Reopening must use the original persisted server authority and
		// preserve uncertainty about the old send after membership returns.
		await tab.waitForFunction(
			() => ((document.getElementById("log")?.textContent ?? "").match(/in the room\./g) ?? []).length >= 2,
			undefined,
			{ timeout: 90_000 },
		).catch(() => fail("the page never re-entered the room on the second server after it came back"));
		// And it draws as what it is. The room tells an arrival who is present with
		// a tell to that member alone, so the line is one reader's and belongs under
		// the aside this window marks its own lines with, not in the middle of the
		// room beside the joins and leaves everybody was told about.
		const roster = await tab.evaluate(() => {
			const line = [...document.querySelectorAll("#log .sys-line")]
				.find((el) => (el.textContent ?? "").includes("in the room."));
			if (line == null) return null;
			const run = line.closest(".sys");
			return {
				here: run?.classList.contains("here") ?? false,
				aside: run?.textContent?.includes("Only you") ?? false,
			};
		});
		if (roster === null) fail("the roster line was not in the log to check how it is drawn");
		else if (!roster.here || !roster.aside) {
			fail(
				`the roster line is drawn as a shared banner, though only this reader was told it: ${
					JSON.stringify(roster)
				}`,
			);
		}
		await pendingRow.locator(".delivery-failure:has-text('Not confirmed')").waitFor();
		if (await pendingRow.locator(".delivery-failure button").count() !== 0) {
			fail("reconnection changed unknown delivery into permission to resend");
		}
		await openRetainedChanges(tab);
		await tab.getByRole("dialog", { name: /^Unfinished change/ }).waitFor();
		if (await tab.locator(`dialog[open] [data-operation="${originalPending}"]`).count() !== 0) {
			fail("reconnection restored a receipt the reader explicitly released");
		}
		await closeRetainedChanges(tab);
	}
}

async function openRetainedChanges(tab: Page): Promise<void> {
	await tab.click("#settingsBtn");
	await tab.getByRole("tab", { name: "Session", exact: true }).click();
	await tab.click("#sessionChangesOpen");
	await tab.waitForSelector('#sessionRecoveryList[aria-busy="false"]', { state: "attached" });
}

async function closeRetainedChanges(tab: Page): Promise<void> {
	await tab.keyboard.press("Escape");
	await tab.getByRole("dialog", { name: /^Unfinished change/ }).waitFor({ state: "hidden" });
	await tab.keyboard.press("Escape");
	await tab.locator("dialog[open]").waitFor({ state: "hidden" });
}
