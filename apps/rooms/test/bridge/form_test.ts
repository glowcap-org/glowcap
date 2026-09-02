// What a bridge may and may not describe.
//
// A form is a peer's account of an interface, so these are mostly about what is
// refused. The shape that matters most is the one that cannot be written down
// at all: a reveal holds leaves, so a form has no depth to bound.

import {
	BridgeFieldSchema,
	type BridgeForm,
	bridgeFormFields,
	bridgeFormHasSecret,
	BridgeFormSchema,
	bridgeFormSecretIds,
	bridgeFormSubmission,
	splitBridgeSubmission,
} from "../../lib/bridge/form.ts";
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

Deno.test("a submission splits by the form's own declaration, not by the caller's memory", () => {
	const declared = z.parse(
		BridgeFormSchema,
		form({
			fields: [
				{ kind: "text", id: "nick", label: "IRC nick", required: true },
				{
					kind: "toggle",
					id: "registered",
					label: "Log in",
					on: false,
					reveals: [
						{ kind: "text", id: "account", label: "Account", required: true },
						{ kind: "secret", id: "password", label: "Password", required: true },
					],
				},
			],
		}),
	);
	// A secret behind a toggle is still a secret, so the ids come from the whole
	// walk rather than the top level.
	assertEquals([...bridgeFormSecretIds(declared)], ["password"]);
	const split = splitBridgeSubmission(bridgeFormSecretIds(declared), {
		nick: "ada",
		account: "ada",
		password: "hunter2",
	});
	assertEquals(split.answers, { nick: "ada", account: "ada" });
	assertEquals(split.secrets, { password: "hunter2" });
	// An answer the form never declared is not a secret, because only a
	// declaration makes one. It stays with the rest rather than being guessed at
	// by its name.
	assertEquals(splitBridgeSubmission(bridgeFormSecretIds(declared), { passphrase: "x" }).secrets, {});
	// A form that asks for nothing secret splits to nothing secret, which is what
	// lets a reconnect replay it with no custody at all.
	assertEquals(splitBridgeSubmission(bridgeFormSecretIds(z.parse(BridgeFormSchema, form())), { nick: "ada" }), {
		answers: { nick: "ada" },
		secrets: {},
	});
});

Deno.test("an action's submission carries only what the reader was asked", () => {
	const declared = z.parse(
		BridgeFormSchema,
		form({
			fields: [
				{ kind: "text", id: "nick", label: "IRC nick", required: true },
				{
					kind: "toggle",
					id: "registered",
					label: "Log in",
					on: false,
					reveals: [
						{ kind: "text", id: "account", label: "Account", required: true },
						{ kind: "secret", id: "password", label: "Password", required: true },
					],
				},
			],
			actions: [
				{ id: "link", label: "Link", busyLabel: "Linking…", tone: "primary", remembered: true },
				{ id: "disconnect", label: "Disconnect", busyLabel: "Disconnecting…", tone: "quiet", remembered: true },
			],
		}),
	);
	const [link, disconnect] = declared.actions;
	const typed = { nick: "ada", account: "ada", password: "hunter2" };

	// An off toggle keeps its reveals out, but its own state still travels: a
	// toggle is an answer, not only disclosure, and a bridge that treats one as a
	// value (IRC's TLS) reads its "on"/"" back rather than a silent absence.
	assertEquals(bridgeFormSubmission(declared, link, typed, new Set()), {
		answers: { nick: "ada", registered: "" },
		secrets: {},
	});
	// An on toggle asks its reveals, and the declaration routes the secret.
	assertEquals(bridgeFormSubmission(declared, link, typed, new Set(["registered"])), {
		answers: { nick: "ada", registered: "on", account: "ada" },
		secrets: { password: "hunter2" },
	});
	// A required visible field left empty refuses with its own label.
	assertEquals(
		bridgeFormSubmission(declared, link, { nick: "ada", account: "ada" }, new Set(["registered"])),
		{ why: "Password is required." },
	);
	// The quiet way out stands alone, so pressing it never sends a credential.
	assertEquals(bridgeFormSubmission(declared, disconnect, typed, new Set(["registered"])), {
		answers: {},
		secrets: {},
	});
});

Deno.test("a form's fields read as one list, revealed ones included", () => {
	const declared = z.parse(
		BridgeFormSchema,
		form({
			fields: [
				{ kind: "text", id: "nick", label: "IRC nick", required: true },
				{
					kind: "toggle",
					id: "registered",
					label: "Log in",
					on: false,
					reveals: [
						{ kind: "text", id: "account", label: "Account", required: true },
						{ kind: "secret", id: "password", label: "Password", required: true },
					],
				},
			],
		}),
	);
	// Revealed fields count whether or not the toggle is on: they are part of the
	// form either way, and what the toggle decides is whether a reader is asked.
	assertEquals(bridgeFormFields(declared).map((field) => field.id), [
		"nick",
		"registered",
		"account",
		"password",
	]);
	assertEquals(bridgeFormHasSecret(declared), true, "a password behind a toggle is still a password");
	assertEquals(bridgeFormHasSecret(z.parse(BridgeFormSchema, form())), false);
});
