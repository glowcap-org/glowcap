import { assertEquals } from "@std/assert";
import { type Bound, explicitBound, implicitBound, withValue } from "./bound.ts";

Deno.test("implicitBound seeds value, explicit=false", () => {
	assertEquals(implicitBound(7), { value: 7, explicit: false });
	assertEquals(implicitBound(), { value: 0, explicit: false });
});

Deno.test("explicitBound seeds value, explicit=true", () => {
	assertEquals(explicitBound(5), { value: 5, explicit: true });
});

Deno.test("withValue sets value and marks explicit", () => {
	const b: Bound = { value: 0, explicit: false };
	assertEquals(withValue(b, 12), { value: 12, explicit: true });
});

Deno.test("withValue overrides a previously-explicit value", () => {
	const b: Bound = { value: 5, explicit: true };
	assertEquals(withValue(b, 8), { value: 8, explicit: true });
});
