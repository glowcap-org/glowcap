// What a bridge may and may not describe.
//
// A form is a peer's account of an interface, so these are mostly about what is
// refused. The shape that matters most is the one that cannot be written down
// at all: a reveal holds leaves, so a form has no depth to bound.

import { BridgeFieldSchema, type BridgeForm, BridgeFormSchema } from "../../lib/bridge/form.ts";
import { MAX_FORM_ACTIONS, MAX_FORM_FIELDS, MAX_FORM_LABEL, MAX_FORM_VALUE } from "../../lib/limits.ts";
import { assertEquals } from "../assert.ts";
import * as z from "zod/mini";

const ok = (form: unknown) => z.safeParse(BridgeFormSchema, form).success;

function form(over: Partial<BridgeForm> = {}): unknown {
	return {
		scope: "libera",
		title: "Your libera identity",
		said: "Rooms only. You are not present on libera.",
		fields: [{ kind: "text", id: "nick", label: "IRC nick", required: true }],
		actions: [{ id: "link", label: "Link to IRC", busyLabel: "Linking…", tone: "primary", remembered: true }],
		...over,
	};
}

Deno.test("a bridge describes a form, and an unbounded one is refused", () => {
	assertEquals(ok(form()), true);
	assertEquals(ok(form({ title: "" })), false);
	assertEquals(ok(form({ actions: [] })), false, "a form with nothing to press is not a form");
	assertEquals(
		ok(form({
			actions: Array.from({ length: MAX_FORM_ACTIONS + 1 }, (_, at) => ({
				id: `a${at}`,
				label: "go",
				busyLabel: "going",
				tone: "primary" as const,
				remembered: false,
			})),
		})),
		false,
	);
	assertEquals(
		ok(form({ fields: [{ kind: "text", id: "n", label: "L".repeat(MAX_FORM_LABEL + 1), required: true }] })),
		false,
	);
	assertEquals(
		ok(form({
			fields: [{ kind: "text", id: "n", label: "n", value: "v".repeat(MAX_FORM_VALUE + 1), required: true }],
		})),
		false,
	);
	// An id names a field in a submission, so it is an identifier rather than
	// anything a bridge feels like sending.
	assertEquals(ok(form({ fields: [{ kind: "text", id: "Nick", label: "n", required: true }] })), false);
	assertEquals(ok(form({ fields: [{ kind: "text", id: "", label: "n", required: true }] })), false);
});

Deno.test("a secret has no starting value, because offering one would mean Rooms kept it", () => {
	assertEquals(ok(form({ fields: [{ kind: "secret", id: "pw", label: "Password", required: true }] })), true);
	assertEquals(
		z.safeParse(BridgeFieldSchema, {
			kind: "secret",
			id: "pw",
			label: "Password",
			required: true,
			value: "hunter2",
		})
			.success,
		false,
		"a secret was allowed to arrive prefilled",
	);
});

Deno.test("a reveal is one level deep, and deeper is unrepresentable rather than refused", () => {
	const registered = {
		kind: "toggle" as const,
		id: "registered",
		label: "Log in to a registered IRC account",
		on: false,
		reveals: [
			{ kind: "text" as const, id: "account", label: "Account", required: true },
			{ kind: "secret" as const, id: "password", label: "Password", required: true },
		],
	};
	assertEquals(ok(form({ fields: [registered] })), true);
	// A toggle inside a reveal does not typecheck and does not parse: the reveal
	// holds leaves. So there is no depth for a bridge to abuse and none for this
	// to bound at runtime.
	assertEquals(
		z.safeParse(BridgeFieldSchema, { ...registered, reveals: [registered] }).success,
		false,
		"a form grew a second level",
	);
	assertEquals(
		ok(form({
			fields: [{
				...registered,
				reveals: Array.from({ length: MAX_FORM_FIELDS + 1 }, (_, at) => ({
					kind: "text" as const,
					id: `f${at}`,
					label: "f",
					required: true,
				})),
			}],
		})),
		false,
	);
});

Deno.test("bridge refresh updates untouched defaults without revoking edits or retaining removed secrets", async () => {
	const { refreshBridgeAnswers, refreshBridgeToggles } = await import("../../web/ui/bridge_form.ts");
	const previous = form({
		fields: [
			{ kind: "text", id: "nick", label: "Nick", required: true, value: "before" },
			{ kind: "secret", id: "password", label: "Password", required: false },
			{ kind: "toggle", id: "account", label: "Account", on: true, reveals: [] },
		],
	}) as BridgeForm;
	const next = form({
		fields: [
			{ kind: "text", id: "nick", label: "Nick", required: true, value: "after" },
			{ kind: "toggle", id: "account", label: "Account", on: false, reveals: [] },
		],
	}) as BridgeForm;
	assertEquals(refreshBridgeAnswers(previous, next, { nick: "before", password: "secret" }), { nick: "after" });
	assertEquals(refreshBridgeAnswers(previous, next, { nick: "" }), { nick: "" });
	assertEquals(refreshBridgeAnswers(previous, next, { nick: "my edit" }), { nick: "my edit" });
	assertEquals([...refreshBridgeToggles(previous, next, new Set(["account"]))], []);
	assertEquals([...refreshBridgeToggles(next, previous, new Set(["account"]))], ["account"]);
});
