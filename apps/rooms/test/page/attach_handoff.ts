// Measure the outgoing cover and the incoming opening screen in their own
// documents. A blank cover can never satisfy the outgoing measurement.
import type { Page } from "playwright";

export async function watchAttachHandoff(page: Page): Promise<() => Promise<void>> {
	const key = "proof.attach-handoff";
	function sample({ key, phase }: { key: string; phase: "leaving" | "opening" }) {
		const check = () => {
			const wait = document.querySelector(".boot-wait");
			if (document.documentElement?.dataset.boot !== phase || !wait) return;
			const box = wait.getBoundingClientRect();
			if (!box.width || !box.height || getComputedStyle(wait.parentElement!).position !== "fixed") return;
			sessionStorage.setItem(
				key + phase,
				JSON.stringify({
					x: box.x + box.width / 2 - innerWidth / 2,
					y: box.y + box.height / 2 - innerHeight / 2,
				}),
			);
			observer.disconnect();
		};
		const observer = new MutationObserver(check);
		observer.observe(document, {
			childList: true,
			subtree: true,
			attributes: true,
			attributeFilter: ["data-boot"],
		});
		check();
	}
	await page.addInitScript(sample, { key, phase: "opening" });
	await page.evaluate(sample, { key, phase: "leaving" });
	return async () => {
		for (const phase of ["leaving", "opening"]) {
			const raw = await page.evaluate((k) => sessionStorage.getItem(k), key + phase);
			if (!raw) throw new Error(`Attach showed no loader during ${phase}`);
			const { x, y } = JSON.parse(raw);
			if (Math.abs(x) > 2 || Math.abs(y) > 2) {
				throw new Error(`Attach loader was off center during ${phase} by ${x}, ${y}px`);
			}
		}
	};
}
