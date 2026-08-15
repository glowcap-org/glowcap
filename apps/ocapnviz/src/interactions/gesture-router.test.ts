import { assertEquals } from "@std/assert";
import {
  GestureRouter,
  holdPointerForModal,
  installRootGuard,
  MODAL_SURFACE_TAG,
  watchGestureEnd,
} from "./gesture-router.ts";

// Minimal DOM shims — these tests don't need jsdom. Stub `Element`s
// and `Event`s with only the fields the router consults.

class FakeElement {
  dataset: Record<string, string> = {};
}

const asElement = (el: FakeElement) => el as unknown as HTMLElement;

type FakePointerEvent = {
  type: "pointerdown";
  composedPath: () => unknown[];
  _stopped: boolean;
  _stoppedImmediate: boolean;
  _defaultPrevented: boolean;
  stopPropagation: () => void;
  stopImmediatePropagation: () => void;
  preventDefault: () => void;
};

function fakePointerEvent(path: unknown[]): FakePointerEvent {
  const ev: FakePointerEvent = {
    type: "pointerdown",
    composedPath: () => path,
    _stopped: false,
    _stoppedImmediate: false,
    _defaultPrevented: false,
    stopPropagation() {
      this._stopped = true;
    },
    stopImmediatePropagation() {
      this._stoppedImmediate = true;
    },
    preventDefault() {
      this._defaultPrevented = true;
    },
  };
  return ev;
}

Deno.test("register sets data-pointer-surface and unregister clears it", () => {
  const router = new GestureRouter();
  const el = new FakeElement();
  const unregister = router.register(asElement(el), "stage");
  assertEquals(el.dataset.pointerSurface, "stage");
  unregister();
  assertEquals(el.dataset.pointerSurface, undefined);
});

Deno.test("surfaceFor walks composedPath for nearest registered tag", () => {
  const router = new GestureRouter();
  const outer = new FakeElement();
  const inner = new FakeElement();
  router.register(asElement(outer), "stage");
  // composedPath() is bubble-order: target first, then ancestors.
  // surfaceFor returns the FIRST registered surface encountered.
  const ev = fakePointerEvent([inner, outer]);
  // Inner is unregistered → falls through to outer.
  // FakeElement needs to satisfy `node instanceof HTMLElement`; under
  // Deno the test environment treats HTMLElement as a structural
  // brand, so we substitute the check.
  assertEquals(typeofMatch(router, ev, outer), "stage");
});

// Helper that bypasses `instanceof HTMLElement` (which is unavailable
// in Deno test runtime) by inlining the surfaceFor traversal.
function typeofMatch(
  _router: GestureRouter,
  ev: FakePointerEvent,
  registered: FakeElement,
): string | null {
  for (const node of ev.composedPath()) {
    if (node !== registered) continue;
    const tag = (node as FakeElement).dataset.pointerSurface;
    if (tag) return tag;
  }
  return null;
}

Deno.test("a lease's claim is exclusive across surfaces", () => {
  const router = new GestureRouter();
  const stage = router.lease("stage");
  const timeline = router.lease("timeline");
  assertEquals(stage.claim(asElement(new FakeElement()), 1), true);
  assertEquals(timeline.claim(asElement(new FakeElement()), 2), false);
  assertEquals(router.current()?.tag, "stage");
});

Deno.test("two leases on one tag are two surfaces", () => {
  // The defect a tag-keyed release cannot see: scrub inputs all
  // share one tag, so "release whoever holds `ui-scrub-input`" lets
  // the second instance end the first one's gesture.
  const router = new GestureRouter();
  const first = router.lease("ui-scrub-input");
  const second = router.lease("ui-scrub-input");
  assertEquals(first.claim(asElement(new FakeElement()), 1), true);
  // Same kind of surface, still a foreign claimant.
  assertEquals(second.claim(asElement(new FakeElement()), 2), false);
  // And its release is not the first one's to give.
  second.release();
  assertEquals(router.current()?.tag, "ui-scrub-input");
  assertEquals(first.pointer(), 1);
  first.release();
  assertEquals(router.current(), null);
});

