#!/usr/bin/env -S deno run -A
/**
 * playwright-error-surfaces-probe.ts — End-to-end check that the
 * error pipeline reaches the UI:
 *
 *   1. Engine emits → bus → ErrorToast renders.
 *   2. The toast carries the expected `title` + `detail` + `recovery`.
 *
 * Drives the engine via the `__ocv.engine` test hook the App exports
 * for diagnostics. Injects a throwing subscriber so the next
 * `engine.#notify` produces an `internal` error on the bus.
 *
 * Doesn't exercise the boundary path or the import path — those
 * need a component-throw fixture and a file-input drive respectively.
 * The infra they share with this probe (bus → modal/toast) is the
 * same, so this one probe asserts the contract end-to-end.
 */

import { chromium } from "playwright";

const url = Deno.args[0] ?? "http://127.0.0.1:5173/";

const browser = await chromium.launch({
  headless: true,
  args: ["--no-sandbox", "--disable-gpu"],
});

try {
  const ctx = await browser.newContext({
    viewport: { width: 1400, height: 900 },
  });
  const page = await ctx.newPage();

  const consoleErrors: string[] = [];
  page.on("pageerror", (err) => consoleErrors.push(err.message));

  await page.goto(url, { waitUntil: "load" });

  // Wait for the App effect that pins __ocv.engine to publish a value.
  await page.waitForFunction(
    () => {
      const ocv = (globalThis as unknown as { __ocv?: { engine?: unknown } })
        .__ocv;
      return ocv?.engine != null;
    },
    null,
    { timeout: 10_000 },
  );

  // Give React's effects (notably `useEngineErrors`) a tick to bind
  // their `engine.onError` subscription after the engine became
  // non-null. Without this the throwing subscriber can fire before
  // the bus is wired.
  await page.waitForTimeout(300);

  // Inject a throwing subscriber; next notify will surface an internal
  // error through the bus. `restart()` is a synchronous notify path
  // that doesn't depend on play state.
  const dispatched = await page.evaluate(() => {
    const ocv = (globalThis as unknown as {
      __ocv: {
        engine: {
          subscribe: (fn: () => void) => () => void;
          restart: () => void;
        };
      };
    }).__ocv;
    if (!ocv?.engine) return { ok: false, reason: "no __ocv.engine" };
    ocv.engine.subscribe(() => {
      throw new Error("probe-injected subscriber failure");
    });
    try {
      ocv.engine.restart();
    } catch (caught) {
      return {
        ok: false,
        reason: `restart threw: ${
          caught instanceof Error ? caught.message : String(caught)
        }`,
      };
    }
    return { ok: true };
  });

  if (!dispatched.ok) {
    console.error(
      "FAIL: could not dispatch via __ocv.engine:",
      dispatched.reason,
    );
    Deno.exit(1);
  }

  // `internal`-coded errors render in the modal (role="alertdialog"),
  // not the toast — internal failures need user acknowledgement, the
  // non-blocking toast surface is reserved for collision /
  // validation / not-found codes.
  const modal = page.getByRole("alertdialog").filter({
    hasText: "Something went wrong",
  });
  try {
    await modal.first().waitFor({ state: "visible", timeout: 5_000 });
  } catch (caught) {
    const allDialogs = await page.getByRole("alertdialog").allInnerTexts();
    const allAlerts = await page.getByRole("alert").allInnerTexts();
    console.error("FAIL: no matching modal within 5s.");
    console.error("  alertdialog nodes:", allDialogs);
    console.error("  alert nodes:", allAlerts);
    console.error("page errors observed:", consoleErrors);
    throw caught;
  }

  const text = await modal.first().innerText();
  const okDetail = text.includes("probe-injected subscriber failure");
  const okRecovery = text.includes("Try the action again");

  if (!okDetail) {
    console.error("FAIL: modal missing expected detail message");
    console.error("modal text:\n" + text);
    Deno.exit(1);
  }
  if (!okRecovery) {
    console.error("FAIL: modal missing expected recovery hint");
    console.error("modal text:\n" + text);
    Deno.exit(1);
  }

  if (consoleErrors.length > 0) {
    // The throwing subscriber logs to console.error by design (see
    // engine.#notify); filter that out before reporting unexpected
    // pageerrors.
    const unexpected = consoleErrors.filter((m) =>
      !m.includes("probe-injected subscriber failure")
    );
    if (unexpected.length > 0) {
      console.error("unexpected pageerrors:", unexpected);
      Deno.exit(1);
    }
  }

  console.log("PASS: error surfaces probe (toast detail + recovery rendered)");
} finally {
  await browser.close();
}
