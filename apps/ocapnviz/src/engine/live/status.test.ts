import { assertEquals } from "@std/assert";
import { liveFeedStatus } from "./status.ts";

Deno.test("liveFeedStatus: an empty field is idle, not connecting", () => {
	assertEquals(
		liveFeedStatus({ sturdyref: "", connected: false, observed: false }),
		"idle",
	);
	assertEquals(
		liveFeedStatus({ sturdyref: "  ", connected: true, observed: true }),
		"idle",
	);
});

Deno.test("liveFeedStatus: a pasted sturdyref that has not opened is connecting", () => {
	assertEquals(
		liveFeedStatus({
			sturdyref: "ocapn://example",
			connected: false,
			observed: false,
		}),
		"connecting",
	);
});

Deno.test("liveFeedStatus: open with nothing arrived is waiting, not connected", () => {
	assertEquals(
		liveFeedStatus({
			sturdyref: "ocapn://example",
			connected: true,
			observed: false,
		}),
		"waiting",
	);
});

Deno.test("liveFeedStatus: open after the first record is connected", () => {
	assertEquals(
		liveFeedStatus({
			sturdyref: "ocapn://example",
			connected: true,
			observed: true,
		}),
		"connected",
	);
});
