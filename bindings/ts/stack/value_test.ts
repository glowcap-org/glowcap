import {
	CAPTP_NEXT,
	CAPTP_V1_0,
	CODEC_CAPNP,
	CODEC_SYRUP,
	FEATURE_FULL,
	FEATURE_HANDOFF,
	FEATURE_PIPELINING,
} from "@pancake/abi";
import { type CaptpVersion, captpVersionId, type Codec, codecId, featureMask } from "./value.ts";

function assertEquals(actual: unknown, expected: unknown): void {
	if (actual !== expected) {
		throw new Error(`expected ${String(expected)}, got ${String(actual)}`);
	}
}

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
		() => captpVersionId("pancake-future" as CaptpVersion),
		"unknown CapTP version pancake-future",
	);
	assertThrows(() => captpVersionId(0 as unknown as CaptpVersion), "unknown CapTP version 0");
});

Deno.test("featureMask composes known features and rejects unknown mask bits", () => {
	assertEquals(featureMask("full"), FEATURE_FULL);
	assertEquals(
		featureMask(FEATURE_PIPELINING + FEATURE_HANDOFF),
		FEATURE_PIPELINING + FEATURE_HANDOFF,
	);
	assertEquals(featureMask(["pipelining", "handoff"]), FEATURE_PIPELINING + FEATURE_HANDOFF);
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
