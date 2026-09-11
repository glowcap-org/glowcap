// The opening screen for a reader who has asked for less motion.
//
// Split from `opening.ts` by subject when that file outgrew the project's
// limit, the way `first_rail.ts` was.
import type { Browser } from "playwright";
import { fail } from "./harness.ts";

/** A reader who has asked for less motion gets an opening screen that sits
 * still and still gets the page. Both halves are worth holding, and the second
 * is the one nobody would find: the screen is taken out of the document when
 * its fade ends, a fade that same preference shortens to nothing, and were that
 * end never reported the screen would stay in the document for good.
 *
 * Stillness is proved by asking for motion rather than by looking for it. The
 * page answers this preference with one blanket rule in page.css that clamps
 * every animation to nothing, so reading the screen's own elements reports
 * stillness whatever anyone adds, and proves only that the rule works
 * somewhere. This gives the opening screen an animation of its own while the
 * screen is up, and holds that the page takes it away. Remove that rule and
 * this fails; add an animation to the splash and this still passes, which is
 * the right answer, because the reader still gets none.
 *
 * The mark answers the preference inside the shader's own loop, by holding one
 * settled frame, which no stylesheet can be asked about. An earlier version of
 * this named a piece of the drawing the shader replaced, found nothing, and
 * passed on the empty string. */
export async function proveOpeningWithoutMotion(browser: Browser, httpPort: number): Promise<void> {
	const still = await browser.newContext({ reducedMotion: "reduce" });
	const calm = await still.newPage();
	await calm.addInitScript(() => {
		const held = { name: "", duration: "", frames: 0, asked: false };
		(globalThis as unknown as { markMotion: typeof held }).markMotion = held;
		const sample = () => {
			const boot = document.querySelector("#boot");
			const named = boot?.querySelector(".boot-name");
			if (boot !== null && named != null) {
				// Asked the moment the screen is first seen, so the asking and
				// the reading share the same frames.
				if (!held.asked) {
					held.asked = true;
					const sheet = document.createElement("style");
					sheet.textContent = "@keyframes boot-motion-probe{from{opacity:.92}to{opacity:1}}" +
						".boot-name{animation:boot-motion-probe 2s linear infinite}";
					document.head.append(sheet);
				}
				const style = getComputedStyle(named);
				held.name = style.animationName;
				held.duration = style.animationDuration;
				held.frames++;
			}
			requestAnimationFrame(sample);
		};
		requestAnimationFrame(sample);
	});
	await calm.goto(`http://127.0.0.1:${httpPort}/`);
	await calm.waitForSelector("#boot", { state: "detached", timeout: 60_000 })
		.catch(() => fail("with less motion asked for, the opening screen never left the document"));
	const motion = await calm.evaluate(() =>
		(globalThis as unknown as { markMotion: { name: string; duration: string; frames: number } }).markMotion
	);
	// The asking has to have landed on the element being read, over more than
	// one frame, or the run measured the wrong moment rather than proving
	// anything about motion.
	if (motion.frames < 2 || motion.name !== "boot-motion-probe") {
		fail(
			`the opening screen was never asked for motion while it was up: ` +
				`${motion.frames} frames, animation ${motion.name || "none"}`,
		);
	}
	if (parseFloat(motion.duration) > 0.01) {
		fail(`with less motion asked for, the opening screen still runs an animation for ${motion.duration}`);
	}
	await still.close();
}
