// Measure the outgoing cover and the incoming opening screen in their own
// documents. A blank cover can never satisfy the outgoing measurement.
import type { Page } from "playwright";
import { bootOpeningSession } from "../../lib/text/session.ts";

export async function watchAttachHandoff(page: Page): Promise<() => Promise<void>> {
	const key = "proof.attach-handoff";
	function sample({ key, phase, note }: { key: string; phase: "leaving" | "opening"; note?: string }) {
		const check = () => {
			const wait = document.querySelector(".boot-wait");
			if (document.documentElement?.dataset.boot !== phase || !wait) return;
			const box = wait.getBoundingClientRect();
			if (!box.width || !box.height || getComputedStyle(wait.parentElement!).position !== "fixed") return;
			if (phase === "leaving") {
				if (wait.querySelector(".boot-why")) throw new Error("The handoff repeated an earlier startup failure");
				const dialog = wait.closest("dialog:modal");
				const status = wait.querySelector('[role="status"]');
				if (
					!dialog?.contains(document.activeElement) || !status?.id ||
					dialog.getAttribute("aria-labelledby") !== status.id || status.textContent !== note
				) return;
				const line = status.getBoundingClientRect();
				if (!status.contains(document.elementFromPoint(line.x + line.width / 2, line.y + line.height / 2))) {
					return;
				}
			}
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
	await page.addInitScript(sample, { key, phase: "opening" as const });
	await page.evaluate(sample, { key, phase: "leaving" as const, note: bootOpeningSession });
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

/** A saved tab identity that the browser cannot use refuses before selecting
 * a workspace. The keyboard user returns to the same, correctable form. */
export async function proveRefusedAttachFocus(page: Page): Promise<void> {
	await page.evaluate(() => sessionStorage.setItem("rooms.managed-tab", "invalid/tab"));
	const attach = page.locator("#sessionAttach");
	await attach.focus();
	await attach.press("Enter");
	await page.locator("#sessionSetupCapabilitySaid").waitFor();
	await page.waitForFunction(() => document.activeElement?.id === "sessionAttach");
	await page.evaluate(() => sessionStorage.removeItem("rooms.managed-tab"));
}
