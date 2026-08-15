import { useEffect, useRef, useState } from "react";
import { c, FONT, RADIUS, SIZE, SPACE, WEIGHT } from "../tokens.ts";
import { type AppError, subscribeErrors } from "./error-bus.ts";

const AUTO_DISMISS_MS = 6000;
const MAX_TOASTS = 4;

interface ToastItem {
  id: number;
  event: AppError;
}

/**
 * Non-blocking toasts for collision / validation / not-found errors —
 * the codes the user can act on inline without losing context. Sits
 * top-right. `internal` and `import` are intentionally NOT toasted —
 * those go to the modal because the user needs to acknowledge.
 *
 * Auto-dismiss after 6s; user can dismiss earlier. At most 4 visible
 * at once; older ones drop off the bottom.
 */
export function ErrorToast() {
  const [toasts, setToasts] = useState<ToastItem[]>([]);

  // Every dismissal still waiting to fire. A timer outliving its
  // subscription would call `setToasts` on a component that is no
  // longer there; the app mounts this once, so what makes it reachable
  // is React's development double-mount, where the first
  // subscription's timers survive into the second.
  const pending = useRef(new Set<number>());

  useEffect(() => {
    let counter = 0;
    const timers = pending.current;
    const unsubscribe = subscribeErrors((event) => {
      if (event.error.code === "internal" || event.error.code === "import") {
        return;
      }
      const id = ++counter;
      setToasts((prev) => {
        const next = [...prev, { id, event }];
        return next.length > MAX_TOASTS ? next.slice(-MAX_TOASTS) : next;
      });
      const timer = globalThis.setTimeout(() => {
        timers.delete(timer);
        setToasts((prev) => prev.filter((t) => t.id !== id));
      }, AUTO_DISMISS_MS);
      timers.add(timer);
    });
    return () => {
      unsubscribe();
      for (const timer of timers) globalThis.clearTimeout(timer);
      timers.clear();
    };
  }, []);

  if (toasts.length === 0) return null;

  return (
    <div
      role="region"
      aria-label="Errors"
      style={{
        position: "fixed",
        top: SPACE.lg,
        right: SPACE.lg,
        display: "flex",
        flexDirection: "column",
        gap: SPACE.sm,
        zIndex: 999,
        maxWidth: 360,
      }}
    >
      {toasts.map((toast) => (
        <div
          key={toast.id}
          role="alert"
          style={{
            background: c.dangerSoft,
            color: c.text,
            border: `1px solid ${c.danger}`,
            borderRadius: RADIUS.md,
            padding: SPACE.md,
            fontFamily: FONT.sans,
            boxShadow: "0 4px 12px rgba(0,0,0,0.18)",
          }}
        >
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "flex-start",
              gap: SPACE.sm,
              marginBottom: SPACE.xs,
            }}
          >
            <div
              style={{
                fontSize: SIZE.base,
                fontWeight: WEIGHT.semibold,
                color: c.danger,
              }}
            >
              {toast.event.error.title}
            </div>
            <button
              type="button"
              aria-label="Dismiss"
              onClick={() => setToasts((prev) => prev.filter((t) => t.id !== toast.id))}
              style={{
                background: "transparent",
                border: "none",
                color: c.textMuted,
                cursor: "pointer",
                // A drawn mark rather than a word, so it takes the
                // heading size to read at all.
                fontSize: SIZE.lg,
                lineHeight: 1,
                padding: 0,
              }}
            >
              ×
            </button>
          </div>
          <div
            style={{
              fontSize: SIZE.sm,
              color: c.text,
              marginBottom: SPACE.xs,
            }}
          >
            {toast.event.error.detail}
          </div>
          <div
            style={{
              fontSize: SIZE.xs,
              color: c.textMuted,
            }}
          >
            {toast.event.error.recovery}
          </div>
        </div>
      ))}
    </div>
  );
}
