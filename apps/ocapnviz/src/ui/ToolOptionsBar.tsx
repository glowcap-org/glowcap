/**
 * Adobe-style tool-options bar — sits above Stage in build mode.
 * Tracks the active builder tool; shows per-tool prefilled-but-
 * editable configuration fields that the *next* click on the canvas
 * will use.
 *
 * Scope: configured tool values, plus the two things a half-finished gesture
 * needs that the banner cannot carry. The banner over the stage says what to
 * click next and is deliberately short — it sits over the picture, so a hint
 * long enough to need reading is covering the thing being read. Detail about the
 * pending click, and the way out of it, live here instead: there is room, it is
 * already scoped to the active tool, and it can hold a button, which the banner
 * cannot because it is `pointer-events: none`.
 *
 * Post-action confirmations and modifier hints are still not this bar's job, and
 * the cursor still owns space-pan.
 *
 * Identity-at-creation (Cluster 2 of the authoring-identity handoff):
 * typing into the ID field BEFORE clicking the canvas commits the
 * typed id with the drop. Collisions surface inline as `<FieldError>`
 * via the engine's `validate` pre-flight; the actual drop still goes
 * through `engine.dispatch` which re-checks (race-safe).
 */

import { useEffect, useState, useSyncExternalStore } from "react";
import type { Engine } from "../engine/engine.ts";
import type { EngineError } from "../engine/errors.ts";
import type { BuilderTool } from "../state/app-state.ts";
import {
  type BuiltinCaptpVersion,
  type BuiltinCodec,
  CAPTP_VERSION_OPTIONS,
  CAPTP_VERSION_WIRE,
  CODEC_OPTIONS,
  type PeerProfile,
  PROFILE_OPTIONS,
  SessionState,
} from "../schema/topology.ts";
import { c, FONT, SIZE, SPACE, WEIGHT } from "./tokens.ts";
import { FieldError } from "./error/FieldError.tsx";
import { toolLabel } from "./ToolPalette.tsx";
import { useDocVersion } from "./useDocVersion.ts";
import { ScrubInput } from "./Timeline/ScrubInput.tsx";

/** Per-tool draft values the bar holds. App lifts these into state
 *  so the values survive tool-switch and so `handleAddPeer` /
 *  `advanceTwoClick` can read them at dispatch time. Session and
 *  message values are sticky across drops by design — users
 *  typically build several of the same kind in a row, so flipping
 *  `codec` once should apply to every session you drop after. */
export type ToolDrafts = {
  // add-peer
  peerId: string;
  peerLabel: string;
  peerProfile: PeerProfile;
  // open-session
  sessionCodec: BuiltinCodec;
  sessionCaptpVersion: BuiltinCaptpVersion;
  sessionInitialState: SessionState;
  // send-message
  messageLabel: string;
  /** Flight duration in ms. Empty string means "use engine default
   *  (DEFAULT_MESSAGE_FLIGHT_MS = 500)"; non-empty parses to a
   *  number, with invalid values silently treated as the default
   *  too. UI keeps it as a string so the field can be cleared. */
  messageFlightMs: string;
};

export const EMPTY_TOOL_DRAFTS: ToolDrafts = {
  peerId: "",
  peerLabel: "",
  peerProfile: "pancake",
  sessionCodec: "capnp",
  sessionCaptpVersion: "v1_0",
  sessionInitialState: "open",
  messageLabel: "",
  messageFlightMs: "",
};

/**
 * The drafts, as a store rather than component state.
 *
 * Two things read them, at different moments. This bar renders
 * them on every keystroke. `handleAddPeer` and the two-click
 * session/message flows read them once, at the click that commits
 * — and that click is the only moment their value matters. Held as
 * state at the App's scope, the second reader saw whatever the
 * drafts were when its callback was last rebuilt, so a field
 * edited after that click's callback was built committed its
 * previous value with no error and no visible tell. `read()` is
 * always the current value, and only the subscriber below
 * re-renders when a field changes, so a keystroke here no longer
 * reconciles the Stage, Inspector and Timeline.
 */
export class ToolDraftStore {
  #drafts: ToolDrafts = EMPTY_TOOL_DRAFTS;
  #listeners = new Set<() => void>();

