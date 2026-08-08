import { useEffect, useId, useRef } from "react";
import { holdPointerForModal } from "../interactions/gesture-router.ts";
import { c, FONT, RADIUS, SIZE, SPACE, WEIGHT } from "./tokens.ts";
import { DIALOG_FOCUSABLE_SELECTOR, dialogKeyIntent } from "./dialog.ts";

/**
 * The DOM half of the dialog contract: the dimmed backdrop, the panel, and
 * the keyboard promise a person expects without being told. Focus moves in
 * when the dialog opens, Tab cycles the controls and cannot leave, Enter
 * takes the default action, Escape dismisses when there is somewhere to go,
 * and focus goes back where it came from on the way out.
 *
 * The rules themselves are `dialogKeyIntent` in `ui/dialog.ts`, which is a
 * pure function so it can be read and tested without a browser. This owns the
 * part that touches real focus, and it is one component rather than one per
 * dialog, because a contract that holds in some dialogs and not others is
 * worse than none.
 *
 * A dialog also owns input while it is up, and that is one promise with two
 * halves. The app listens for keystrokes on the window, so a dialog that only
 * trapped focus would still let `v` pick a tool and Cmd-Z take back an edit
 * behind it. Every key event goes to the dialog or to nothing.
 *
 * The pointer half is the same promise, made to the gesture router, which is
 * already what decides which surface a press belongs to. The backdrop covers
 * the viewport and the siblings go `inert`, so a press cannot land on the app
 * by accident. Neither of those is visible to a capture-phase listener rooted
 * above the dialog, and the router's guard is one: a gesture still in flight
 * takes the dialog's own clicks out of its reach. So the dialog claims the
 * pointer through `holdPointerForModal` rather than resting on where in the
 * tree it happens to sit.
 *
 * What a dialog brings is its own content and its own answer. The box, the
 * title at the top of it and the row of answers at the bottom are all here,
 * so two dialogs cannot stand at two heights or name themselves two ways.
 */
