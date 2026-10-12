// Real /relay traffic and DOM identities, including intermediate mutations that
// a final screenshot cannot see. Called by rooms-web-responsiveness. No product hooks.
import type { Browser, Page } from "playwright";
import { establishLocalSession } from "../support/session_setup.ts";
import { awaitBubble, fail, openDmTo, say } from "./harness.ts";

async function watch(page: Page, who: string): Promise<void> {
	await page.evaluate((who) => {
		const bubbles = new Map<string, Element>();
		const errors: string[] = [];
		const timings: number[] = [];
		const inputs: number[] = [];
		const cancelled = new Set<string>();
		const said = new Set<string>();
		// One entry per distinct condition. An observer that repeats per mutation
		// buries the fact that names the failure under hundreds of copies of it.
		const once = (message: string) => {
			if (said.has(message)) return;
			said.add(message);
			errors.push(`${who}: ${message}`);
		};
		const input = (event: Event) => {
			if ((event.target as HTMLElement).id !== "line") return;
			requestAnimationFrame(() => requestAnimationFrame(() => inputs.push(performance.now() - event.timeStamp)));
		};
		document.addEventListener("input", input);
		const observer = new MutationObserver(() => {
			// Two surfaces wear this class. The effects bar holds unfinished
			// changes and its text carries how many; the paused notice names the
			// paused or revoked link. Neither is expected here, and the words each
			// says are the diagnosis.
			const bar = document.querySelector(".session-effect-notice:not(.session-paused-notice)");
			if (bar != null && !said.has("retained effects bar")) {
				said.add("retained effects bar");
				const recent = [...document.querySelectorAll(".bubble")].slice(-2).map((node) =>
					node.textContent?.match(/responsive-[a-z]+-\d+/)?.[0] ?? "?"
				);
				const settings = document.querySelector("#settingsTitle") ? ", settings open" : "";
				errors.push(
					`${who}: retained effects bar appeared while [${recent}] was the latest activity${settings}: ${bar.textContent?.trim()}`,
				);
			}
			const paused = document.querySelector(".session-paused-notice");
			if (paused != null) once(`the page says its session is paused: ${paused.textContent?.trim()}`);
			for (const row of document.querySelectorAll("#roomList li:not(.room-pending) .rname-text")) {
				if (cancelled.has(row.textContent ?? "")) once(`cancelled room appeared: ${row.textContent}`);
			}
			for (const node of document.querySelectorAll(".bubble")) {
				const text = node.textContent ?? "";
				const identity = text.match(/responsive-[a-z]+-\d+/)?.[0];
				if (identity == null) continue;
				const original = bubbles.get(identity);
				if (original != null && original !== node) once(`replaced or duplicated ${identity}`);
				bubbles.set(identity, node);
			}
		});
		observer.observe(document.body, { subtree: true, childList: true, attributes: true });
		const long = new PerformanceObserver((list) => timings.push(...list.getEntries().map((row) => row.duration)));
		long.observe({ type: "longtask" });
		Object.assign(globalThis, {
			responsiveness: { errors, timings, inputs, input, bubbles, observer, long, cancelled },
		});
	}, who);
}

