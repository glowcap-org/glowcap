import {
	CAPTP_NEXT,
	CAPTP_V1_0,
	CODEC_CAPNP,
	CODEC_SYRUP,
	FEATURE_BASELINE,
	FEATURE_FULL,
	FEATURE_HANDOFF,
	FEATURE_MULTI_LOCATION,
	FEATURE_PIPELINING,
	FEATURE_UNTAG,
} from "@glowcap/abi";
import { type CaptpVersion, captpVersionId, type Codec, codecId, featureMask, refFromId } from "../value.ts";
import { assertEquals } from "../../dogfood/assert.ts";

function assertThrows(fn: () => unknown, message: string): void {
	try {
		fn();
	} catch (err) {
		if (err instanceof TypeError && err.message.includes(message)) return;
		throw new Error(`expected TypeError containing "${message}", got ${String(err)}`);
	}
	throw new Error(`expected TypeError containing "${message}"`);
}

Deno.test("codecId names only concrete built-in codecs", () => {
	assertEquals(codecId("syrup"), CODEC_SYRUP);
	assertEquals(codecId("capnp"), CODEC_CAPNP);
	assertThrows(() => codecId("unknown" as Codec), "unknown OCapN codec unknown");
	assertThrows(() => codecId(0 as unknown as Codec), "unknown OCapN codec 0");
});

Deno.test("captpVersionId names only concrete CapTP profiles", () => {
	assertEquals(captpVersionId("v1_0"), CAPTP_V1_0);
	assertEquals(captpVersionId("next"), CAPTP_NEXT);
	assertThrows(
		() => captpVersionId("glowcap-future" as CaptpVersion),
		"unknown CapTP version glowcap-future",
	);
	assertThrows(() => captpVersionId(0 as unknown as CaptpVersion), "unknown CapTP version 0");
});

Deno.test("featureMask composes known features and rejects unknown mask bits", () => {
	assertEquals(featureMask("full"), FEATURE_FULL);
	assertEquals(featureMask("baseline"), FEATURE_BASELINE);
	assertEquals(
		featureMask(FEATURE_PIPELINING + FEATURE_HANDOFF),
		FEATURE_PIPELINING + FEATURE_HANDOFF,
	);
	assertEquals(featureMask(["pipelining", "handoff"]), FEATURE_PIPELINING + FEATURE_HANDOFF);
	assertEquals(featureMask(["untag"]), FEATURE_UNTAG);
	assertEquals(featureMask(["multi_location"]), FEATURE_MULTI_LOCATION);
	assertThrows(() => featureMask(FEATURE_FULL + 1), "unknown OCapN feature mask");
	assertThrows(() => featureMask(-1), "unknown OCapN feature mask");
	assertThrows(() => featureMask(0x8000_0000), "unknown OCapN feature mask");
	assertThrows(() => featureMask(0xffff_ffff), "unknown OCapN feature mask");
	assertThrows(() => featureMask(0x1_0000_0000), "unknown OCapN feature mask");
	assertThrows(
		() => featureMask(0x1_0000_0000 + FEATURE_PIPELINING),
		"unknown OCapN feature mask",
	);
});

Deno.test("Ref equality follows opaque Host identity, not wrapper occurrence", () => {
	const first = refFromId(17n);
	const repeated = refFromId(17n);
	const other = refFromId(18n);
	assertEquals(first === repeated, false);
	assertEquals(first.equals(repeated), true);
	assertEquals(first.equals(other), false);
	first.markReleased();
	assertEquals(first.equals(repeated), true);
});