export function Dialog(
  {
    role = "dialog",
    title,
    titleTone = "default",
    maxWidth = 520,
    autoFocusRef,
    onPrimary,
    onDismiss,
    footer,
    children,
  }: {
    /** `alertdialog` for something the person must deal with, the default for
     *  everything else. */
    role?: "dialog" | "alertdialog";
    /** What the dialog is called, which is also the name it is announced by.
     *  It is a prop rather than a slot because the accessible name and the
     *  visible heading are one fact, and a caller that spelled an id twice to
     *  join them could mistype one of them in silence. */
    title: string;
    /** `danger` for a dialog reporting something that went wrong. */
    titleTone?: "default" | "danger";
    maxWidth?: number;
    /** Where focus lands when the dialog opens. Without one it lands on the
     *  first control in the panel. */
    autoFocusRef?: React.RefObject<HTMLElement | null>;
    /** What Enter does when focus is not on a control that acts by itself. */
    onPrimary: () => void;
    /** What Escape does. Omitted when the dialog has nowhere to go, as the
     *  error boundary's has: the app behind it is already broken, and
     *  dismissing would take away the only explanation. */
    onDismiss?: (() => void) | undefined;
    /** The answers, in reading order. They sit in one right-aligned row under
     *  the content, so the way out of every dialog is in the same corner. */
    footer?: React.ReactNode;
    children: React.ReactNode;
  },
) {
  const backdropRef = useRef<HTMLDivElement | null>(null);
  const panelRef = useRef<HTMLDivElement | null>(null);
  const titleId = useId();

  // Everything that is not this dialog goes inert while it is up, which is
  // the browser's own word for "not focusable, not clickable, not read out".
  // Trapping Tab inside the panel is not the same promise: it holds only once
  // focus is already inside, and it does nothing about a pointer, a screen
  // reader or the browser's own find. Marking the siblings on the way up to
  // the body leaves exactly the dialog reachable, however deep in the tree it
  // was rendered. Only what this dialog marked is unmarked on the way out, so
  // a dialog opened over another one hands the first one back untouched.
  useEffect(() => {
    const root = backdropRef.current;
    if (!root) return;
    const marked: Element[] = [];
    for (
      let node: Element = root;
      node.parentElement !== null;
      node = node.parentElement
    ) {
      for (const sibling of node.parentElement.children) {
        if (sibling === node || sibling.hasAttribute("inert")) continue;
        sibling.setAttribute("inert", "");
        marked.push(sibling);
      }
    }
    return () => {
      for (const el of marked) el.removeAttribute("inert");
    };
  }, []);

  // The pointer half of the same promise. The claim is taken when the dialog
  // opens and given back when it closes, and they are one effect for the
  // reason focus is: a claim nobody hands back freezes every surface in the
  // app. Whatever gesture was in flight is interrupted on the way in, since
  // the surface driving it is behind the dialog now.
  useEffect(() => {
    const root = backdropRef.current;
    if (!root) return;
    return holdPointerForModal(root);
  }, []);

  // Focus moves in when the dialog opens and goes back where it came from
  // when it closes. They are the two halves of one promise, so they live in
  // one effect and the restore cannot be dropped independently of the take.
  useEffect(() => {
    const opener = document.activeElement;
    const target = autoFocusRef?.current ??
      panelRef.current?.querySelector<HTMLElement>(DIALOG_FOCUSABLE_SELECTOR);
    target?.focus();
    return () => {
      if (opener instanceof HTMLElement && opener.isConnected) opener.focus();
    };
  }, [autoFocusRef]);

  // Keys aimed anywhere but inside the panel stop here. The app's shortcut
  // listener sits on the window in the bubble phase, so a capture-phase
  // listener on the same window is the one place a keystroke can be taken out
  // of its reach before it arrives.
  useEffect(() => {
    const swallow = (ev: KeyboardEvent) => {
      const panel = panelRef.current;
      const target = ev.target;
      if (panel && target instanceof Node && panel.contains(target)) return;
      ev.stopImmediatePropagation();
      ev.preventDefault();
    };
    globalThis.addEventListener("keydown", swallow, { capture: true });
    globalThis.addEventListener("keyup", swallow, { capture: true });
    return () => {
      globalThis.removeEventListener("keydown", swallow, { capture: true });
      globalThis.removeEventListener("keyup", swallow, { capture: true });
    };
  }, []);

  const onKeyDown = (ev: React.KeyboardEvent) => {
    // The other half: a key pressed on a control inside the panel belongs to
    // the dialog, so it does not carry on to the window either.
    ev.stopPropagation();
    const panel = panelRef.current;
    const inCycle = panel
      ? [...panel.querySelectorAll<HTMLElement>(DIALOG_FOCUSABLE_SELECTOR)]
      : [];
    const active = document.activeElement;
    const intent = dialogKeyIntent(ev, {
      atFirst: inCycle.length > 0 && active === inCycle[0],
      atLast: inCycle.length > 0 && active === inCycle[inCycle.length - 1],
      focusActivates: active instanceof HTMLButtonElement ||
        active instanceof HTMLAnchorElement,
      dismissible: onDismiss !== undefined,
    });
    if (!intent) return;
    ev.preventDefault();
    if (intent.kind === "primary") onPrimary();
    else if (intent.kind === "dismiss") onDismiss?.();
    else if (intent.to === "first") inCycle[0]?.focus();
    else inCycle[inCycle.length - 1]?.focus();
  };

  return (
    <div
      ref={backdropRef}
      role={role}
      aria-modal="true"
      aria-labelledby={titleId}
      onKeyDown={onKeyDown}
      onKeyUp={(ev) => ev.stopPropagation()}
      // A press on the backdrop is a press outside the dialog, which is the
      // same answer Escape gives. A dialog with nowhere to go ignores it, as
      // it ignores Escape.
      onPointerDown={(ev) => {
        if (ev.target === ev.currentTarget) onDismiss?.();
      }}
      style={{
        position: "fixed",
        inset: 0,
        background: "rgba(0,0,0,0.45)",
        // The app shell passes pointer events through to the canvas beneath it
        // and every opaque panel claims them back (`appShellStyle` in
        // `App.tsx`). A dialog is mounted wherever its owner lives, so it
        // claims them here rather than relying on the shell it landed in:
        // without this the panel is unclickable and the backdrop never hears
        // the press that should dismiss it.
        pointerEvents: "auto",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        zIndex: 1000,
      }}
    >
      <div
        ref={panelRef}
        style={{
          background: c.surface,
          color: c.text,
          border: `1px solid ${c.borderStrong}`,
          borderRadius: RADIUS.md,
          padding: SPACE.lg,
          maxWidth,
          width: "calc(100% - 64px)",
          maxHeight: "82vh",
          display: "flex",
          flexDirection: "column",
          boxShadow: "0 8px 24px rgba(0,0,0,0.25)",
        }}
      >
        <div
          id={titleId}
          style={{
            fontFamily: FONT.sans,
            fontSize: SIZE.lg,
            fontWeight: WEIGHT.semibold,
            color: titleTone === "danger" ? c.danger : c.text,
            marginBottom: SPACE.sm,
          }}
        >
          {title}
        </div>
        {children}
        {footer !== undefined && (
          <div
            style={{
              display: "flex",
              justifyContent: "flex-end",
              gap: SPACE.sm,
              paddingTop: SPACE.md,
            }}
          >
            {footer}
          </div>
        )}
      </div>
    </div>
  );
}