export async function run(browser: Browser, port: number, transport: "TCP" | "iroh" = "TCP"): Promise<void> {
	const context = await browser.newContext({ reducedMotion: "reduce", viewport: { width: 1280, height: 800 } });
	const alice = await context.newPage();
	const bobContext = await browser.newContext();
	const bob = await bobContext.newPage();
	let delay = 0;
	let packets = 0;
	let peak = 0;
	let hold = false;
	const buffered: (() => void)[] = [];
	const timers = new Set<ReturnType<typeof setTimeout>>();
	await alice.routeWebSocket("**/relay**", (socket) => {
		const server = socket.connectToServer();
		const forward = (send: () => void) => {
			packets++;
			if (delay === 0) {
				send();
				return;
			}
			if (timers.size >= 256) fail("responsiveness transport queue exceeded 256 frames");
			const timer = setTimeout(() => {
				timers.delete(timer);
				send();
			}, delay);
			timers.add(timer);
			peak = Math.max(peak, timers.size);
		};
		socket.onMessage((message) => forward(() => server.send(message)));
		server.onMessage((message) => {
			if (hold) {
				if (buffered.length >= 256) fail("burst transport queue exceeded 256 frames");
				buffered.push(() => socket.send(message));
				peak = Math.max(peak, buffered.length);
			} else forward(() => socket.send(message));
		});
	});
	try {
		for (const [page, nick] of [[alice, "responsive-alice"], [bob, "responsive-bob"]] as const) {
			await page.goto(`http://127.0.0.1:${port}/`);
			await establishLocalSession(page);
			await watch(page, nick);
			await page.fill("#nick", nick);
			await page.fill("#room", "responsiveness");
			await page.click("#joinBtn");
			await page.waitForSelector("#line:not([disabled])", { timeout: 60_000 });
		}
		// Opening an existing direct conversation must also remain quiet. Do this
		// before the tracked room posts: selecting a different log may remount it.
		await openDmTo(alice, "responsive-bob");
		await alice.locator("#roomList .room-open").filter({ hasText: "responsiveness" }).click();
		await openDmTo(alice, "responsive-bob");
		if (await alice.locator("[data-busy=true]").count()) fail("an existing direct line painted busy");
		await alice.locator("#roomList .room-open").filter({ hasText: "responsiveness" }).click();
		// Withhold real server replies. Cancel must release the form and the
		// rail before a reply arrives, and late work must not select its room.
		await alice.click(".wordmark-link");
		await alice.fill("#room", "cancel-main-join");
		hold = true;
		await alice.click("#joinBtn");
		await alice.locator("#joinStop:enabled").click();
		await alice.evaluate(() => {
			(globalThis as unknown as { responsiveness: { cancelled: Set<string> } }).responsiveness.cancelled.add(
				"cancel-main-join",
			);
		});
		await alice.locator("#joinBtn:enabled").waitFor({ timeout: 1000 });
		if (!(await alice.locator("#room").isEditable())) fail("cancel kept the join fields inert");
		hold = false;
		for (const send of buffered.splice(0)) send();
		await alice.locator("#roomList .room-open").filter({ hasText: "responsiveness" }).click();
		await alice.waitForSelector("#line:not([disabled])");
		await alice.click("#newRoomBtn");
		await alice.fill("#newRoomInput", "cancel-sidebar-join");
		hold = true;
		await alice.press("#newRoomInput", "Enter");
		await alice.locator("#roomList .room-pending").waitFor({ timeout: 1000 });
		for (const width of [1280, 390]) {
			await alice.setViewportSize({ width, height: 844 });
			if (width === 390) await alice.click("#backBtn");
			const geometry = await alice.locator("#roomList .room-pending").evaluate((row) => {
				const box = row.getBoundingClientRect();
				const cancel = row.querySelector("button")!.getBoundingClientRect();
				const name = row.querySelector(".rname")!.getBoundingClientRect();
				const status = row.querySelector(".rwhere-status")!;
				const ring = getComputedStyle(row.querySelector(".room-progress")!, "::after");
				return {
					contained: cancel.left >= box.left && cancel.right <= box.right &&
						cancel.top >= box.top && cancel.bottom <= box.bottom,
					captionOffset: status.getBoundingClientRect().left - name.left,
					captionSize: parseFloat(getComputedStyle(status).fontSize),
					nameSize: parseFloat(getComputedStyle(row.querySelector(".rname")!).fontSize),
					ringWidth: parseFloat(ring.width),
					ringHeight: parseFloat(ring.height),
					overflow: document.documentElement.scrollWidth > innerWidth,
				};
			});
			if (
				!geometry.contained || Math.abs(geometry.captionOffset) > 1 || geometry.overflow ||
				geometry.captionSize >= geometry.nameSize || geometry.ringWidth !== geometry.ringHeight ||
				geometry.ringWidth !== 13
			) {
				fail(`pending room bounds at ${width}px: ${JSON.stringify(geometry)}`);
			}
		}
		await alice.getByLabel("Stop joining cancel-sidebar-join", { exact: true }).click();
		await alice.evaluate(() => {
			(globalThis as unknown as { responsiveness: { cancelled: Set<string> } }).responsiveness.cancelled.add(
				"cancel-sidebar-join",
			);
		});
		await alice.locator("#roomList .room-pending").waitFor({ state: "hidden", timeout: 1000 });
		await alice.setViewportSize({ width: 1280, height: 800 });
		hold = false;
		for (const send of buffered.splice(0)) send();
		// The next real post proves all older requests have drained without
		// taking selection away from the original conversation.
		await say(alice, "responsive-after-cancel");
		await awaitBubble(bob, "responsive-after-cancel", "responsive-bob");
		if (await alice.locator("#roomList li.here").filter({ hasText: "cancel-" }).count()) {
			fail("a cancelled acquisition selected its late room");
		}
		const cancellationErrors = await alice.evaluate(() =>
			(globalThis as unknown as { responsiveness: { errors: string[] } }).responsiveness.errors
		);
		if (cancellationErrors.length) fail(cancellationErrors.join("; "));
		// The reload must interrupt nothing: a send receipt whose reply the reload
		// takes away is a retained operation with an uncertain outcome, and the
		// page's answer to that is the recovery bar, which is not what
		// this proof watches for. Bob's echo can land before Alice's own receipt
		// settles, so first wait for every drawn line to leave its sending,
		// failed, or unconfirmed state. The flushed replies of the cancelled
		// joins may still be proving their outcomes with nothing drawn to show
		// for it, so the proof then asks the page the question directly: the
		// session's own receipt inventory, which stays open in Settings and
		// re-reads until a read finds nothing held.
		await alice.waitForFunction(
			() =>
				[...document.querySelectorAll(".bubble")].every((node) =>
					!/\b(?:sending|failed|unconfirmed)\b/.test(node.className)
				),
			undefined,
			{ timeout: 10_000 },
		).catch(() => fail("a line was still unsettled when the proof reloaded"));
		await alice.click("#settingsBtn").catch(() => fail("settings did not open for the receipt drain"));
		await alice.click("#sessionTab");
		await alice.click("#sessionChangesOpen").catch(() => fail("the receipt inventory did not open"));
		await alice.waitForFunction(
			() => {
				const list = document.querySelector("#sessionRecoveryList");
				return list != null && list.getAttribute("aria-busy") === "false" &&
					list.querySelectorAll("li").length === 0;
			},
			undefined,
			{ timeout: 10_000 },
		).catch(() => fail("the receipt inventory never emptied before the reload"));
		const drained = (await alice.textContent(".session-recovery-modal .lead"))?.trim() ?? "";
		if (drained !== "There are no unfinished changes to review.") {
			fail(`the receipt inventory was not empty at the reload: ${JSON.stringify(drained)}`);
		}
		await alice.keyboard.press("Escape");
		await alice.waitForSelector("#sessionRecoveryTitle", { state: "hidden", timeout: 5_000 })
			.catch(() => fail("the receipt inventory stayed open after Escape"));
		await alice.keyboard.press("Escape");
		await alice.waitForSelector("#settingsTitle", { state: "hidden", timeout: 5_000 })
			.catch(() => fail("settings stayed open after Escape"));
		await alice.reload();
		await alice.waitForSelector("#line:not([disabled])");
		if (await alice.locator("#roomList .rname-text").filter({ hasText: /^cancel-/ }).count()) {
			fail("reloading restored a cancelled room from retained membership");
		}
		await watch(alice, "responsive-alice");
		for (let i = 0; i < 3; i++) {
			await say(alice, `responsive-fast-${i}`);
			await awaitBubble(bob, `responsive-fast-${i}`, "responsive-bob");
		}

		const editable = alice.locator(".bubble").filter({ hasText: "responsive-fast-2" });
		await editable.hover();
		await editable.getByLabel("More for this message", { exact: true }).click();
		await alice.getByRole("menuitem", { name: "Edit", exact: true }).click();
		await alice.waitForSelector("#changing");
		await say(alice, "responsive-fast-2 edited");
		await awaitBubble(bob, "responsive-fast-2 edited", "responsive-bob");
		const withdrawing = alice.locator(".bubble").filter({ hasText: "responsive-fast-1" });
		await withdrawing.hover();
		await withdrawing.getByLabel("More for this message", { exact: true }).click();
		await alice.getByRole("menuitem", { name: "Withdraw", exact: true }).click();
		await bob.locator(".bubble.withdrawn").waitFor();
		await alice.click("#settingsBtn");
		await alice.click("#sessionTab");
		const keeping = await alice.getAttribute("#keepHistoryToggle", "aria-checked");
		await alice.click("#keepHistoryToggle");
		await alice.waitForFunction((keeping) => {
			const control = document.querySelector<HTMLButtonElement>("#keepHistoryToggle");
			return control != null && !control.disabled && control.getAttribute("aria-checked") !== keeping;
		}, keeping);
		await alice.keyboard.press("Escape");
		await alice.waitForSelector("#settingsTitle", { state: "hidden" });
		await say(alice, "/topic responsiveness proof");
		await bob.waitForFunction(() => document.body.textContent?.includes("responsiveness proof"));
		await alice.click("#standingBtn");
		await alice.locator(".standing-menu [role=menuitemradio]").filter({ hasText: /^Away$/ }).click();
		await alice.waitForFunction(() => document.querySelector("#standingBtn #status")?.textContent === "away");
		// Slow the actual production websocket in both directions. The packet
		// counter and remote arrival prove this emulation reached the transport.
		const before = packets;
		delay = 1200;
		await say(alice, "responsive-slow-0");
		await alice.locator(".bubble.sending").filter({ hasText: "responsive-slow-0" }).waitFor();
		if (packets <= before) fail("network emulation did not intercept Rooms traffic");
		await awaitBubble(bob, "responsive-slow-0", "responsive-bob");
		delay = 0;
		await alice.waitForFunction(() =>
			![...document.querySelectorAll(".bubble.sending")].some((b) => b.textContent?.includes("responsive-slow-0"))
		);
		// Closing Settings during a delayed save must not reopen it or steal focus.
		delay = 1200;
		await alice.click("#settingsBtn");
		await alice.click("#sessionTab");
		await alice.click("#keepHistoryToggle");
		if (!(await alice.locator("#keepHistoryToggle").isDisabled())) fail("save did not disable on the press");
		await alice.keyboard.press("Escape");
		await alice.waitForSelector("#settingsTitle", { state: "hidden" });
		await alice.fill("#line", "my newer draft");
		delay = 0;
		// Warm history makes scroll retention observable before releasing the burst.
		for (let i = 0; i < 16; i++) {
			await say(bob, `responsive-warm-${i}`);
			await awaitBubble(alice, `responsive-warm-${i}`, "responsive-alice");
		}
		await alice.locator("#log").evaluate((log) => {
			log.scrollTop = 0;
		});
		const anchor = await alice.locator("#log").evaluate((log) => {
			if (log.scrollHeight <= log.clientHeight) throw new Error("scroll proof needs overflowing history");
			return log.querySelector(".bubble")!.getBoundingClientRect().top;
		});
		// A burst of 64 real posts grows the receiver's history while its reader
		// types. CPU is Chromium's default 1x; enforce budgets on that profile.
		await alice.evaluate(() => {
			const probe =
				(globalThis as unknown as { responsiveness: { timings: number[]; inputs: number[] } }).responsiveness;
			probe.timings.length = 0;
			probe.inputs.length = 0;
		});
		hold = true;
		for (let i = 0; i < 64; i++) {
			await say(bob, `responsive-burst-${i}`);
			const sent = bob.locator(".bubble").filter({ hasText: `responsive-burst-${i}` });
			await sent.hover();
			await sent.getByLabel("More for this message", { exact: true }).click();
			await bob.getByRole("menuitem", { name: "Edit", exact: true }).waitFor();
			await bob.keyboard.press("Escape");
		}
		if (buffered.length === 0) fail("the burst did not intercept incoming transport frames");
		hold = false;
		await alice.bringToFront();
		for (const send of buffered.splice(0)) send();
		for (let i = 0; i < 24; i++) {
			await alice.fill("#line", `still typing ${i}`);
		}
		await awaitBubble(alice, "responsive-burst-63", "responsive-alice");
		await alice.waitForFunction(() =>
			(globalThis as unknown as { responsiveness: { inputs: number[] } }).responsiveness.inputs.length >= 24
		);
		const afterAnchor = await alice.locator("#log .bubble").first().evaluate((node) =>
			node.getBoundingClientRect().top
		);
		if (Math.abs(afterAnchor - anchor) > 1) fail(`incoming burst moved scroll anchor: ${anchor} -> ${afterAnchor}`);
		if (await alice.locator("#settingsTitle").isVisible()) fail("a late save reopened Settings");
		const screenshot = Deno.env.get("GLOWCAP_RESPONSIVENESS_SCREENSHOT");
		if (screenshot) await alice.screenshot({ path: screenshot });
		const result = await alice.evaluate(() => {
			const probe = (globalThis as unknown as {
				responsiveness: {
					errors: string[];
					timings: number[];
					inputs: number[];
					input: (event: Event) => void;
					bubbles: Map<string, Element>;
					observer: MutationObserver;
					long: PerformanceObserver;
				};
			}).responsiveness;
			probe.observer.disconnect();
			probe.long.disconnect();
			document.removeEventListener("input", probe.input);
			return {
				errors: probe.errors,
				longTasks: probe.timings,
				latency: probe.inputs,
				history: document.querySelectorAll(".bubble").length,
				tracked: probe.bubbles.size,
				focus: document.activeElement?.id,
			};
		});
		const bobErrors = await bob.evaluate(() =>
			(globalThis as unknown as { responsiveness: { errors: string[] } }).responsiveness.errors
		);
		if (result.errors.length || bobErrors.length) fail([...result.errors, ...bobErrors].join("; "));
		if (result.latency.length < 24) fail("the burst did not measure every real input event");
		if (Math.max(0, ...result.latency) > 100 || result.longTasks.some((ms) => ms > 50)) {
			fail(`responsiveness budgets exceeded: ${JSON.stringify(result)}`);
		}
		if (result.focus !== "line") fail("a background arrival moved composer focus");
		console.log(
			`RESPONSIVENESS ${
				JSON.stringify({
					browser: browser.version(),
					transport: `WebSocket /relay to ${transport}`,
					cpu: "1x",
					events: 64,
					peakTransportQueue: peak,
					maxInputMs: Math.max(...result.latency),
					...result,
				})
			}`,
		);
	} finally {
		for (const timer of timers) clearTimeout(timer);
		timers.clear();
		buffered.length = 0;
		await context.close();
		await bobContext.close();
		if (
			browser.contexts().includes(context) || browser.contexts().includes(bobContext) || timers.size ||
			buffered.length
		) {
			fail("responsiveness proof retained a context or transport callback");
		}
		console.log("RESPONSIVENESS retired: contexts=0 transportTimers=0 bufferedFrames=0");
	}
}
