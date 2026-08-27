// The hand-rolled Blake3 held to known answers.
//
// This digest has one job: produce the same bytes the Zig host computes with
// `std.crypto.hash.Blake3`, because an AID that does not match on both sides
// makes every identity in this application disagree. The cross-language demo
// proves that agreement by construction — the host re-derives the caller's AID
// and refuses a mismatch — but the demo is not on the ordinary gate, so this
// pins the primitive directly against vectors generated from that same Zig
// implementation, the empty-input one matching Blake3's universally published
// value.
//
// Validated against a defect: a one-swap change to MSG_PERMUTATION fails
// every vector here, so the vectors exercise the compression, not just the
// output length.

import { blake3 } from "./blake3.ts";

// A local assert, the way the task board's tests keep one, so this file adds no
// external test dependency the repo's lint would refuse.
function assertEquals(actual: unknown, expected: unknown, message?: string): void {
	if (actual !== expected) {
		throw new Error(`${message ?? "assertion failed"}: expected ${expected}, got ${actual}`);
	}
}

function hex(bytes: Uint8Array): string {
	return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const vectors: ReadonlyArray<readonly [string, string]> = [
	["", "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"],
	["abc", "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"],
	["pancake accountability", "d2364110bbf66fb4ffb92798642a4bc53064e5db15b26e4a916020d01d760bf9"],
];

Deno.test("blake3 matches the Zig host's digest, empty input included", () => {
	const encoder = new TextEncoder();
	for (const [input, expected] of vectors) {
		assertEquals(hex(blake3(encoder.encode(input))), expected, `blake3(${JSON.stringify(input)})`);
	}
});

Deno.test("blake3 spans the chunk boundary the same way", () => {
	// One byte past a 1024-byte chunk exercises the parent-node path a short
	// input never reaches. The input is Blake3's own test pattern (byte i is
	// i mod 251) and the expected value is that project's published length-1025
	// vector, so this pins the multi-chunk tree against the standard, not only
	// against the Zig host.
	const input = new Uint8Array(1025);
	for (let i = 0; i < input.length; i++) input[i] = i % 251;
	assertEquals(hex(blake3(input)), "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444");
});