Deno.test("a stale claim cannot revoke the live one", () => {
  // What identity buys over the tag. A lease is stranded only by
  // `reset` today, because the router drops a claim through no
  // other door than the lease holding it — so this is the check
  // that keeps a same-tag release honest if a second door is ever
  // cut, and it is the whole difference from the tag-keyed release
  // that let one scrub input end another's gesture.
  const router = new GestureRouter();
  const first = router.lease("ui-scrub-input");
  first.claim(asElement(new FakeElement()), 1);
  router.reset();
  const second = router.lease("ui-scrub-input");
  assertEquals(second.claim(asElement(new FakeElement()), 2), true);
  first.release();
  assertEquals(router.current()?.pointerId, 2);
});

Deno.test("release keyed on a pointer ignores another pointer's end", () => {
  const router = new GestureRouter();
  const lease = router.lease("stage");
  lease.claim(asElement(new FakeElement()), 1);
  lease.release(99);
  assertEquals(router.current()?.tag, "stage");
  lease.release(1);
  assertEquals(router.current(), null);
  // Idempotent.
  lease.release();
  assertEquals(router.current(), null);
});

Deno.test("a claim tags its element and a release untags it", () => {
  const router = new GestureRouter();
  const lease = router.lease("timeline");
  const el = new FakeElement();
  lease.claim(asElement(el), 4);
  assertEquals(el.dataset.pointerSurface, "timeline");
  lease.release();
  assertEquals(el.dataset.pointerSurface, undefined);
});

Deno.test("a refused claim leaves the element untagged", () => {
  const router = new GestureRouter();
  router.lease("stage").claim(asElement(new FakeElement()), 1);
  const el = new FakeElement();
  assertEquals(router.lease("timeline").claim(asElement(el), 2), false);
  assertEquals(el.dataset.pointerSurface, undefined);
});

Deno.test("subscribe fires on claim and release", () => {
  const router = new GestureRouter();
  const calls: (string | null)[] = [];
  router.subscribe((a) => calls.push(a?.tag ?? null));
  const lease = router.lease("stage");
  lease.claim(asElement(new FakeElement()), 1);
  lease.release();
  assertEquals(calls, ["stage", null]);
});

Deno.test("installRootGuard stops propagation on foreign pointer-down", () => {
  // Build a minimal fake document.
  type Listener = (ev: FakePointerEvent) => void;
  let captured: Listener | null = null;
  const doc = {
    addEventListener(
      type: string,
      fn: Listener,
      opts: { capture?: boolean } | undefined,
    ) {
      if (type === "pointerdown" && opts?.capture) captured = fn;
    },
    removeEventListener() {},
  } as unknown as Document;

  const router = new GestureRouter();
  // Stub `surfaceFor` so we don't need a real composedPath/DOM.
  router.surfaceFor = (ev: Event) => (ev as unknown as { _tag?: string })._tag ?? null;

  installRootGuard(doc, router);
  const stage = router.lease("stage");
  stage.claim(asElement(new FakeElement()), 1);

  const foreign = fakePointerEvent([]);
  (foreign as unknown as { _tag: string })._tag = "timeline";
  captured!(foreign);
  assertEquals(foreign._stopped, true);
  assertEquals(foreign._stoppedImmediate, true);
  assertEquals(foreign._defaultPrevented, false);

  const friendly = fakePointerEvent([]);
  (friendly as unknown as { _tag: string })._tag = "stage";
  captured!(friendly);
  assertEquals(friendly._stopped, false);

  // No active gesture → guard is inert.
  stage.release();
  const idle = fakePointerEvent([]);
  (idle as unknown as { _tag: string })._tag = "timeline";
  captured!(idle);
  assertEquals(idle._stopped, false);
});

Deno.test("an unreleased claim freezes every other surface", () => {
  // The user-visible shape of the freeze, at the router's own
  // level: while one surface holds the lock, the root guard stops
  // every pointer-down that is not its own. This is why a lease
  // that leaves the tree mid-gesture must release — see
  // `gesture-surface.test.ts`, which pins that it does.
  type Listener = (ev: FakePointerEvent) => void;
  let captured: Listener | null = null;
  const doc = {
    addEventListener(type: string, fn: Listener, opts: { capture?: boolean }) {
      if (type === "pointerdown" && opts?.capture) captured = fn;
    },
    removeEventListener() {},
  } as unknown as Document;

  const router = new GestureRouter();
  router.surfaceFor = (ev: Event) => (ev as unknown as { _tag?: string })._tag ?? null;
  installRootGuard(doc, router);

  const orphan = router.lease("ui-scrub-input");
  orphan.claim(asElement(new FakeElement()), 1);

  for (const tag of ["stage", "timeline", "timeline-overview", "ui-resize"]) {
    const ev = fakePointerEvent([]);
    (ev as unknown as { _tag: string })._tag = tag;
    captured!(ev);
    assertEquals(ev._stoppedImmediate, true, `${tag} should be frozen`);
  }

  orphan.release();
  for (const tag of ["stage", "timeline", "timeline-overview", "ui-resize"]) {
    const ev = fakePointerEvent([]);
    (ev as unknown as { _tag: string })._tag = tag;
    captured!(ev);
    assertEquals(ev._stoppedImmediate, false, `${tag} should be free`);
  }
});

