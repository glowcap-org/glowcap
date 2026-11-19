// Postmortem only. Each result describes one snapshot document's untimed Browser
// trouble journal. Adjacent repeats fold into a count and only 50 rows survive.
// Even a single retained refusal cannot identify which reopen produced it.
import type { Page } from "playwright";
import type { FailureReport } from "./reopen_capture.ts";
import { PAGE_CAPTURE_KEY, type PageSnapshot } from "./reopen_capture_page.ts";
import { within } from "./wait.ts";

interface JournalRow {
	querySelector(selector: string): { textContent: string | null } | null;
}

// Serialized into Chromium. Inspect source and reason separately and return
// only closed categories, counts and retention. Never return a row's text.
export function projectJournal(panel: { querySelectorAll(selector: string): ArrayLike<JournalRow> }) {
	// The Rust browser channel formats a refused promise as a JsValue. Chromium's
	// sdp_offer_answer.cc adds the local-answer prefix. Match the first line of
	// that envelope, so an unrelated note quoting an error stays unclassified.
	function classify(note: string) {
		const localAnswer =
			/^browser channel: JsValue\((InvalidStateError|OperationError): (?:Failed to execute 'setLocalDescription' on 'RTCPeerConnection': )?Failed to set local answer sdp: ([^\r\n]+)/
				.exec(note);
		if (!localAnswer) return "unclassified";
		const message = localAnswer[2].replace(/\)$/, "");
		if (localAnswer[1] === "InvalidStateError") {
			return /^Called in wrong state: (?:stable|have-local-offer|have-remote-pranswer|closed)$/.test(message)
				? "answer-wrong-state"
				: "unclassified";
		}
		if (message === "Failed to create data channel.") return "answer-data-channel-creation";
		const jsep = /^Failed to apply the description for m= section with mid='[^'\r\n]+': (.+)$/.exec(message);
		if (!jsep) return "unclassified";
		const inner = jsep[1];
		if (/^Invalid ICE parameters: ./.test(inner)) return "answer-ice-parameters";
		if (
			[
				"Answerer must be passive when offerer is active",
				"Answerer must be active when offerer is passive",
				"Offerer must use current negotiated role for setup attribute.",
				"Answerer must use either active or passive value for setup attribute.",
			].includes(inner)
		) return "answer-dtls-role";
		// Exact inner messages from jsep_transport.cc and dtls_transport.cc. The
		// fingerprint mismatch embeds both digests, so only its prefix is matched.
		const exact: Record<string, string> = {
			"Failed to setup RTCP mux.": "answer-rtcp-mux",
			"Fingerprint provided but no identity available.": "answer-local-certificate-missing",
			"Applying an answer transport description without applying any offer.": "answer-transport-offer-missing",
			"Local fingerprint supplied when caller didn't offer DTLS.": "answer-dtls-not-offered",
			"Failed to set SSL role for the transport.": "answer-ssl-role",
			"Failed to apply remote fingerprint.": "answer-remote-fingerprint",
		};
		if (Object.hasOwn(exact, inner)) return exact[inner];
		if (inner.startsWith("Local fingerprint does not match identity. Expected: ")) {
			return "answer-local-fingerprint-mismatch";
		}
		return "answer-transport-application";
	}

	const rows = panel.querySelectorAll("#pageTrouble li");
	const retainedRows = Math.min(rows.length, 50);
	const managed = [];
	for (let i = 0; i < retainedRows; i++) {
		const row = rows[i];
		if (row.querySelector(".ops-kind")?.textContent !== "Managed signaling") continue;
		const reason = classify(row.querySelector(".ops-note")?.textContent ?? "");
		const folded = row.querySelector(".ops-trouble-count")?.textContent;
		const count = folded == null ? 1 : /^×[1-9]\d*$/.test(folded) ? Number(folded.slice(1)) : NaN;
		managed.push({ reason, count: Number.isSafeInteger(count) ? count : null });
	}
	return { retainedRows, atCapacity: retainedRows === 50, managed };
}

// This function runs in the main document. The capture already assigned it
// an install ID before any application script ran.
function documentId(_: Element, key: string) {
	return (Reflect.get(globalThis, key) as { snapshot(): PageSnapshot } | undefined)?.snapshot().installId;
}

