// Presentation checks wait for finite transitions, while ambient motion keeps running.
import type { Page } from "playwright";

export async function waitForFiniteAnimations(page: Page): Promise<void> {
	await page.waitForFunction(
		() =>
			document.getAnimations().every((animation) =>
				animation.effect?.getTiming().iterations === Infinity ||
				animation.playState === "finished" || animation.playState === "idle"
			),
		undefined,
		{ timeout: 10_000 },
	);
}
