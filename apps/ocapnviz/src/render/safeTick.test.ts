import { assert, assertEquals } from "@std/assert";
import { safeListener, safeTick } from "./safeTick.ts";
import {
  _resetErrorBusForTesting,
  type AppError,
  subscribeErrors,
} from "../ui/error/error-bus.ts";

function captured(): { items: AppError[]; off: () => void } {
  const items: AppError[] = [];
  const off = subscribeErrors((e) => items.push(e));
  return { items, off };
}

Deno.test("safeTick: throwing callback emits and keeps the wrapper callable", () => {
  _resetErrorBusForTesting();
  const cap = captured();

  let calls = 0;
  const wrapped = safeTick(() => {
    calls += 1;
    throw new Error("boom");
  });

  wrapped();
  wrapped();
  assertEquals(calls, 2);
  // Both calls throw with the same message, so dedupe keeps only the
  // first emission within the 1s window.
  assertEquals(cap.items.length, 1);
  assertEquals(cap.items[0]?.error.code, "internal");
  cap.off();
});

Deno.test("safeTick: distinct error messages each emit (no false dedupe)", () => {
  _resetErrorBusForTesting();
  const cap = captured();

  let n = 0;
  const wrapped = safeTick(() => {
    n += 1;
    throw new Error(`failure-${n}`);
  });

  wrapped();
  wrapped();
  wrapped();
  assertEquals(cap.items.length, 3);
  cap.off();
});

Deno.test("safeTick: successful calls pass through unchanged", () => {
  _resetErrorBusForTesting();
  const cap = captured();

  const seen: number[] = [];
  const wrapped = safeTick<[number]>((n) => {
    seen.push(n);
  });

  wrapped(1);
  wrapped(2);
  wrapped(3);
  assertEquals(seen, [1, 2, 3]);
  assertEquals(cap.items.length, 0);
  cap.off();
});

Deno.test("safeListener: throwing listener emits and keeps wrapper callable", () => {
  _resetErrorBusForTesting();
  const cap = captured();

  let calls = 0;
  const wrapped = safeListener<Event>(() => {
    calls += 1;
    throw new Error("listener boom");
  });

  wrapped(new Event("resize"));
  wrapped(new Event("resize"));
  assertEquals(calls, 2);
  assert(cap.items.length >= 1);
  assertEquals(cap.items[0]?.error.code, "internal");
  cap.off();
});
