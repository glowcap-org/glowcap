// Both browser copy paths end at one refusal, with the browser diagnostic kept.
/// <reference lib="dom" />
import { assert, assertEquals } from "@std/assert";
import { writeClipboard } from "../web/ui/clipboard.ts";
import { failureView, LocalRefusal } from "../lib/text/failure.ts";

for (const rejected of [false, true]) {
	Deno.test(`clipboard ${rejected ? "permission refusal" : "absence"} has one catalog answer`, async () => {
		const prior = new Map(
			["document", "Element", "HTMLElement"].map(
				(key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)],
			),
		);
		const clipboard = Object.getOwnPropertyDescriptor(navigator, "clipboard");
		const cause = new DOMException("clipboard permission denied", "NotAllowedError");
		const field = {
			style: { cssText: "" },
			setAttribute() {},
			focus() {},
			select() {},
			setSelectionRange() {},
			remove() {},
		};
		Object.defineProperty(globalThis, "document", {
			configurable: true,
			value: {
				activeElement: null,
				body: { appendChild() {} },
				createElement: () => field,
				execCommand: () => false,
			},
		});
		for (const key of ["Element", "HTMLElement"]) {
			Object.defineProperty(globalThis, key, { configurable: true, value: class {} });
		}
		Object.defineProperty(navigator, "clipboard", {
			configurable: true,
			value: rejected ? { writeText: () => Promise.reject(cause) } : undefined,
		});
		try {
			const [result] = await Promise.allSettled([writeClipboard("link", document.body)]);
			assert(result.status === "rejected" && result.reason instanceof LocalRefusal);
			const view = failureView(result.reason);
			assertEquals(view.code, "local-clipboard-unavailable");
			assertEquals(view.retry, "never");
			assertEquals(view.detail, rejected ? cause.message : "");
			if (rejected) assert(result.reason.cause === cause);
		} finally {
			for (const [key, descriptor] of prior) {
				if (descriptor == null) Reflect.deleteProperty(globalThis, key);
				else Object.defineProperty(globalThis, key, descriptor);
			}
			if (clipboard == null) Reflect.deleteProperty(navigator, "clipboard");
			else Object.defineProperty(navigator, "clipboard", clipboard);
		}
	});
}
