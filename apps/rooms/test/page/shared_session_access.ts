// The production editor issues use separately from management, and lifecycle
// changes reach a view already holding the exact issued endpoint.
import type { Browser, Page } from "playwright";
import { Buffer } from "node:buffer";
import { managedAccessText as text, statusTag } from "../../lib/text/managed_access.ts";
import { managedSessionText } from "../../lib/text/managed_session.ts";
import { fail, say, waitForPostedLine } from "./harness.ts";
import { png } from "./png.ts";
import { namedRoomRow } from "../support/conversation_row.ts";

export async function proveManagedAccessEditor(browser: Browser, owner: Page, httpPort: number, control: string) {
	await owner.click("#settingsBtn");
	await owner.click("#sessionTab");
	await owner.click("#sessionAccessOpen");
	const access = owner.locator(".session-access-modal");
	await holdControl(owner, control);
	const controls = access.locator("li.entry")
		.filter({ has: owner.getByRole("button", { name: text.manage, exact: true }) });
	// Issuance appends another held control. Keep observing the original issuer.
	const held = controls.nth(await controls.count() - 1);
	await held.getByRole("button", { name: text.manage, exact: true }).waitFor();
	const viewport = owner.viewportSize();
	await owner.setViewportSize({ width: 320, height: 844 });
	const escaped = await access.locator(".entry-head .actions").evaluateAll((groups) =>
		groups.flatMap((group) => {
			const row = group.closest(".entry")!.getBoundingClientRect();
			return [...group.querySelectorAll("button")].flatMap((button) => {
				const box = button.getBoundingClientRect();
				return box.left < row.left - 1 || box.right > row.right + 1 ? [button.textContent] : [];
			});
		})
	);
	if (escaped.length !== 0) fail(`access actions escape their row on a phone: ${escaped.join(", ")}`);
	if (viewport != null) await owner.setViewportSize(viewport);
	await held.getByRole("button", { name: text.issueAsk, exact: true }).click();
	const issuing = owner.locator(".session-issue-modal");
	await owner.fill("#sessionAccessLabel", "Page observer");
	// The issuer keeps full management of what it creates; nothing here has to
	// be ticked for the new access to stay inspectable, editable and revocable.
	await issuing.getByRole("button", { name: text.create, exact: true }).click();
	const linkField = issuing.getByRole("button", { name: text.copyAccess, exact: true });
	await linkField.waitFor().catch(async () =>
		fail(`workspace issuance did not publish access: ${await issuing.innerText()}`)
	);
	const link = (await linkField.locator(".copy-field-text").textContent())?.trim() ?? "";
	if (!link.startsWith("ocapn://") || link === control) fail("editor did not publish separate workspace use");
	await issuing.getByRole("button", { name: text.done, exact: true }).click();
	await issuing.waitFor({ state: "hidden" });
	await held.getByRole("button", { name: text.issueAsk, exact: true }).waitFor().catch(() =>
		fail("a finished issuance left its control asking to resume it")
	);
	await access.locator("li.entry").filter({ hasText: "Page observer" }).waitFor({ timeout: 10_000 }).catch(
		async () => fail(`the issued access is not listed under its label: ${await access.innerText()}`),
	);
	const context = await browser.newContext();
	const observer = await context.newPage();
	try {
		await observer.goto(`http://127.0.0.1:${httpPort}/`);
		await observer.fill("#sessionSetupCapability", link);
		await Promise.all([observer.waitForNavigation(), observer.click("#sessionAttach")]);
		await observer.waitForSelector("#line[disabled]");
		await observer.locator("#roomList").getByText("mirror-one", { exact: true }).waitFor();
		await access.locator("li.entry").filter({ hasText: "Page observer" }).getByRole("button", {
			name: text.manage,
			exact: true,
		}).click();
		const editor = owner.locator(".session-grant-edit-modal");
		await owner.fill("#sessionGrantLabel", "Page reviewer");
		await editor.getByRole("button", { name: text.saveLabel, exact: true }).click();
		await editor.getByText(text.committedEdit, { exact: true }).waitFor();
		await owner.keyboard.press("Escape");
		await editor.waitFor({ state: "hidden" });
		const opener = access.locator("li.entry").filter({ hasText: "Page reviewer" }).getByRole("button", {
			name: text.manage,
			exact: true,
		});
		if (!await opener.evaluate((button) => button === document.activeElement)) {
			fail("closing the committed grant editor did not return focus to its Manage control");
		}
		await access.getByRole("button", { name: "Close", exact: true }).click();
		await owner.click("#settingsClose");
		await owner.reload();
		await owner.waitForSelector("#settingsBtn");
		await owner.locator("#roomList").getByText("mirror-one", { exact: true }).click();
		await owner.click("#settingsBtn");
		await owner.click("#sessionTab");
		await owner.click("#sessionAccessOpen");
		await access.locator("li.entry").filter({ hasText: "Page reviewer" }).getByRole("button", {
			name: text.manage,
			exact: true,
		}).click();
		// A shared control is a narrower one of its own; this one may also
		// change permissions, which a label edit needs.
		await editor.getByRole("checkbox", { name: text.shareEdit }).check();
		await editor.getByRole("button", { name: text.prepareControl, exact: true }).click();
		const controlField = editor.getByRole("button", { name: text.copyControl, exact: true });
		await controlField.waitFor();
		const childControl = (await controlField.locator(".copy-field-text").textContent())?.trim() ?? "";
		if (!childControl.startsWith("ocapn://") || childControl === link) {
			fail("management and workspace use were conflated");
		}
		// An observer can explicitly hold management without acquiring workspace
		// editing or custody powers from that management endpoint.
		await observer.click("#settingsBtn");
		await observer.click("#sessionTab");
		await observer.click("#sessionAccessOpen");
		const otherAccess = observer.locator(".session-access-modal");
		await otherAccess.getByText(text.noControl, { exact: true }).waitFor();
		await holdControl(observer, childControl);
		await otherAccess.getByRole("button", { name: text.manage, exact: true }).click();
		const otherEditor = observer.locator(".session-grant-edit-modal");
		await owner.fill("#sessionGrantLabel", "Preserved first draft");
		await observer.fill("#sessionGrantLabel", "Another viewer committed");
		await otherEditor.getByRole("button", { name: text.saveLabel, exact: true }).click();
		await otherEditor.getByText(text.committedEdit, { exact: true }).waitFor();
		await editor.getByRole("button", { name: text.saveLabel, exact: true }).click();
		await editor.getByRole("button", { name: text.reapply, exact: true }).waitFor();
		const nameEdit = editor.locator(".entry").filter({ has: owner.locator("#sessionGrantLabel") });
		await nameEdit.getByRole("button", { name: text.reapply, exact: true }).waitFor();
		await nameEdit.getByRole("button", { name: text.discard, exact: true }).waitFor();
		await nameEdit.getByText("Current name: Another viewer committed.", { exact: true }).waitFor();
		if (await owner.inputValue("#sessionGrantLabel") !== "Preserved first draft") {
			fail("conflict erased the label draft");
		}
		await editor.getByRole("button", { name: text.reapply, exact: true }).click();
		await editor.getByText(text.committedEdit, { exact: true }).waitFor();
		// Removing a live control from the list asks first, and lets go only of
		// the management: the access it managed keeps working below.
		await otherEditor.getByRole("button", { name: text.removeAsk, exact: true }).click();
		await otherEditor.getByRole("button", { name: text.remove, exact: true }).click();
		await otherEditor.waitFor({ state: "hidden" }).catch(async () =>
			fail(`removing a held control did not settle: ${await otherEditor.innerText()}`)
		);
		await otherAccess.getByText(text.noControl, { exact: true }).waitFor();
		await otherAccess.getByRole("button", { name: "Close", exact: true }).click();
		await observer.click("#settingsClose");
		await observer.locator("#roomList").getByText("mirror-one", { exact: true }).click();
		await editor.getByRole("radio", { name: /^Collaborator/ }).check();
		await editor.getByRole("button", { name: text.savePermissions, exact: true }).click();
		await observer.waitForSelector("#line:not([disabled])");
		await observer.fill("#line", "Collaborator draft");
		await owner.waitForFunction(() =>
			(document.querySelector("#line") as HTMLTextAreaElement)?.value === "Collaborator draft"
		).catch(async () => fail(`collaborator draft did not sync: ${await observer.locator("body").innerText()}`));
		await say(observer, "Posted with collaborator access");
		for (const page of [owner, observer]) {
			await page.locator(".bubble").filter({ hasText: "Posted with collaborator access" }).first().waitFor();
		}
		await waitForPostedLine(observer, "Posted with collaborator access");
		const posted = observer.locator(".row.mine .bubble").filter({ hasText: "Posted with collaborator access" });
		await posted.hover();
		await posted.getByLabel("More for this message", { exact: true }).click();
		await observer.getByRole("menuitem", { name: "Edit", exact: true }).click();
		await say(observer, "Edited with collaborator access");
		for (const page of [owner, observer]) {
			await page.locator(".bubble").filter({ hasText: "Edited with collaborator access" }).first().waitFor();
		}
		await observer.waitForSelector(".changing-bar", { state: "detached" });
		await observer.setInputFiles("#filePick", {
			name: "collaborator.png",
			mimeType: "image/png",
			buffer: Buffer.from(png),
		});
		await observer.waitForSelector('.composer-file:has-text("collaborator.png")');
		await say(observer, "Uploaded with collaborator access");
		await waitForPostedLine(observer, "Uploaded with collaborator access");
		await owner.locator(".bubble").filter({ hasText: "Uploaded with collaborator access" }).locator("img")
			.waitFor();
		const upload = observer.locator(".bubble").filter({ hasText: "Uploaded with collaborator access" });
		await upload.locator(".attach .why").filter({ hasText: "This access doesn't allow that action." }).waitFor();
		await say(observer, "After an unopened collaborator file");
		await owner.locator(".bubble").filter({ hasText: "After an unopened collaborator file" }).waitFor();
		await waitForPostedLine(observer, "After an unopened collaborator file");
		// Opening files is independent of participation. Granting it lets the
		// existing attachment retry its original selection without another post.
		await editor.getByRole("checkbox", { name: text.readFile, exact: true }).check();
		await editor.getByRole("button", { name: text.savePermissions, exact: true }).click();
		await editor.locator(".session-grant-permissions").getByText(text.committedEdit, { exact: true }).waitFor();
		await upload.getByRole("button", { name: /^Retry collaborator\.png,/ }).click();
		await upload.locator("img").waitFor();
		await observer.waitForFunction(() =>
			!document.querySelector(".draft-sync") &&
			(document.querySelector("#line") as HTMLTextAreaElement)?.value === ""
		).catch(async () => fail(`collaborator post did not complete: ${await observer.locator("body").innerText()}`));
		await editor.getByRole("radio", { name: /^Administrator/ }).check();
		await editor.getByRole("button", { name: text.savePermissions, exact: true }).click();
		await editor.locator(".session-grant-permissions").getByText(text.committedEdit, { exact: true }).waitFor();
		await proveNamedJoining(owner, observer);
		await editor.getByRole("radio", { name: /^Observer/ }).check();
		await editor.getByRole("radio", { name: /^None/ }).check();
		await editor.getByRole("button", { name: text.savePermissions, exact: true }).click();
		await observer.waitForSelector("#line[disabled]");
		await editor.getByRole("switch", { name: text.activeLabel, exact: true }).click();
		await observer.locator(".session-paused-notice").waitFor().catch(async () =>
			fail(
				`paused view did not settle: editor=${await editor.innerText()} observer=${await observer.locator(
					"body",
				).innerText()}`,
			)
		);
		await observer.reload();
		await observer.locator(".session-paused-notice").waitFor().catch(async () =>
			fail(`paused reload did not settle: ${await observer.locator("body").innerText()}`)
		);
		await editor.getByRole("switch", { name: text.activeLabel, exact: true }).click();
		await observer.locator(".session-paused-notice").waitFor({ state: "detached" });
		await observer.locator("#roomList").getByText("mirror-one", { exact: true }).waitFor();
		await editor.getByRole("button", { name: text.revokeAsk, exact: true }).click();
		await editor.getByRole("button", { name: text.revoke, exact: true }).click();
		await observer.getByText(managedSessionText.revoked, { exact: true }).waitFor();
		// Revoking takes the row off the list; the record stays under the
		// access it was created from, and the removal survives a reload.
		await editor.waitFor({ state: "hidden" }).catch(async () =>
			fail(`revoking did not take the access off the list: ${await editor.innerText()}`)
		);
		// The reapplied draft is the label this access ended with.
		const revoked = access.locator("li.entry").filter({ hasText: "Preserved first draft" });
		await revoked.waitFor({ state: "detached" });
		await owner.reload();
		await owner.waitForSelector("#settingsBtn");
		await owner.click("#settingsBtn");
		await owner.click("#sessionTab");
		await owner.click("#sessionAccessOpen");
		const issuer = access.locator("li.entry")
			.filter({ has: owner.getByRole("button", { name: text.issueAsk, exact: true }) }).last();
		await issuer.waitFor();
		if (await revoked.count() !== 0) fail("a removed control came back after reload");
		await issuer.getByRole("button", { name: text.manage, exact: true }).click();
		const record = editor.locator("li.entry").filter({ hasText: "Preserved first draft" });
		await record.getByText(statusTag.revoked, { exact: true }).waitFor().catch(async () =>
			fail(`the revoked access left no record under its issuer: ${await editor.innerText()}`)
		);
	} finally {
		await context.close();
	}
}

