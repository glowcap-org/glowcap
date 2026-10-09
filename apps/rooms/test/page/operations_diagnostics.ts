import type { Page } from "playwright";
import { fail } from "./harness.ts";
import { takeCapability } from "./capability_set.ts";
import { opsDiagnosticsLabel } from "../../lib/text/ops.ts";

/**
 * Take diagnostics from an active listeners pane, prove its read-only outcome
 * and retained browser failure journal, then return to listeners.
 */
export async function takeAndInspectDiagnostics(tab: Page, diagnosticsSwiss: string): Promise<void> {
	await tab.click("#settingsBtn");
	await tab.waitForSelector("#settingsTitle");
	await tab.click("#holdingsTab");
	await tab.waitForSelector("#holdingsPanel", { state: "attached" });
	await takeCapability(tab, "#opsDiagnosticsToggle", diagnosticsSwiss);
	await tab.waitForSelector("#holdingsPanel", { state: "attached" });
	await tab.click("#opsBtn");
	await tab.waitForSelector("#opsNav");
	await tab.click("#directoryOpsLink");
	await tab.waitForFunction(() => location.pathname === "/ops/directory");

	// Inspect reads the directory's inventories under the operator's own
	// headings, so a holder of either capability lands on one page. What it
	// cannot do is act, so the pane draws no control at all rather than a
	// disabled one.
	await tab.waitForFunction(
		() => {
			const named = [...document.querySelectorAll("#directoryOpsPanel .entry-name")]
				.map((row) => row.textContent ?? "");
			return named.includes("directory");
		},
		undefined,
		{ timeout: 10_000 },
	).catch(() => fail("the diagnostics pane did not name the published bootstrap"));
	const inspectShape = await tab.evaluate(() => {
		const panel = document.getElementById("directoryOpsPanel");
		return {
			sections: [...(panel?.querySelectorAll(".ops-section .well-title") ?? [])]
				.map((title) => (title.textContent ?? "").replace(/\d+$/, "").trim()),
			// Everything pressable outside the head. The head's own control
			// re-reads the directory, which is the one thing inspect may do.
			acts: [...(panel?.querySelectorAll("button, input, select, textarea") ?? [])]
				.filter((control) => control.closest(".ops-head") === null).length,
		};
	});
	for (const heading of ["Room access", "Connections and live references", "Room moderator authority"]) {
		if (!inspectShape.sections.includes(heading)) {
			fail(`the diagnostics pane did not report ${heading}: ${JSON.stringify(inspectShape)}`);
		}
	}
	if (inspectShape.acts !== 0) {
		fail(`the diagnostics pane offered a control that acts: ${JSON.stringify(inspectShape)}`);
	}

	// Browser-only trouble stands beside the directory's holdings when there is
	// something to inspect. This journey rejected a stale diagnostics link
	// before acquiring the current one. Its exact refusal remains here after
	// repairing the draft, independently of the server's operator journal.
	// One well owns the whole bounded journal; an empty one is never drawn.
	const browserTrouble = tab.locator("#pageTrouble");
	if (await browserTrouble.count() !== 1) {
		fail("browser trouble did not draw as one journal well");
	}
	const browserTroubleText = await browserTrouble.textContent() ?? "";
	if (
		!browserTroubleText.includes(opsDiagnosticsLabel) ||
		!browserTroubleText.includes("does not recognize that swiss number")
	) {
		fail(`the browser journal lost the stale-capability outcome: ${JSON.stringify(browserTroubleText)}`);
	}

	await tab.click("#listenersOpsLink");
	await tab.waitForSelector("#listenersList");
}
