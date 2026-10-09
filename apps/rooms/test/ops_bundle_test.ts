// Capability bundles keep one canonical editable draft and never silently discard labelled values.
import "./support/browser_application.ts";
import { formatOpsBundle, opsBundleReady, parseOpsBundle, parseOpsBundleDraft } from "../web/ui/ops/bundle.ts";
import { assertEquals } from "./assert.ts";

Deno.test("the server capability block is accepted without its other output", () => {
	const parsed = parseOpsBundle(`
rooms: ready
ROOMS-TRACE-LISTENING ocapn://127.0.0.1.tcp/s/not-the-trace-swiss
ROOMS-ADMIN-LISTENERS ocapn://127.0.0.1%3A1234.tcp/s/listeners-swiss
ROOMS-DIAGNOSTICS ocapn://127.0.0.1%3A1234.tcp/s/diagnostics-swiss
ROOMS-IRC ocapn://127.0.0.1%3A1234.tcp/s/irc-swiss
ROOMS-OPERATOR ocapn://127.0.0.1%3A1234.tcp/s/operator-swiss
ROOMS-PEERING ocapn://127.0.0.1%3A1234.tcp/s/peering-swiss
ROOMS-TRACE ocapn://127.0.0.1%3A1234.tcp/s/trace-swiss
`);
	assertEquals([...parsed.keys()].join(","), "listeners,diagnostics,irc,operator,peering,trace");
	assertEquals(parsed.get("operator"), "ocapn://127.0.0.1%3A1234.tcp/s/operator-swiss");
});

Deno.test("the capability bundle controls and text edit one canonical draft", () => {
	const text =
		"ROOMS-DIAGNOSTICS ocapn://127.0.0.1%3A1234.tcp/s/diagnostics-swiss\nROOMS-OPERATOR ocapn://127.0.0.1%3A1234.tcp/s/operator-swiss";
	const draft = parseOpsBundleDraft(text);
	assertEquals(formatOpsBundle(draft), text);
	assertEquals(opsBundleReady(draft), true);
	const incomplete = parseOpsBundleDraft("ROOMS-OPERATOR");
	assertEquals(incomplete.has("operator"), true);
	assertEquals(incomplete.get("operator"), "");
	assertEquals(opsBundleReady(incomplete), false);
	const unfinished = new Map([["operator" as const, "value with spaces"]]);
	let refused = false;
	try {
		formatOpsBundle(unfinished);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(opsBundleReady(unfinished), false);
});

Deno.test("the editable capability bundle canonicalizes grammar whitespace without changing values", () => {
	const draft = parseOpsBundleDraft(
		"\n  ROOMS-DIAGNOSTICS   ocapn://127.0.0.1%3A1234.tcp/s/diagnostics-swiss  \n\tROOMS-OPERATOR\tocapn://127.0.0.1%3A1234.tcp/s/operator-swiss\t\n",
	);
	assertEquals(
		formatOpsBundle(draft),
		"ROOMS-DIAGNOSTICS ocapn://127.0.0.1%3A1234.tcp/s/diagnostics-swiss\nROOMS-OPERATOR ocapn://127.0.0.1%3A1234.tcp/s/operator-swiss",
	);
});

Deno.test("the editable capability bundle refuses text it would have to drop", () => {
	for (const raw of ["rooms: ready", "ROOMS-OPERATOR one extra", "ROOMS-OPERATOR one\nROOMS-OPERATOR two"]) {
		let refused = false;
		try {
			parseOpsBundleDraft(raw);
		} catch {
			refused = true;
		}
		assertEquals(refused, true);
	}
});

Deno.test("a capability block never silently changes or drops a labelled value", () => {
	for (
		const raw of [
			"ROOMS-OPERATOR one\nROOMS-OPERATOR two",
			"ROOMS-UNKNOWN value",
			"ROOMS-OPERATOR",
			"ROOMS-OPERATOR one extra",
		]
	) {
		let refused = false;
		try {
			parseOpsBundle(raw);
		} catch {
			refused = true;
		}
		assertEquals(refused, true);
	}
});
