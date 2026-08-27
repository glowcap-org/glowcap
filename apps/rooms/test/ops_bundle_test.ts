import { formatOpsBundle, opsBundleReady, parseOpsBundle, parseOpsBundleDraft } from "../web/ui/ops/bundle.ts";
import { assertEquals } from "./assert.ts";

Deno.test("the server capability block is accepted without its other output", () => {
	const parsed = parseOpsBundle(`
rooms: ready
ROOMS-VIZ-LISTENING ocapn://127.0.0.1.tcp/s/not-the-viz-swiss
ROOMS-ADMIN-LISTENERS listeners-swiss
ROOMS-DIAGNOSTICS diagnostics-swiss
ROOMS-IRC irc-swiss
ROOMS-OPERATOR operator-swiss
ROOMS-PEERING peering-swiss
ROOMS-VIZ viz-swiss
`);
	assertEquals([...parsed.keys()].join(","), "listeners,diagnostics,irc,operator,peering,viz");
	assertEquals(parsed.get("operator"), "operator-swiss");
});

Deno.test("the capability bundle controls and text edit one canonical draft", () => {
	const text = "ROOMS-DIAGNOSTICS diagnostics-swiss\nROOMS-OPERATOR operator-swiss";
	const draft = parseOpsBundleDraft(text);
	assertEquals(formatOpsBundle(draft), text);
	assertEquals(opsBundleReady(draft), true);
	const incomplete = parseOpsBundleDraft("ROOMS-OPERATOR");
	assertEquals(incomplete.has("operator"), true);
	assertEquals(incomplete.get("operator"), "");
	assertEquals(opsBundleReady(incomplete), false);
});

Deno.test("the editable capability bundle canonicalizes grammar whitespace without changing values", () => {
	const draft = parseOpsBundleDraft(
		"\n  ROOMS-DIAGNOSTICS   diagnostics-swiss  \n\tROOMS-OPERATOR\toperator-swiss\t\n",
	);
	assertEquals(formatOpsBundle(draft), "ROOMS-DIAGNOSTICS diagnostics-swiss\nROOMS-OPERATOR operator-swiss");
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
