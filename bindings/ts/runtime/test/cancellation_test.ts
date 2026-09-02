import { INTERNAL } from "@glowcap/abi";
import { takeRuntimeFailures } from "../context.ts";
import { abortable } from "../internal/cancellation.ts";
import { assertEquals } from "../../dogfood/assert.ts";

Deno.test("abortable reports an asynchronous late-owner refusal exactly once", async () => {
	const controller = new AbortController();
	controller.abort();
	let publish!: (value: object) => void;
	const pending = new Promise<object>((resolve) => publish = resolve);
	const cleanupFailure = new Error("late close refused");
	const observed: unknown[] = [];

	await abortable(
		pending,
		controller.signal,
		(error) => observed.push(error),
		() => Promise.reject(cleanupFailure),
	).then(
		() => {
			throw new Error("cancelled operation resolved");
		},
		() => {},
	);
	publish({});
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(observed.length, 1);
	assertEquals(observed[0], cleanupFailure);
});

Deno.test("abortable preserves cleanup and diagnostic-observer failures in the process seam", async () => {
	takeRuntimeFailures();
	const controller = new AbortController();
	controller.abort();
	let publish!: (value: object) => void;
	const pending = new Promise<object>((resolve) => publish = resolve);
	const cleanupFailure = new Error("late close refused");
	const observerFailure = new Error("observer refused");

	await abortable(
		pending,
		controller.signal,
		() => {
			throw observerFailure;
		},
		() => {
			throw cleanupFailure;
		},
	).catch(() => {});
	publish({});
	await new Promise((resolve) => setTimeout(resolve, 0));
	const failures = takeRuntimeFailures();
	assertEquals(failures.length, 2);
	assertEquals(failures[0].operation, "abortable.late-cleanup.diagnostic");
	assertEquals(failures[0].primaryResult, INTERNAL);
	assertEquals(failures[0].primaryMessage, cleanupFailure.message);
	assertEquals(failures[1].operation, "abortable.late-cleanup.diagnostic-observer");
	assertEquals(failures[1].primaryMessage, observerFailure.message);
});

Deno.test("abortable reports an uncancellable operation's late rejection", async () => {
	const controller = new AbortController();
	controller.abort();
	let refuse!: (error: unknown) => void;
	const pending = new Promise<never>((_resolve, reject) => refuse = reject);
	const lateFailure = new Error("late dial refusal");
	const observed: unknown[] = [];

	await abortable(pending, controller.signal, (error) => observed.push(error)).catch(() => {});
	refuse(lateFailure);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(observed.length, 1);
	assertEquals(observed[0], lateFailure);
});
