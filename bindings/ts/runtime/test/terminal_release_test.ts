import { INTERNAL, INVALID_ARGUMENT, IO, OK } from "@glowcap/abi";
import { GlowcapError, secondaryFailures } from "../errors.ts";
import type { DriverCallOutcome } from "../internal/driver_failure.ts";
import { TerminalDriverRelease } from "../driver_loop/terminal_release.ts";
import { assert } from "../../dogfood/assert.ts";

function outcome(code: number, error: GlowcapError | null): DriverCallOutcome {
	return { code, failure: null, error };
}

Deno.test("an observed close refusal waits for the next safe boundary", () => {
	const primary = new GlowcapError(INTERNAL, "driver loop failed");
	const refusal = new GlowcapError(INVALID_ARGUMENT, "release refused");
	let attempts = 0;
	let commits = 0;
	const attemptCount = () => attempts;
	const commitCount = () => commits;
	let retry: (() => void) | null = null;
	new TerminalDriverRelease(
		primary,
		() => {
			attempts++;
			return outcome(OK, null);
		},
		() => {
			commits++;
		},
		outcome(INVALID_ARGUMENT, refusal),
		(next) => {
			retry = next;
		},
	);
	assert(attemptCount() === 0, "the refusing close boundary immediately retried release");
	assert(commitCount() === 0, "a refused release committed teardown");
	assert(secondaryFailures(primary)[0] === refusal, "the exact refusal was not retained");
	assert(retry != null, "the refused release lost its retry owner");
	(retry as () => void)();
	assert(attemptCount() === 1, "the next boundary did not make exactly one attempt");
	assert(commitCount() === 1, "successful retry did not commit teardown exactly once");
	(retry as () => void)();
	assert(attemptCount() === 1 && commitCount() === 1, "consumed release remained callable");
});

Deno.test("terminal release preserves primary and later cleanup consequences", async () => {
	const primary = new GlowcapError(INTERNAL, "step failed");
	const refusal = new GlowcapError(INVALID_ARGUMENT, "release refused");
	const consumedFailure = new GlowcapError(IO, "release teardown failed");
	const cleanup = new Error("wrapper cleanup failed");
	let attempts = 0;
	const attemptCount = () => attempts;
	let retry: (() => void) | null = null;
	const owner = new TerminalDriverRelease(
		primary,
		() => {
			attempts++;
			return attempts === 1 ? outcome(INVALID_ARGUMENT, refusal) : outcome(IO, consumedFailure);
		},
		() => Promise.reject(cleanup),
		undefined,
		(next) => {
			retry = next;
		},
	);
	assert(owner.failure === primary, "terminal release replaced the primary identity");
	assert(attemptCount() === 1 && retry != null, "first refusal was not parked");
	(retry as () => void)();
	await Promise.resolve();
	const secondary = secondaryFailures(primary);
	assert(secondary[0] === refusal, "the first refusal moved");
	assert(secondary[1] === consumedFailure, "the consuming release failure disappeared");
	assert(secondary[2] === cleanup, "wrapper cleanup did not remain a consequence");
});

Deno.test("a release call exception retains the lease for a later boundary", () => {
	const primary = new GlowcapError(INTERNAL, "step failed");
	const refusal = new Error("FFI release call refused");
	let attempts = 0;
	let commits = 0;
	const attemptCount = () => attempts;
	const commitCount = () => commits;
	let retry: (() => void) | null = null;
	new TerminalDriverRelease(
		primary,
		() => {
			attempts++;
			if (attempts === 1) throw refusal;
			return outcome(OK, null);
		},
		() => {
			commits++;
		},
		undefined,
		(next) => {
			retry = next;
		},
	);
	assert(attemptCount() === 1 && commitCount() === 0, "a throwing call consumed the release lease");
	assert(secondaryFailures(primary)[0] === refusal, "the call exception disappeared");
	assert(retry != null, "a throwing release lost its retry owner");
	(retry as () => void)();
	assert(attemptCount() === 2 && commitCount() === 1, "the later safe boundary did not retire the lease");
});
