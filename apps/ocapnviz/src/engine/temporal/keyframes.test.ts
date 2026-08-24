import { assertEquals } from "@std/assert";
import { keyframeAt, type KeyframeTrack, removeKeyframe, setKeyframe } from "./keyframes.ts";

const stateTrack: KeyframeTrack<string> = [
	{ t: 0, value: "negotiating" },
	{ t: 10, value: "open" },
	{ t: 15, value: "draining" },
];

Deno.test("keyframeAt: empty / undefined track returns undefined", () => {
	assertEquals(keyframeAt(undefined, 5), undefined);
	assertEquals(keyframeAt<string>([], 5), undefined);
});

Deno.test("keyframeAt: t before first keyframe returns undefined", () => {
	assertEquals(keyframeAt(stateTrack, -1), undefined);
});

Deno.test("keyframeAt: exact boundary returns the NEW value (half-open)", () => {
	assertEquals(keyframeAt(stateTrack, 0), "negotiating");
	assertEquals(keyframeAt(stateTrack, 10), "open");
	assertEquals(keyframeAt(stateTrack, 15), "draining");
});

Deno.test("keyframeAt: just-before-boundary returns the PRIOR value", () => {
	assertEquals(keyframeAt(stateTrack, 9.999), "negotiating");
	assertEquals(keyframeAt(stateTrack, 14.999), "open");
});

Deno.test("keyframeAt: well past the last keyframe stays on the last value", () => {
	assertEquals(keyframeAt(stateTrack, 99), "draining");
});

Deno.test("setKeyframe: insert into empty track", () => {
	assertEquals(setKeyframe<string>(undefined, 5, "foo"), [
		{ t: 5, value: "foo" },
	]);
});

Deno.test("setKeyframe: insert preserves sort order", () => {
	const inserted = setKeyframe(stateTrack, 5, "negotiating");
	assertEquals(inserted.map((k) => k.t), [0, 5, 10, 15]);
});

Deno.test("setKeyframe: replace at existing t (last write wins)", () => {
	const replaced = setKeyframe(stateTrack, 10, "closed");
	assertEquals(replaced.find((k) => k.t === 10)?.value, "closed");
	assertEquals(replaced.length, 3);
});

Deno.test("setKeyframe: append after last", () => {
	const appended = setKeyframe(stateTrack, 20, "closed");
	assertEquals(appended[appended.length - 1], { t: 20, value: "closed" });
});

Deno.test("removeKeyframe: filters at exact t, no-op otherwise", () => {
	const removed = removeKeyframe(stateTrack, 10);
	assertEquals(removed.length, 2);
	assertEquals(removed.find((k) => k.t === 10), undefined);

	const noop = removeKeyframe(stateTrack, 999);
	assertEquals(noop.length, stateTrack.length);
});
