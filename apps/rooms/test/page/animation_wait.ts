// A real browser proves finite transitions finish without stopping ambient motion.
import type { Browser } from "playwright";
import { waitForFiniteAnimations } from "../support/animations.ts";

export async function proveFiniteAnimationWait(browser: Browser): Promise<void> {
	const page = await browser.newPage();
	try {
		await page.setContent("<div id='finite'>fade</div><div id='ambient'>breath</div>");
		await page.evaluate(() => {
			document.querySelector("#finite")!.animate([{ opacity: 0 }, { opacity: 1 }], {
				duration: 250,
				fill: "forwards",
			});
			document.querySelector("#ambient")!.animate([{ opacity: 0.5 }, { opacity: 1 }], {
				duration: 1000,
				iterations: Infinity,
			});
		});
		await waitForFiniteAnimations(page);
		const correct = await page.evaluate(() =>
			document.querySelector("#finite")!.getAnimations()[0]?.playState === "finished" &&
			document.querySelector("#ambient")!.getAnimations()[0]?.playState === "running"
		);
		if (!correct) throw new Error("animation wait must finish the fade and preserve ambient motion");
	} finally {
		await page.close();
	}
}
