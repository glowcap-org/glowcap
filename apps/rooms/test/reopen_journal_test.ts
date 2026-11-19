// Unit boundary for the reopen proof's projection of OperatorPane's rendered
// journal. The browser journey exercises the real grant and panel.
import { projectJournal } from "./support/reopen_journal.ts";
import { assertEquals } from "./assert.ts";

function row(note: string, source = "Managed signaling", folded?: string) {
	const fields: Record<string, string | undefined> = {
		".ops-kind": source,
		".ops-note": note,
		".ops-trouble-count": folded,
	};
	return {
		querySelector: (selector: string) => fields[selector] === undefined ? null : { textContent: fields[selector] },
	};
}

function panel(rows: ReturnType<typeof row>[]) {
	return { querySelectorAll: (selector: string) => selector === "#pageTrouble li" ? rows : [] };
}

Deno.test("the reopen journal projects only local-answer envelopes on Managed signaling rows", () => {
	const bridge = "browser channel: JsValue(";
	const answer = bridge + "OperationError: Failed to set local answer sdp: ";
	const jsep = answer + "Failed to apply the description for m= section with mid='private': ";
	const data = "Failed to create data channel.";
	const rows = [
		row(answer + data, "Managed signaling changes"),
		row(answer + data, "Managed signaling", "×3"),
		row(bridge + "InvalidStateError: Failed to set local answer sdp: Called in wrong state: stable)"),
		row(jsep + "Invalid ICE parameters: private"),
		row(jsep + "Answerer must be passive when offerer is active"),
		row(jsep + "other private detail"),
		row(bridge + "OperationError: Failed to set remote answer sdp: " + data),
		row("InvalidStateError: Called in wrong state: stable"),
		row(answer + "other private detail"),
		row("unrelated note quoting " + answer + data),
	];
	assertEquals(projectJournal(panel(rows)), {
		retainedRows: rows.length,
		atCapacity: false,
		managed: [
			{ reason: "answer-data-channel-creation", count: 3 },
			{ reason: "answer-wrong-state", count: 1 },
			{ reason: "answer-ice-parameters", count: 1 },
			{ reason: "answer-dtls-role", count: 1 },
			{ reason: "answer-transport-application", count: 1 },
			{ reason: "unclassified", count: 1 },
			{ reason: "unclassified", count: 1 },
			{ reason: "unclassified", count: 1 },
			{ reason: "unclassified", count: 1 },
		],
	});
});

Deno.test("the reopen journal splits the known local-answer transport messages without returning their text", () => {
	const jsep = "browser channel: JsValue(OperationError: Failed to execute 'setLocalDescription' on " +
		"'RTCPeerConnection': Failed to set local answer sdp: Failed to apply the description for m= section with mid='0': ";
	const cases: Array<[string, string]> = [
		["Failed to setup RTCP mux.", "answer-rtcp-mux"],
		["Fingerprint provided but no identity available.", "answer-local-certificate-missing"],
		[
			"Local fingerprint does not match identity. Expected: sha-256 AA:BB Got: sha-256 CC:DD",
			"answer-local-fingerprint-mismatch",
		],
		["Applying an answer transport description without applying any offer.", "answer-transport-offer-missing"],
		["Local fingerprint supplied when caller didn't offer DTLS.", "answer-dtls-not-offered"],
		["Failed to set SSL role for the transport.", "answer-ssl-role"],
		["Failed to apply remote fingerprint.", "answer-remote-fingerprint"],
		["Failed to setup RTCP mux. extra", "answer-transport-application"],
		// The local-answer path calls VerifyCertificateFingerprint only when it has a fingerprint.
		["No fingerprint", "answer-transport-application"],
		["constructor", "answer-transport-application"],
	];
	const projected = projectJournal(panel(cases.map(([inner]) => row(jsep + inner + ")"))));
	assertEquals(projected.managed.map((observation) => observation.reason), cases.map(([, reason]) => reason));
	assertEquals(JSON.stringify(projected).includes("AA:BB"), false);
});

Deno.test("local answers can be installed after a remote offer or a local provisional answer", () => {
	const rows = ["have-remote-offer", "have-local-pranswer", "unknown"].map((state) =>
		row(`browser channel: JsValue(InvalidStateError: Failed to set local answer sdp: Called in wrong state: ${state})`)
	);
	assertEquals(projectJournal(panel(rows)).managed.map((observation) => observation.reason), [
		"unclassified",
		"unclassified",
		"unclassified",
	]);
});

Deno.test("a full journal can have lost evidence even when no retained row matches", () => {
	const rows = Array.from({ length: 50 }, () => row("Managed signaling", "Other"));
	assertEquals(projectJournal(panel(rows)), { retainedRows: 50, atCapacity: true, managed: [] });
	assertEquals(projectJournal(panel([])), { retainedRows: 0, atCapacity: false, managed: [] });
});
