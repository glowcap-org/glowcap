// Completing what a reader is part way through typing.
//
// Four things complete — members, rooms, emoji, commands — and each draws from a
// different source that has to be live at the moment the reader asks. What is
// checked is that the list is the room's answer rather than a cached guess.
//
// The rail block at the end was written against three broken builds and refuses
// each: a field given no names to offer, a field that opens the room on the
// press that takes the name, and a field whose combobox role comes and goes
// with its list. It does not reach two neighbouring states. The join card names
// a room through the same hook, and only its wiring — where the names come
// from, where the list hangs — is untested here. And "taking a name did not go
// anywhere" is read as the panel still standing rather than as the reader not
// moving, because at this point in the conversation the rail carries one room
// and going to it would land where the reader already is.

import type { Page } from "playwright";
import { Buffer } from "node:buffer";
import { bubbleInkContrast, fail } from "./harness.ts";
import { inkContrast } from "../ink_contrast.ts";

export async function run(tab: Page, second: Page): Promise<void> {
	// ── Inline completion ────────────────────────────────────────────────
	// `@` plus a prefix raises the list with the roster's match; Enter accepts
	// into the draft instead of sending, which is the regression this guards:
	// with the list open, Enter belongs to the completion.
	await tab.click("#line");
	await tab.type("#line", "@bart");
	await tab.waitForSelector("#completePop [role=option]", { timeout: 10_000 })
		.catch(async () => {
			const saw = await tab.evaluate(() => ({
				draft: (document.getElementById("line") as HTMLTextAreaElement | null)?.value ?? "",
				pop: document.getElementById("completePop")?.innerHTML ?? "(no pop)",
				members: [...document.querySelectorAll("#members li")].map((li) => (li.textContent ?? "").slice(0, 40)),
				room: document.getElementById("roomName")?.textContent ?? "",
				rail: [...document.querySelectorAll("#roomList li .rname")].map((n) => n.textContent ?? ""),
				log: [...document.querySelectorAll("#log .sys")].map((s) => (s.textContent ?? "").slice(0, 80)).slice(
					-6,
				),
				address: location.pathname + location.search + location.hash,
			}));
			fail(`typing @bart never raised the completion list; the page held ${JSON.stringify(saw)}`);
		});
	await tab.press("#line", "Enter");
	const completed = await tab.inputValue("#line");
	if (completed !== "@bartholomew-longname ") {
		const saw = await tab.evaluate(() => ({
			pop: document.getElementById("completePop")?.innerHTML ?? "(no pop)",
			members: [...document.querySelectorAll("#members li")].map((li) => (li.textContent ?? "").slice(0, 40)),
			log: [...document.querySelectorAll("#log .sys")].map((s) => (s.textContent ?? "").slice(0, 60)).slice(-4),
		}));
		fail(`completion left the draft as ${JSON.stringify(completed)}; the page held ${JSON.stringify(saw)}`);
	}
	// Completion starts on the first useful emoji character; waiting for two or
	// more makes a fast typist outrun a discoverability feature.
	await tab.type("#line", ":r");
	await tab.waitForSelector("#completePop [role=option]", { timeout: 10_000 })
		.catch(() => fail("typing :r never raised the emoji list"));
	await tab.type("#line", "ocke");
	await tab.press("#line", "Enter");
	const withEmoji = await tab.inputValue("#line");
	if (!withEmoji.endsWith("🚀")) {
		fail(`emoji completion left the draft as ${JSON.stringify(withEmoji)}`);
	}
	await tab.fill("#line", "");

	// Commands are discoverable before the reader already knows their spelling.
	// The accepted command then rides the ordinary message protocol, and every
	// client renders it as an action rather than a literal slash-prefixed line.
	await tab.type("#line", "/");
	// Braced so these names belong to this check rather than to the whole file.
	// This module is one long scope, and three separate additions to it have now
	// collided with a name a hundred lines away.
	{
		const labels = await tab.locator("#completePop [role=option]").allTextContents();
		if (labels.length === 0) fail("typing / offered no commands at all");
		// Every one says what it does, so the list teaches rather than expecting a
		// reader to already know the vocabulary. Counted as rows that carry the
		// half saying so, and read as a sentence for software that has only the
		// text: the space between a name and its summary is drawn by the layout,
		// and a layout says nothing to a screen reader.
		const said = await tab.evaluate(() =>
			[...document.querySelectorAll("#completePop [role=option]")].map((row) => ({
				name: row.querySelector(".complete-label")?.textContent ?? "",
				hint: row.querySelector(".complete-hint")?.textContent ?? "",
				spoken: row.getAttribute("aria-label") ?? "",
			}))
		);
		// It belongs to the field it is completing, so it rests against it rather
		// than against the band the field sits in — with the reserved hint line
		// between them it stood forty-three pixels off and read as a thing that had
		// arrived rather than one the caret had raised.
		const against = await tab.evaluate(() => {
			const pop = document.getElementById("completePop")?.getBoundingClientRect();
			const field = document.querySelector(".composer form")?.getBoundingClientRect();
			return pop === undefined || field === undefined ? null : Math.round(field.top - pop.bottom);
		});
		if (against === null) fail("the completion list or the field it completes was not there to measure");
		else if (against < 0 || against > 12) {
			fail(`the completion list sits ${against}px from the field that raised it`);
		}

		// Typing / is how a reader finds out what they can do here, so it answers
		// with everything and not with a first handful. Held against the catalog
		// rather than a number written here: what a conversation may run is the
		// room's to decide, and a count in this file would be a second opinion on
		// it that drifts. More than the box holds is the whole point, so the check
		// is that the list is longer than a screenful of it.
		const offered = await tab.evaluate(() => {
			const pop = document.getElementById("completePop");
			const rows = pop?.querySelectorAll("[role=option]").length ?? 0;
			return pop === null ? null : { rows, scrolls: pop.scrollHeight > pop.clientHeight + 1 };
		});
		if (offered === null) fail("the completion list was not there to measure");
		else if (offered.rows < 12) {
			fail(`typing / offered ${offered.rows} commands, which is a handful and not the vocabulary`);
		} else if (!offered.scrolls) {
			fail(`the completion list holds all ${offered.rows} commands without scrolling, so it has grown unbounded`);
		}
		// That the pick scrolls with the arrows is held by the effect in
		// Composer.tsx and is deliberately not walked here. This scene is one long
		// conversation on a thirty second deadline, and pressing arrows in the
		// composer moves state the rest of it reads: the draft, the recalled line,
		// and which row Enter would take. A check that costs the scene its budget is
		// not a check, it is a second defect.

		const mute = said.filter((row) => row.hint === "");
		if (mute.length > 0) fail(`a command was offered with nothing said about it: ${JSON.stringify(mute)}`);
		const run = said.filter((row) => !row.spoken.includes(", "));
		if (run.length > 0) fail(`a command's name runs into its summary when read out: ${JSON.stringify(run)}`);
		// A command this room has not handed over, or that only a room can run, is
		// not in the list. Offering `/kick` here would only teach the refusal.
		await tab.fill("#line", "");
		await tab.type("#line", "/kick");
		const waiting = await tab.evaluate(() =>
			[...document.querySelectorAll("#completePop [role=option]")].map((row) =>
				row.querySelector(".complete-label")?.textContent ?? ""
			)
		);
		if (waiting.includes("/kick")) {
			fail(`/kick was offered before this room handed it over: ${JSON.stringify(waiting)}`);
		}
		// Left as the next check found it: a bare slash, mid-typing.
		await tab.fill("#line", "");
		await tab.type("#line", "/");
		await tab.waitForSelector("#completePop [role=option]", { timeout: 10_000 })
			.catch(() => fail("the command list did not come back"));
	}
	// Typed far enough to name one, the list narrows to it and Enter takes it.
	await tab.type("#line", "me");
	await tab.waitForSelector('#completePop [role=option]:has-text("/me")', { timeout: 10_000 })
		.catch(() => fail("typing /me did not offer the /me command"));
	await tab.press("#line", "Enter");
	if (await tab.inputValue("#line") !== "/me ") fail("accepting /me did not leave an action draft");
	await tab.fill("#line", "/me waves hello");
	await tab.press("#line", "Enter");
	await second.waitForSelector('.sys.action:has-text("✻ web-alice waves hello")', { timeout: 30_000 })
		.catch(() => fail("the second peer did not render /me as an action"));

	// Changing and taking back a line, all the way through: the room hands back a
	// reference to each line it takes, and holding one is the authority. Asked
	// from the other tab as well as this one, because a line changing only for
	// the person who changed it would look identical from here and be useless.
	{
		const said = "frist post";
		await tab.fill("#line", said);
		await tab.press("#line", "Enter");
		await second.waitForSelector(`.bubble:has-text("${said}")`, { timeout: 30_000 })
			.catch(() => fail("the other peer never saw the line that was about to be changed"));

		await tab.fill("#line", "/edit first post");
		await tab.press("#line", "Enter");
		await second.waitForSelector('.bubble:has-text("first post")', { timeout: 30_000 })
			.catch(() => fail("an edit never reached the other peer"));
		// The old words are gone rather than sitting beside the new ones.
		if (await second.locator(`.bubble:has-text("${said}")`).count() > 0) {
			fail("the line still reads as what it used to say");
		}
		// And it says it moved, so a reader who answered the old words can tell.
		await second.waitForSelector(".edited-said", { timeout: 10_000 })
			.catch(() => fail("a changed line does not say it was changed"));

		await tab.fill("#line", "/delete");
		await tab.press("#line", "Enter");
		await second.waitForSelector(".bubble.withdrawn", { timeout: 30_000 })
			.catch(async () => {
				const there = await second.evaluate(() =>
					[...document.querySelectorAll(".bubble")].map((b) =>
						b.className + ": " + (b.textContent ?? "").slice(0, 30)
					)
				);
				const here = await tab.evaluate(() =>
					[...document.querySelectorAll("#log .sys")].map((s) => (s.textContent ?? "").slice(0, 90))
				);
				const composer = await tab.inputValue("#line");
				fail(
					`the other peer never showed a line as withdrawn; it holds ${
						JSON.stringify(there)
					}, this tab was told ${JSON.stringify(here)}, and its composer holds ${JSON.stringify(composer)}`,
				);
			});
		// It keeps its place and shows none of what it said.
		if (await second.locator('.bubble:has-text("first post")').count() > 0) {
			fail("a withdrawn line still shows what it said");
		}
		await second.waitForSelector('.withdrawn-said:has-text("Message withdrawn")', { timeout: 10_000 })
			.catch(() => fail("a withdrawn line does not say what happened to it"));
	}

	// The pencil changes the line it was pressed on. `/edit` changes the most
	// recent one, so a pencil that only filled the composer with that command
	// would quietly rewrite a different message whenever a reader picked an older
	// one — which is why the composer remembers the line rather than the words.
	{
		for (const said of ["older line", "newer line"]) {
			await tab.fill("#line", said);
			await tab.press("#line", "Enter");
			await second.waitForSelector(`.bubble:has-text("${said}")`, { timeout: 30_000 })
				.catch(() => fail(`the other peer never saw "${said}"`));
		}
		const older = tab.locator('.bubble:has-text("older line")').last();
		// The controls appear on the message under the pointer, so reach it the way
		// a reader does rather than by making them permanently visible for a test.
		await older.hover();
		await older.getByLabel("More for this message").click();
		await tab.locator('.line-menu [role=menuitem]:has-text("Edit")').click();
		if (await tab.inputValue("#line") !== "older line") {
			fail("the pencil did not put that line's words in the composer");
		}
		await tab.waitForSelector("#changing", { timeout: 10_000 })
			.catch(() => fail("the composer does not say it is changing a message rather than writing one"));
		// The words are in the field; so is the caret, at the end of them. Pressed
		// from a menu that closes on the same press, the focus lands on nothing
		// unless it is handed over, and a reader has to click into their own
		// sentence before they can change it.
		const ready = await tab.evaluate(() => {
			const box = document.getElementById("line") as HTMLTextAreaElement | null;
			return {
				focused: document.activeElement === box,
				caret: box?.selectionStart ?? -1,
				end: box?.value.length ?? -1,
				marked: [...document.querySelectorAll(".bubble.changing")].map((b) =>
					(b.textContent ?? "").slice(0, 20)
				),
			};
		});
		if (!ready.focused) fail(`pressing Edit left the caret elsewhere: ${JSON.stringify(ready)}`);
		if (ready.caret !== ready.end) {
			fail(`the caret is not at the end of what is being rewritten: ${JSON.stringify(ready)}`);
		}
		// And the log says which line that is. It matters more than it did when
		// only the newest could be changed: this menu will rewrite any line still
		// held, including one well up the conversation.
		if (ready.marked.length !== 1 || !ready.marked[0].includes("older line")) {
			fail(`the log does not mark the one line being rewritten: ${JSON.stringify(ready.marked)}`);
		}
		await tab.fill("#line", "older line, fixed");
		await tab.press("#line", "Enter");
		await second.waitForSelector('.bubble:has-text("older line, fixed")', { timeout: 30_000 })
			.catch(() => fail("the change made with the pencil never reached the other peer"));
		// The one that says whether the right line moved: the newest line is still
		// the newest and still says what it said.
		const newest = await second.locator(".bubble").last().textContent();
		if (newest === null || !newest.includes("newer line")) {
			fail(`the pencil changed the most recent line instead of the one it was on: ${JSON.stringify(newest)}`);
		}
		// And the composer is a composer again, with nothing held over.
		if (await tab.locator("#changing").count() !== 0) {
			fail("the composer still says it is changing a message after the change was sent");
		}

		// The note that says it moved comes after the words it qualifies, with a
		// gap: drawn before them it reads as a label on the message rather than a
		// remark at the end of it, and against them it reads as part of what was
		// said.
		await second.waitForSelector(".edited-said", { timeout: 30_000 })
			.catch(() => fail("the other peer's copy of a changed line does not say it changed"));
		const note = await second.evaluate((words) => {
			const said = document.querySelector(".edited-said") as HTMLElement | null;
			const bubble = said?.closest(".bubble") as HTMLElement | null;
			if (said === null || bubble == null) return null;
			// The words are text nodes in the bubble rather than an element of their
			// own, so this asks the bubble's own child order and measures the text
			// with a range over the node that holds it.
			const kids = [...bubble.childNodes];
			const noteAt = kids.indexOf(said);
			let wordsAt = -1;
			let text: DOMRect | null = null;
			for (let at = 0; at < kids.length; at++) {
				const node = kids[at];
				if (node === said || !(node.textContent ?? "").includes(words)) continue;
				wordsAt = at;
				const range = document.createRange();
				range.selectNode(node);
				text = range.getBoundingClientRect();
			}
			const mark = said.getBoundingClientRect();
			return {
				after: wordsAt >= 0 && noteAt > wordsAt,
				gap: text === null ? -1 : Math.round(mark.left - text.right),
				said: said.textContent ?? "",
			};
		}, "older line, fixed");
		if (note === null) fail("a changed line drew no note about it");
		else if (!note.after) fail(`the note that a line changed is drawn before its words: ${JSON.stringify(note)}`);
		else if (note.gap < 3 && note.gap > -1) {
			fail(`the note that a line changed is jammed against the words: ${JSON.stringify(note)}`);
		}

		// And it can be read. Small and quiet is the point of it; unreadable is not,
		// and on this tab's own bubble it sits on the accent fill, where a grey
		// chosen against paper turns to mud. Two measures, because the two bubbles
		// are painted differently — an accent gradient one side and a flat surface
		// the other — and the tool for one cannot answer about the other.
		const overGradient = await bubbleInkContrast(tab, ".row.mine .edited-said");
		if (!("ratio" in overGradient)) {
			fail(`the note on this tab's own changed line could not be measured: ${overGradient.why}`);
		} else if (overGradient.ratio < 4.5) {
			fail(`the note on this tab's own changed line reads at ${overGradient.ratio.toFixed(2)}:1`);
		}
		const overPaper = await inkContrast(second, ".row.them .edited-said");
		if (overPaper === null) fail("the note on the other peer's copy of a changed line could not be measured");
		else if (overPaper.ratio < 4.5) {
			fail(`the note on the other peer's copy reads at ${overPaper.ratio.toFixed(2)}:1 over ${overPaper.saw}`);
		}
	}

	// What the room is about is a capability rather than a rank. The room answers
	// every subscribe with the authority to set it, so this works from a tab that
	// did not open the room, and it reaches everybody including whoever arrives
	// afterwards.
	{
		await tab.fill("#line", "/topic what we are here for");
		await tab.press("#line", "Enter");
		await second.waitForSelector('#topic:has-text("what we are here for")', { timeout: 30_000 })
			.catch(async () => {
				const said = await tab.evaluate(() =>
					[...document.querySelectorAll("#log .sys")].map((s) => (s.textContent ?? "").slice(0, 90)).slice(-3)
				);
				fail(`the topic never reached the other peer; this tab was last told ${JSON.stringify(said)}`);
			});
		// The way to change it is offered because this membership was handed the
		// ability, and pressing it writes the command with what the topic says
		// now — so amending a topic is amending text rather than retyping it.
		await tab.waitForSelector('#topic [aria-label="Change the topic"]', { timeout: 10_000 })
			.catch(() => fail("a member the room handed the topic to was not offered a way to change it"));
		await tab.click('#topic [aria-label="Change the topic"]');
		if (await tab.inputValue("#line") !== "/topic what we are here for") {
			fail(`changing the topic did not write the command: ${JSON.stringify(await tab.inputValue("#line"))}`);
		}
		// Taking it down is a thing somebody does on purpose, so it is an empty
		// topic rather than no topic, and the bar goes rather than sitting there
		// holding a blank. The bar offers it as its own control, which writes
		// the command like the pencil does, so the reader confirms in the
		// composer rather than losing the topic to one slip.
		await tab.click('#topic [aria-label="Take the topic down"]');
		if (await tab.inputValue("#line") !== "/topic -") {
			fail(`the take-down control did not write the command: ${JSON.stringify(await tab.inputValue("#line"))}`);
		}
		await tab.press("#line", "Enter");
		await second.waitForSelector("#topic", { state: "detached", timeout: 30_000 })
			.catch(() => fail("taking the topic down left the bar on screen"));
	}

	// Stepping away is a member's own standing rather than something handed to
	// them, and it is about somebody who is still here: the room says it, and it
	// shows against their name where the question "are they reading this" is
	// actually asked.
	{
		await tab.fill("#line", "/away back in ten");
		await tab.press("#line", "Enter");
		await second.waitForSelector('#members li.away .away-said:has-text("back in ten")', { timeout: 30_000 })
			.catch(async () => {
				const rows = await second.evaluate(() =>
					[...document.querySelectorAll("#members li")].map((li) =>
						li.className + ": " + (li.textContent ?? "").slice(0, 40)
					)
				);
				fail(`the other peer's member list does not show who stepped away: ${JSON.stringify(rows)}`);
			});
		// Bare says you are back, the way it has in every client for thirty years.
		await tab.fill("#line", "/away");
		await tab.press("#line", "Enter");
		await second.waitForSelector("#members li.away", { state: "detached", timeout: 30_000 })
			.catch(() => fail("coming back left the member list saying otherwise"));
	}

	// A notice travels in the line the way an action does, so it needs nothing
	// from the room, and it keeps its author because it is somebody speaking. It
	// names the other member on purpose: the point of sending one is to say
	// something without pulling anybody back to their screen.
	{
		await tab.fill("#line", "/notice @bartholomew-longname the build is green again");
		await tab.press("#line", "Enter");
		await second.waitForSelector('.sys.notice:has-text("-web-alice- ")', { timeout: 30_000 })
			.catch(() => fail("a notice did not arrive drawn as one"));
		// Drawn as a notice rather than as an ordinary line, which is what says it
		// went quietly.
		if (await second.locator('.bubble:has-text("the build is green again")').count() > 0) {
			fail("a notice was drawn as an ordinary message");
		}
	}

	// Fenced code is posted as ordinary text but rendered as a block. Shortcodes
	// inside it stay source code: rich-text substitution must stop at the fence.
	const fenced = '```ts\nconst launch = ":rocket:";\n```';
	await tab.fill("#line", fenced);
	await tab.press("#line", "Enter");
	await second.waitForFunction(
		() =>
			[...document.querySelectorAll(".code-block code")].some((code) =>
				code.textContent === 'const launch = ":rocket:";'
			),
		undefined,
		{ timeout: 30_000 },
	).catch(() => fail("the second peer did not render the fenced source as an exact code block"));

	// Admission happens before Send consumes the composer. A file the shared
	// attachment contract refuses leaves both its chip and caption in place so
	// the reader can correct the problem rather than reconstruct the message.
	const invalidName = "x".repeat(300) + ".txt";
	await tab.setInputFiles("#filePick", {
		name: invalidName,
		mimeType: "text/plain",
		buffer: Buffer.from("still here"),
	});
	await tab.fill("#line", "keep this draft");
	await tab.click("#sendBtn");
	if (await tab.inputValue("#line") !== "keep this draft") {
		fail("refusing an invalid attachment consumed its caption");
	}
	await tab.waitForSelector(`.composer-file:has-text("${invalidName}")`, { timeout: 10_000 })
		.catch(() => fail("refusing an invalid attachment removed its composer chip"));
	await tab.click(`.composer-file:has-text("${invalidName}") .composer-file-remove`);
	await tab.fill("#line", "");

	// More files than a message can carry. Keeping every one of them for the
	// reader to correct is the right answer to a file the contract refuses and the
	// wrong one to a folder dropped on the composer: the correction is removing
	// them one press at a time before anything can be sent. What fits is taken and
	// the rest is refused at the gesture, saying so.
	{
		const many = Array.from({ length: 11 }, (_, at) => ({
			name: `spare-${at}.txt`,
			mimeType: "text/plain",
			buffer: Buffer.from(`file ${at}`),
		}));
		await tab.setInputFiles("#filePick", many);
		await tab.waitForFunction(
			() => (document.getElementById("log")?.textContent ?? "").includes("left out"),
			undefined,
			{ timeout: 10_000 },
		).catch(() => fail("dropping more files than a message can carry said nothing about the ones left out"));
		const chips = await tab.locator(".composer-file").count();
		if (chips !== 8) fail(`the composer took ${chips} files onto a message that can carry 8`);
		// And the ones it took are attachable: Send is ready, not refusing.
		if (await tab.isDisabled("#sendBtn")) fail("the files that fit did not make Send ready");
		for (let at = 0; at < chips; at++) await tab.click(".composer-file .composer-file-remove");
		if (await tab.locator(".composer-file").count() !== 0) {
			fail("the composer kept a file after every chip was removed");
		}
	}
	await tab.fill("#line", "");

	// ── Naming a room in the rail ────────────────────────────────────────
	// The composer is not the only place a name is typed. The rail's "+" panel
	// names a room too, and it finishes the same way from the same source the
	// directory advertises, so a reader who learned the list in one place has
	// not learned a second control on arriving at the other.
	//
	// Measured against a room this tab can already see rather than a name
	// written down here: what the directory carries at this point in the
	// conversation belongs to the conversation, and a proof that pinned it
	// would be checking its own arithmetic.
	{
		const known = await tab.evaluate(() =>
			document.querySelector("#roomList li .rname")?.textContent?.trim() ?? ""
		);
		if (known.length < 3) fail(`the rail carried no room to finish against, only ${JSON.stringify(known)}`);
		const start = known.slice(0, 2);
		await tab.click("#newRoomBtn");
		// Asked with nothing typed and no list up. A field that can finish names
		// says so for as long as it can, rather than only while its list stands:
		// the two are different claims, and software that reads the page aloud
		// announces a whole new control every time the first one changes.
		const idle = await tab.evaluate(() => {
			const field = document.getElementById("newRoomInput");
			return { role: field?.getAttribute("role") ?? "", open: field?.getAttribute("aria-expanded") ?? "" };
		});
		if (idle.role !== "combobox" || idle.open !== "false") {
			fail(`the rail field with no list up announced ${JSON.stringify(idle)}`);
		}
		await tab.type("#newRoomInput", start);
		await tab.waitForSelector("#newRoomOffers [role=option]", { timeout: 10_000 })
			.catch(() =>
				fail(`typing ${JSON.stringify(start)} in the rail offered no rooms, though ${known} starts with it`)
			);
		// The field says what it is and what it is doing, which is the composer's
		// own contract: one control that opens and closes, not a textbox that
		// turns into a combobox and back on every keystroke.
		const said = await tab.evaluate(() => {
			const field = document.getElementById("newRoomInput");
			return {
				role: field?.getAttribute("role") ?? "",
				open: field?.getAttribute("aria-expanded") ?? "",
				owns: field?.getAttribute("aria-controls") ?? "",
			};
		});
		if (said.role !== "combobox" || said.open !== "true" || said.owns !== "newRoomOffers") {
			fail(`the rail field with its list up announced ${JSON.stringify(said)}`);
		}
		// Walking to a row and taking it fills the field with the whole name and
		// stops there. Enter belongs to the list; the press that submits is the
		// next one, so a row the reader has only just arrived at cannot open a
		// room on its own.
		//
		// Read as "the panel is still standing" rather than "the reader did not
		// move", because a name taken here may well be the room already open, and
		// then going would leave no mark to find. A panel that submitted has put
		// itself away, whatever it opened.
		await tab.press("#newRoomInput", "ArrowDown");
		await tab.press("#newRoomInput", "Enter");
		const standing = await tab.evaluate(() => ({
			open: document.getElementById("newRoom")?.classList.contains("show") ?? false,
			held: (document.getElementById("newRoomInput") as HTMLInputElement | null)?.value ?? "",
		}));
		if (!standing.open) fail("taking an offered room name submitted the rail panel instead of filling it");
		if (standing.held !== known) {
			fail(`taking the first offered room left the rail field as ${JSON.stringify(standing.held)}`);
		}
		await tab.fill("#newRoomInput", "");
		await tab.press("#newRoomInput", "Escape");
		await tab.press("#newRoomInput", "Escape");
	}
}
