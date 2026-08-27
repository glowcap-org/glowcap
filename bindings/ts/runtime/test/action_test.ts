import { answerGiftId } from "../action.ts";
import { assert } from "../../dogfood/assert.ts";

Deno.test("gift-id completion reports only entropy failure", () => {
	const entropyFailure = new Error("entropy unavailable");
	let failed = 0;
	answerGiftId(
		() => {
			throw entropyFailure;
		},
		() => {
			throw new Error("entropy failure reached provide");
		},
		() => failed++,
	);
	assert(failed === 1, "entropy failure did not complete the ticket as failed");
});

Deno.test("gift-id completion preserves a provide refusal", () => {
	const refusal = new Error("ticket refused");
	let failed = 0;
	let observed: unknown = null;
	try {
		answerGiftId(
			() => new Uint8Array(32),
			() => {
				throw refusal;
			},
			() => failed++,
		);
	} catch (error) {
		observed = error;
	}
	assert(observed === refusal, "provide refusal identity changed");
	assert(failed === 0, "provide refusal was misreported as entropy failure");
});