  /** The committed value, now. Callers that act on a click read
   *  through this and never through a captured copy. */
  read = (): ToolDrafts => this.#drafts;

  set = (next: ToolDrafts): void => {
    this.#drafts = next;
    for (const fn of this.#listeners) fn();
  };

  /** Replace some fields and leave the rest — how a caller outside
   *  the bar edits a draft (clearing the peer id after a drop). */
  update = (patch: Partial<ToolDrafts>): void => {
    this.set({ ...this.#drafts, ...patch });
  };

  subscribe = (fn: () => void): () => void => {
    this.#listeners.add(fn);
    return () => {
      this.#listeners.delete(fn);
    };
  };
}

/** Compute the next auto-mint default id (`peer-N`) without
 *  advancing the engine's counter. Used to prefill the ID field
 *  with a meaningful placeholder. The engine's actual mint may
 *  pick a different id if the user has manually used the suggested
 *  one between renders, but the next dispatch will reconcile. */
export function nextDefaultPeerId(engine: Engine): string {
  const peers = engine.doc.entities?.peers;
  if (!peers) return "peer-1";
  let n = 1;
  while (peers[`peer-${n}`] !== undefined) n += 1;
  return `peer-${n}`;
}

export function ToolOptionsBar(
  {
    tool,
    engine,
    drafts: store,
    armedLabel = null,
    onCancelArmed,
  }: {
    tool: BuilderTool;
    /** Required — caller should not render the bar when there's no
     *  engine (no doc loaded). The bar reads collision pre-flight
     *  off the engine; a null engine has no
     *  useful shape to render. */
    engine: Engine;
    /** The App's one draft store. This bar is its only subscriber;
     *  the click handlers that commit a draft read it directly. */
    drafts: ToolDraftStore;
    /** Display label of the peer a two-click tool is waiting on a second click
     *  for, or null when no gesture is part-finished. Present makes the row
     *  below appear, which is the only on-screen way out of the flow. */
    armedLabel?: string | null;
    /** Abandon the part-finished gesture. The same verb Escape runs, because two
     *  ways to cancel that unwind differently is worse than one that is hard to
     *  find. */
    onCancelArmed?: (() => void) | undefined;
  },
) {
  // Subscribe to document changes so the peer-id collision check refreshes as
  // the user authors: undoing the peer that a typed id collided with frees the
  // name, and the inline error has to go with it. The version is a dependency
  // of that check and not merely a re-render trigger. Dropped on the floor, the
  // effect below kept whichever verdict it reached the last time the id or the
  // tool changed, and the error outlived the collision it named.
  //
  // Which peer ids are taken is a fact about the document, so this is the
  // document's version and not the engine's. Subscribing to every engine
  // notification would re-run the check on every frame of playback and answer
  // the same way each time.
  const docVersion = useDocVersion(engine);

  // The drafts this render paints, and the writer every field
  // below edits through.
  const drafts = useSyncExternalStore(store.subscribe, store.read);
  const onDraftsChange = store.set;

  // Pre-flight collision on the typed peer id. Pure read; runs on
  // every keystroke so the user gets immediate feedback before the
  // click that drops the peer.
  const [peerIdError, setPeerIdError] = useState<EngineError | null>(null);
  useEffect(() => {
    if (tool !== "add-peer") {
      setPeerIdError(null);
      return;
    }
    const typed = drafts.peerId.trim();
    if (typed.length === 0) {
      setPeerIdError(null);
      return;
    }
    const v = engine.validate({
      kind: "add-peer",
      profile: drafts.peerProfile,
      position: { x: 0, y: 0 },
      id: typed,
    });
    setPeerIdError(v.ok ? null : v.error);
  }, [engine, docVersion, tool, drafts.peerId, drafts.peerProfile]);

  const placeholder = nextDefaultPeerId(engine);

  return (
    <div style={barRoot}>
      <span style={toolLabelStyle}>{toolLabel(tool)}</span>
      <div style={sep} />
      {armedLabel !== null && (
        <div style={armedRow}>
          <span style={armedNote}>
            {tool === "open-session"
              ? (
                <>
                  Waiting on a second peer for{" "}
                  <span style={armedWho}>{armedLabel}</span>. Clicking empty
                  canvas ends the session at a peer nobody has named.
                </>
              )
              : (
                <>
                  Waiting on a receiver for{" "}
                  <span style={armedWho}>{armedLabel}</span>.
                </>
              )}
          </span>
          {onCancelArmed && (
            <button
              type="button"
              className="ocv-btn"
              onClick={onCancelArmed}
              title="Abandon this gesture (Escape)"
            >
              Cancel
            </button>
          )}
          <div style={sep} />
        </div>
      )}

      {tool === "add-peer" && (
        <div style={fieldsRow}>
          <Field label="ID">
            <input
              type="text"
              className="ocv-input"
              value={drafts.peerId}
              onChange={(ev) =>
                onDraftsChange({ ...drafts, peerId: ev.target.value })}
              placeholder={placeholder}
              spellCheck={false}
              aria-invalid={peerIdError !== null}
              aria-label="Peer id"
              style={{ ...inlineInput, width: 110 }}
              title={drafts.peerId || `default: ${placeholder}`}
            />
          </Field>
          <Field label="Label">
            <input
              type="text"
              className="ocv-input"
              value={drafts.peerLabel}
              onChange={(ev) =>
                onDraftsChange({ ...drafts, peerLabel: ev.target.value })}
              placeholder="(uses id)"
              spellCheck={false}
              aria-label="Peer label"
              style={{ ...inlineInput, width: 110 }}
              title={drafts.peerLabel || "(uses id as label)"}
            />
          </Field>
          <Field label="Profile">
            <select
              className="ocv-select"
              value={drafts.peerProfile}
              onChange={(ev) =>
                onDraftsChange({
                  ...drafts,
                  peerProfile: ev.target.value as PeerProfile,
                })}
              style={inlineSelect}
              aria-label="Peer profile"
            >
              {PROFILE_OPTIONS.map((p) => (
                <option key={p} value={p}>{p}</option>
              ))}
            </select>
          </Field>
          {peerIdError && (
            <div style={errorSlot}>
              <FieldError error={peerIdError} />
            </div>
          )}
        </div>
      )}
      {tool === "open-session" && (
        <div style={fieldsRow}>
          <Field label="Codec">
            <select
              className="ocv-select"
              value={drafts.sessionCodec}
              onChange={(ev) =>
                onDraftsChange({
                  ...drafts,
                  sessionCodec: ev.target.value as BuiltinCodec,
                })}
              style={{ ...inlineSelect, maxWidth: 92 }}
              aria-label="Session codec"
            >
              {CODEC_OPTIONS.map((codec) => (
                <option key={codec} value={codec}>{codec}</option>
              ))}
            </select>
          </Field>
          <Field label="CapTP">
            <select
              className="ocv-select"
              value={drafts.sessionCaptpVersion}
              onChange={(ev) =>
                onDraftsChange({
                  ...drafts,
                  sessionCaptpVersion: ev.target.value as BuiltinCaptpVersion,
                })}
              style={{ ...inlineSelect, maxWidth: 92 }}
              aria-label="CapTP version"
            >
              {CAPTP_VERSION_OPTIONS.map((v) => (
                <option key={v} value={v}>{CAPTP_VERSION_WIRE[v]}</option>
              ))}
            </select>
          </Field>
          <Field label="Initial">
            <select
              className="ocv-select"
              value={drafts.sessionInitialState}
              onChange={(ev) =>
                onDraftsChange({
                  ...drafts,
                  sessionInitialState: ev.target.value as SessionState,
                })}
              style={{ ...inlineSelect, maxWidth: 104 }}
              aria-label="Session initial state"
            >
              {SessionState.options.map((s) => (
                <option key={s} value={s}>{s}</option>
              ))}
            </select>
          </Field>
        </div>
      )}
      {tool === "send-message" && (
        <div style={fieldsRow}>
          <Field label="Label">
            <input
              type="text"
              className="ocv-input"
              value={drafts.messageLabel}
              onChange={(ev) =>
                onDraftsChange({ ...drafts, messageLabel: ev.target.value })}
              placeholder="(unlabeled)"
              spellCheck={false}
              aria-label="Message label"
              style={{ ...inlineInput, width: 100 }}
            />
          </Field>
          <Field label="Flight">
            <ScrubInput
              label="Message flight ms"
              value={drafts.messageFlightMs === ""
                ? 500
                : (Number(drafts.messageFlightMs) || 500)}
              onChange={(next) =>
                onDraftsChange({
                  ...drafts,
                  messageFlightMs: String(Math.round(next)),
                })}
              min={0}
              max={60_000}
              format={(v) => `${Math.round(v)} ms`}
              formatInput={(v) => String(Math.round(v))}
              defaultValue={500}
              linear
              pxPerDoubling={1}
            />
          </Field>
        </div>
      )}
      {tool === "select" && (
        <span style={placeholderText}>
          Click an entity to inspect it. Drag a peer to move it.
        </span>
      )}
      {tool === "hand" && (
        <span style={placeholderText}>
          Drag to pan. Holding Space pans from any tool.
        </span>
      )}
    </div>
  );
}

function Field(
  { label, children }: { label: string; children: React.ReactNode },
) {
  return (
    <label style={fieldRoot}>
      <span style={fieldLabel}>{label}</span>
      {children}
    </label>
  );
}

// ─── Styles ──────────────────────────────────────────────────────

/** Not `fieldsRow`: that one wraps, which put the way out on a second line
 *  underneath the sentence explaining why a reader might want it. The button
 *  keeps its place at the end of the sentence however the sentence lays out. */
const armedRow = {
  display: "flex",
  alignItems: "center",
  gap: SPACE.sm,
  minWidth: 0,
} satisfies React.CSSProperties;

/** The part-finished gesture's own line: what is pending, and the way out.
 *  Sentence case and not uppercase, because it is a sentence rather than a
 *  label, and it is the one thing in this bar a reader has to actually read. */
const armedNote = {
  fontSize: SIZE.sm,
  color: c.textMuted,
  maxWidth: 460,
} satisfies React.CSSProperties;

const armedWho = {
  color: c.accent,
  fontWeight: WEIGHT.semibold,
} satisfies React.CSSProperties;

const barRoot = {
  display: "flex",
  alignItems: "center",
  gap: SPACE.sm,
  padding: `${SPACE.xs}px ${SPACE.sm}px`,
  background: c.surface,
  borderBottom: `1px solid ${c.border}`,
  fontFamily: FONT.sans,
  fontSize: SIZE.sm,
  minHeight: 32,
} satisfies React.CSSProperties;

const toolLabelStyle = {
  color: c.text,
  fontWeight: WEIGHT.semibold,
  fontSize: SIZE.sm,
} satisfies React.CSSProperties;

const sep = {
  width: 1,
  height: 18,
  background: c.border,
} satisfies React.CSSProperties;

const fieldsRow = {
  display: "flex",
  alignItems: "center",
  gap: SPACE.sm,
  flexWrap: "wrap",
  minWidth: 0,
} satisfies React.CSSProperties;

const fieldRoot = {
  display: "flex",
  alignItems: "center",
  gap: 4,
  minWidth: 0,
} satisfies React.CSSProperties;

const fieldLabel = {
  color: c.textMuted,
  fontSize: SIZE.xs,
  letterSpacing: 0.01,
} satisfies React.CSSProperties;

// What a draft field in this bar is beyond an `.ocv-input`: a fixed
// width, mono, and an ellipsis when the draft outruns it. Corner,
// surface, inset and hover are the class's, and this object used to
// restate three of them — which left these the only fields in the app
// with a three-pixel corner and no hover, because an inline value beats
// the class silently.
const inlineInput = {
  width: 80,
  fontFamily: FONT.mono,
  fontSize: SIZE.sm,
  textOverflow: "ellipsis",
} satisfies React.CSSProperties;

const inlineSelect = {
  fontFamily: FONT.sans,
  fontSize: SIZE.sm,
  minWidth: 0,
  textOverflow: "ellipsis",
} satisfies React.CSSProperties;

const placeholderText = {
  color: c.textSubtle,
  fontStyle: "italic",
  fontSize: SIZE.xs,
} satisfies React.CSSProperties;

const errorSlot = {
  marginLeft: SPACE.sm,
  flexBasis: "100%",
} satisfies React.CSSProperties;