async function readJournal(
	page: Page,
	origin: string,
	installId: string,
	operator: () => Promise<string>,
	remaining: () => number,
) {
	// Keep every UI action scoped to the captured document. A navigation may
	// detach its controls, but it cannot redirect a credential fill to a new page.
	const doc = await page.locator("html").elementHandle({ timeout: remaining() });
	const id = () => page.locator("html").evaluate(documentId, PAGE_CAPTURE_KEY, { timeout: remaining() });
	try {
		const matches = await doc.evaluate(documentId, PAGE_CAPTURE_KEY);
		if (!matches) return { status: "unavailable" };
		if (matches !== installId) return { status: "replaced" };
		if (await doc.evaluate(() => location.origin) !== origin) return { status: "unavailable" };
		const control = (selector: string) => doc.waitForSelector(selector, { state: "visible", timeout: remaining() });
		const click = async (selector: string) => (await control(selector)).click({ timeout: remaining() });
		if (!await doc.$("#settingsTitle")) await click("#settingsBtn");
		await click("#holdingsTab");
		await click("#opsOperatorToggle");
		const field = await control("#capabilityValueUri");
		const uri = await operator();
		remaining();
		// Submit through this field's controlled React form. Both the write and
		// submit address its own DOM nodes independently of keyboard focus.
		const submitted = await field.evaluate((input, { origin, installId, key, uri }) => {
			const capture = Reflect.get(globalThis, key) as { snapshot(): PageSnapshot } | undefined;
			if (
				location.origin !== origin || capture?.snapshot().installId !== installId ||
				!(input instanceof HTMLInputElement) || input.ownerDocument !== document || !input.isConnected ||
				input !== document.getElementById("capabilityValueUri") || !input.form
			) return false;
			const form = input.form;
			const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
			if (!setValue) return false;
			setValue.call(input, uri);
			input.dispatchEvent(new Event("input", { bubbles: true }));
			form.requestSubmit();
			return true;
		}, { origin, installId, key: PAGE_CAPTURE_KEY, uri });
		if (!submitted) return { status: "unavailable" };
		await click("#opsCapabilitySetSave");
		await control("#opsCapabilitySetSaved");
		await click("#opsBtn");
		await click("#operatorOpsLink");
		const panel = await control("#operatorOpsPanel");
		const journal = await panel.evaluate(projectJournal);
		const current = await id();
		if (!current) return { status: "unavailable" };
		return current === installId ? { status: "read", ...journal } : { status: "replaced" };
	} catch {
		const current = await id().catch(() => undefined);
		return { status: current && current !== installId ? "replaced" : "unavailable" };
	}
}

/** Only live direct tabs have a journal to ask. Every tab shares the same
 * five-second budget, including the server announcement and browser reads.
 * The caller tears down Chromium immediately after this last failure report. */
export async function reportReopenJournals(
	snapshot: FailureReport,
	origin: string,
	pages: Array<[string, Page]>,
	getOperator: (ms: number) => Promise<string>,
): Promise<void> {
	const deadline = performance.now() + 5_000;
	const remaining = () => {
		const ms = Math.ceil(deadline - performance.now());
		if (ms <= 0) throw new Error("postmortem deadline");
		return ms;
	};
	let operator: Promise<string> | undefined;
	const credential = () => operator ??= getOperator(remaining());
	await Promise.all(pages.map(async ([tab, page]) => {
		const original = snapshot.tabs.find((report) => report.name === tab && report.mode === "webrtc");
		if (!original || page.isClosed()) return;
		page.removeAllListeners("console");
		page.removeAllListeners("pageerror");
		const installId = original.page?.installId;
		const install = original.documents.retained.findIndex((document) => document.installId === installId);
		const snapshotDocument = install < 0 ? null : original.documents.evicted + install + 1;
		let observation: { status: string } = { status: "unavailable" };
		if (installId) {
			try {
				observation = await within(
					readJournal(page, origin, installId, credential, remaining),
					"browser trouble",
					remaining(),
				);
			} catch {
				// tolerant: an unanswered read contributes no journal evidence.
			}
		}
		console.error(`  [reopen journal] ${JSON.stringify({ tab, snapshotDocument, ...observation })}`);
	}));
}
