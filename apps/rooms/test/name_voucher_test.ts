// When this app will present a name voucher, and — the part with something at
// stake — when it will not.
//
// A voucher is single-use bytes that prove the holder is a registered member,
// so presenting one is being that member on any connection. `enterRoom` may
// mint one when a room refuses a subscribe because the name is held, which is
// the ordinary case of the same reader arriving on a second connection. The
// rule about *which* rooms may receive one is `mayPresentNameVoucher`, and the
// clause that carries the weight is `trusted`: a room reached by name or
// redeemed from a link is the directory's own, while a room that arrived as a
// reference over a direct line is hosted by whoever handed it over — outside
// the directory's trust domain, and indistinguishable from a real room by
// looking at it.
//
// Pinned here rather than through the browser because the decision is a pure
// one taken on this side, before anything is sent. A scenario proof would
// mostly re-prove that the page threads a flag through; this states the rule
// itself, clause by clause.

import { mayPresentNameVoucher } from "../lib/limits.ts";
import { assertEquals } from "./assert.ts";

/** The case where the answer is yes: the ordinary second connection of a reader
 * whose name this directory granted, meeting a room it can prove is its own. */
const ordinary = {
	trusted: true,
	nickTaken: true,
	attempt: 0,
	presented: false,
	ownName: true,
};

Deno.test("a room the directory vouches for may be shown the voucher", () => {
	assertEquals(mayPresentNameVoucher(ordinary), true);
});

Deno.test("a room handed over from outside the directory is never shown one", () => {
	// The whole of the rule. Everything else about this attempt is the ordinary
	// case; only the provenance of the reference differs, and that alone is
	// enough to withhold the bytes.
	assertEquals(mayPresentNameVoucher({ ...ordinary, trusted: false }), false);
});

Deno.test("a voucher answers a held name, and nothing else", () => {
	// Some other refusal — the room is full, the name is unshowable — is not a
	// claim about who this reader is, so proving who they are answers nothing.
	assertEquals(mayPresentNameVoucher({ ...ordinary, nickTaken: false }), false);
});

Deno.test("only the first attempt presents one", () => {
	// A voucher the room did not accept will not be accepted twice, and each is
	// spent on presentation, so a retry that minted another would spend the
	// name's bounded supply to learn the same answer.
	assertEquals(mayPresentNameVoucher({ ...ordinary, attempt: 1 }), false);
	assertEquals(mayPresentNameVoucher({ ...ordinary, presented: true }), false);
});

Deno.test("a voucher is only for the name this directory granted", () => {
	// Asking for a name this directory never granted: the voucher proves the
	// registered name and would prove nothing about the one being claimed.
	assertEquals(mayPresentNameVoucher({ ...ordinary, ownName: false }), false);
});
