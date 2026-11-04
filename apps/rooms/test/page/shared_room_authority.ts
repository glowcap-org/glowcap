import type { Page } from "playwright";
import { fail } from "../support/fail.ts";

/** Prove the attached path after its session peer restarted: the room was
 * realized through its durable entry link, yet revoking that entry authority status-allow: pending state or quoted runtime label
 * leaves the subscribed membership able to use its manager to replace it. */
export async function proveSharedRoomAuthorityRotation(
	page: Page,
	diagnose: () => Promise<unknown>,
): Promise<void> {
	await page.click("#roomAbout");
	await page.click("#convcardCapabilitiesTab").catch(async (error) =>
		fail(
			`the restarted room card has no capabilities tab: ${String(error)}; ${await page.locator("body")
				.innerText()}`,
		)
	);
	await page.waitForSelector("#convcardManager", { timeout: 30_000 })
		.catch(() => fail("the restarted attached room did not retain its manager capability"));
	const retiredLink = (await page.textContent("#convcardRoomLink"))?.trim() ?? "";
	await page.click("#convcardRoomLinkRevokeAsk");
	await page.getByRole("button", { name: "Revoke room authority" }).click();
	await page.waitForSelector("#convcardCreateRoomLink", { timeout: 30_000 })
		.catch(async () => {
			console.error("ROTATION-VIEW", await page.locator("body").innerText());
			fail("revoking an attached room entry link did not expose manager-backed reissue");
		});
	await page.click("#convcardCreateRoomLink");
	await page.waitForSelector("#convcardRoomLink", { timeout: 30_000 });
	const reissuedLink = (await page.textContent("#convcardRoomLink"))?.trim() ?? "";
	if (reissuedLink === "" || reissuedLink === retiredLink) {
		fail("the attached room manager did not create a fresh room-entry generation");
	}
	// A native click does not prove that the controller admitted a command.
	// Keep bounded input and panel-state evidence for the intermittent CI failure.
	const trace = await page.evaluateHandle(() => {
		const events: unknown[] = [];
		const inputs: unknown[] = [];
		let inputCount = 0;
		let dropped = 0;
		let panel = document.querySelector("#convcardCapabilitiesPanel");
		let generation = 0;
		let previous = "";
		const state = () => {
			const current = document.querySelector("#convcardCapabilitiesPanel");
			if (current !== panel) {
				panel = current;
				generation++;
			}
			const claim = document.querySelector<HTMLButtonElement>("#convcardStewardClaim");
			return {
				generation,
				panel: panel !== null,
				claim: claim?.textContent,
				disabled: claim?.disabled,
				manager: document.querySelector("#convcardManager") !== null,
				moderator: document.querySelector("#convcardSteward") !== null,
				refusal: document.querySelector("#convcardStewardSaid")?.textContent,
			};
		};
		const record = (event: unknown) => {
			if (events.length === 32) {
				events.shift();
				dropped++;
			}
			events.push(event);
		};
		const changed = () => {
			const current = state();
			const encoded = JSON.stringify(current);
			if (encoded !== previous) record({ kind: "state", ...current });
			previous = encoded;
		};
		const input = (event: Event) => {
			const target = event.target instanceof Element ? event.target : null;
			inputCount++;
			if (inputs.length === 8) return;
			inputs.push({
				kind: event.type,
				target: target?.id || target?.tagName,
				button: target?.closest("button")?.id,
				...state(),
			});
		};
		const kinds = ["pointerdown", "pointerup", "click"];
		for (const kind of kinds) document.addEventListener(kind, input, true);
		const observer = new MutationObserver(changed);
		observer.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
		changed();
		return {
			read: () => ({ inputs, inputCount, events, dropped, latest: state() }),
			close: () => {
				observer.disconnect();
				for (const kind of kinds) document.removeEventListener(kind, input, true);
			},
		};
	});
	let failure: { error: unknown } | null = null;
	try {
		await page.click("#convcardStewardClaim");
		await page.waitForSelector("#convcardSteward", { timeout: 30_000 }).catch(async (error: unknown) => {
			const input = await trace.evaluate((recording) => recording.read())
				.catch((error: unknown) => ({ traceError: String(error) }));
			console.error("ROOM-AUTHORITY-INPUT", JSON.stringify(input));
			const authority = await diagnose().catch((error: unknown) => ({ diagnosticError: String(error) }));
			fail(
				`the attached room manager did not recreate moderation after entry-link rotation; ${String(error)}; ${
					JSON.stringify({ input, authority })
				}; ${await page.locator("body").innerText()}`,
			);
		});
	} catch (error) {
		failure = { error };
	}
	try {
		try {
			await trace.evaluate((recording) => recording.close());
		} finally {
			await trace.dispose();
		}
	} catch (error) {
		if (failure == null) throw error;
		console.error("ROOM-AUTHORITY-TRACE-CLEANUP", String(error));
	}
	if (failure != null) throw failure.error;
	await page.click("#convcardClose");
}