async function proveNamedJoining(owner: Page, visitor: Page): Promise<void> {
	const room = "shared-access-room";
	async function open() {
		await visitor.click("#newRoomBtn");
		await visitor.fill("#newRoomInput", room);
		await visitor.press("#newRoomInput", "Enter");
		await namedRoomRow(visitor, room, true, "membership-joined").waitFor({ timeout: 15_000 }).catch(async () =>
			fail(`named join through shared access failed: ${await visitor.locator("body").innerText()}`)
		);
		await visitor.waitForFunction((room) => {
			const line = document.querySelector<HTMLTextAreaElement>("#line");
			return document.querySelector("#roomName")?.textContent === room && line != null && !line.disabled;
		}, room);
	}
	async function leave() {
		await say(visitor, "/leave");
		await namedRoomRow(visitor, room, false, "membership-joined").waitFor({ state: "detached" });
	}
	// The directory belongs to the original session link. This viewer holds a
	// separately issued grant. Both absent-name creation and public readmission
	// must work without substituting the directory's initiating source.
	await open();
	await say(visitor, "Created through shared access");
	await waitForPostedLine(visitor, "Created through shared access");
	await leave();
	await open();
	await say(visitor, "Rejoined through shared access");
	await waitForPostedLine(visitor, "Rejoined through shared access");
	await namedRoomRow(owner, room, false, "membership-joined").waitFor();
	const screenshot = Deno.env.get("GLOWCAP_MANAGED_ACCESS_SCREENSHOT");
	if (screenshot != null) await visitor.screenshot({ path: screenshot, fullPage: true });
	await leave();
	await namedRoomRow(visitor, "mirror-one").click();
	await visitor.waitForSelector("#line:not([disabled])");
}

/** Open the hold card from Session access, hold `control` there, and wait for it to close. */
async function holdControl(tab: Page, control: string) {
	await tab.click("#sessionHoldOpen");
	const card = tab.locator(".session-hold-modal");
	await tab.fill("#sessionControlUri", control);
	await card.getByRole("button", { name: text.holdControl, exact: true }).click();
	await card.waitFor({ state: "hidden" }).catch(async () =>
		fail(`holding a management control did not settle: ${await card.innerText()}`)
	);
}