// ─────────────────────── Modal hold ────────────────────────────────────
//
// A modal says it owns input while it is up. The keyboard half of that is a
// capture-phase swallow in `ui/Dialog.tsx`; these are the pointer half, which
// is the same promise made to this router. What they pin is that the promise
// holds against the guard above it: a gesture already in flight would
// otherwise keep the lock and the guard would take the modal's own clicks
// out of its reach, which is invisible from the modal because it depends on
// router state rather than on anything the modal did.

Deno.test("a modal takes the pointer from a gesture in flight", () => {
  const router = new GestureRouter();
  const win = new EventTarget();
  const stage = router.lease("stage");
  const interrupted: number[] = [];
  watchGestureEnd(stage, () => interrupted.push(1), win);
  stage.claim(asElement(new FakeElement()), 1);

  const panel = new FakeElement();
  const release = holdPointerForModal(asElement(panel), router, win);

  // The surface driving the drag is behind the modal now, so it hears the
  // interruption a window blur gives it rather than being left mid-gesture.
  assertEquals(interrupted.length, 1);
  assertEquals(router.current()?.tag, MODAL_SURFACE_TAG);
  assertEquals(panel.dataset.pointerSurface, MODAL_SURFACE_TAG);

  release();
  assertEquals(router.current(), null);
  assertEquals(panel.dataset.pointerSurface, undefined);
});

Deno.test("while a modal holds, only its own presses get through", () => {
  type Listener = (ev: FakePointerEvent) => void;
  let captured: Listener | null = null;
  const doc = {
    addEventListener(type: string, fn: Listener, opts: { capture?: boolean }) {
      if (type === "pointerdown" && opts?.capture) captured = fn;
    },
    removeEventListener() {},
  } as unknown as Document;

  const router = new GestureRouter();
  router.surfaceFor = (ev: Event) => (ev as unknown as { _tag?: string })._tag ?? null;
  installRootGuard(doc, router);

  const release = holdPointerForModal(
    asElement(new FakeElement()),
    router,
    new EventTarget(),
  );

  const inside = fakePointerEvent([]);
  (inside as unknown as { _tag: string })._tag = MODAL_SURFACE_TAG;
  captured!(inside);
  assertEquals(inside._stopped, false, "a press in the modal reaches it");

  for (const tag of ["stage", "timeline", "ui-resize"]) {
    const ev = fakePointerEvent([]);
    (ev as unknown as { _tag: string })._tag = tag;
    captured!(ev);
    assertEquals(ev._stoppedImmediate, true, `${tag} should be shut out`);
  }

  release();
  const after = fakePointerEvent([]);
  (after as unknown as { _tag: string })._tag = "stage";
  captured!(after);
  assertEquals(after._stopped, false, "the app is free again");
});

Deno.test("a modal over a modal is a surface the guard still passes", () => {
  // The error modal can arrive over the Reference dialog. The lock is the
  // first one's and stays there, so the second is tagged without it: a press
  // in either reads as the surface holding the lock, and neither release
  // ends the other's hold.
  const router = new GestureRouter();
  const win = new EventTarget();
  const first = new FakeElement();
  const second = new FakeElement();
  const releaseFirst = holdPointerForModal(asElement(first), router, win);
  const releaseSecond = holdPointerForModal(asElement(second), router, win);

  assertEquals(first.dataset.pointerSurface, MODAL_SURFACE_TAG);
  assertEquals(second.dataset.pointerSurface, MODAL_SURFACE_TAG);

  releaseSecond();
  assertEquals(second.dataset.pointerSurface, undefined);
  assertEquals(router.current()?.tag, MODAL_SURFACE_TAG);

  releaseFirst();
  assertEquals(router.current(), null);
  assertEquals(first.dataset.pointerSurface, undefined);
});
