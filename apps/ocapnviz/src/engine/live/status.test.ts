import { assertEquals } from "@std/assert";
import { liveFeedStatus } from "./status.ts";

Deno.test("liveFeedStatus: an empty field is idle, not connecting", () => {
	assertEquals(
		liveFeedStatus({ sturdyref: "", connection: "connecting", observed: false }),
		"idle",
	);
	assertEquals(
		liveFeedStatus({ sturdyref: "  ", connection: "connected", observed: true }),
		"idle",
	);
});

Deno.test("liveFeedStatus: a pasted sturdyref that has not opened is connecting", () => {
	assertEquals(
		liveFeedStatus({
			sturdyref: "ocapn://example",
			connection: "connecting",
			observed: false,
		}),
		"connecting",
	);
});

Deno.test("liveFeedStatus: open with nothing arrived is waiting, not connected", () => {
	assertEquals(
		liveFeedStatus({
			sturdyref: "ocapn://example",
			connection: "connected",
			observed: false,
		}),
		"waiting",
	);
});

Deno.test("liveFeedStatus: open after the first record is connected", () => {
	assertEquals(
		liveFeedStatus({
			sturdyref: "ocapn://example",
			connection: "connected",
			observed: true,
		}),
		"connected",
	);
});

Deno.test("liveFeedStatus: a link this page cannot dial is refused, not connecting", () => {
	assertEquals(
		liveFeedStatus({
			sturdyref: "ocapn://trace.example%3A9300.tcp/s/swiss",
			connection: "refused",
			observed: false,
		}),
		"refused",
	);
});

Deno.test("liveFeedStatus: a terminal failure stays stopped after records were observed", () => {
	assertEquals(
		liveFeedStatus({ sturdyref: "ocapn://key.tcp/s/swiss", connection: "stopped", observed: true }),
		"stopped",
	);
});
