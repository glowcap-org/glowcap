import { assert, assertEquals } from "@std/assert";
import { _resetErrorBusForTesting, type AppError, pushError, subscribeErrors } from "./error-bus.ts";
import { collisionError, internalError } from "../../engine/errors.ts";

function sample(): AppError {
  return {
    error: collisionError("peer", "peer-1"),
    source: "engine",
  };
}

Deno.test("subscribeErrors receives subsequent pushes", () => {
  _resetErrorBusForTesting();
  const received: AppError[] = [];
  subscribeErrors((e) => received.push(e));

  pushError(sample());
  pushError({
    error: internalError(new Error("boom")),
    source: "window",
  });

  assertEquals(received.length, 2);
  assertEquals(received[0]?.source, "engine");
  assertEquals(received[1]?.source, "window");
});

Deno.test("unsubscribe stops further deliveries", () => {
  _resetErrorBusForTesting();
  let count = 0;
  const off = subscribeErrors(() => {
    count += 1;
  });

  pushError(sample());
  assertEquals(count, 1);

  off();
  pushError(sample());
  assertEquals(count, 1);
});

Deno.test("multiple listeners all fire; one throwing can't starve others", () => {
  _resetErrorBusForTesting();
  let good = 0;
  subscribeErrors(() => {
    throw new Error("bad listener");
  });
  subscribeErrors(() => {
    good += 1;
  });

  pushError(sample());
  assertEquals(good, 1);
});

Deno.test("errors pushed before any subscription are dropped", () => {
  _resetErrorBusForTesting();
  pushError(sample());

  const received: AppError[] = [];
  subscribeErrors((e) => received.push(e));
  assertEquals(received.length, 0);

  pushError(sample());
  assert(received.length === 1);
});
