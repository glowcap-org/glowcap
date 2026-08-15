/**
 * Raw payload viewer — the Inspector pane for a message's wire
 * frame. The pipeline hands bytes through untouched (the producer
 * caps, the converter passes, the observation is the one home);
 * this is the one place they become text, in whichever lens the
 * reader picks: a hex dump, UTF-8, or the raw base64.
 *
 * The hex lens spaces its rows by the codec that produced the frame,
 * so a Cap'n Proto frame reads as the 64-bit words it is made of.
 * That is a display decision the pane makes, not a fourth lens: see
 * `hexGroupFor`. The caller decides which codec that is, because a
 * frame's codec is not always its session's: every `op:start-session`
 * is Syrup whatever the session goes on to speak (ADR-0103).
 *
 * Display-only. Decoding failures render as replacement characters
 * rather than errors — a binary frame viewed as UTF-8 is the
 * reader's experiment, not a fault.
 *
 * A message whose recording carried no frame gets a sentence saying
 * so rather than an empty pane. `payloadState` is where the three
 * readings (a frame, no frame, malformed bytes) are decided.
 */

import { useMemo, useState } from "react";
import { formatHexDump, type HexGroupBytes } from "../format.ts";
import type { Codec } from "../../schema/topology.ts";
import { c, FONT, RADIUS, segmentCellClass, SIZE, SPACE } from "../tokens.ts";

// Lenses answer questions a reader can actually have about an OCapN
// frame. UTF-16 is deliberately absent: Syrup and Cap'n Proto text
// are UTF-8 by spec, so a UTF-16 lens could only render convincing
// garbage. A producer that ever carries UTF-16 payloads earns the
// entry back with one line here and one switch arm.
const VIEW_MODES = ["hex", "utf-8", "base64"] as const;
type ViewMode = (typeof VIEW_MODES)[number];

// The lens is a viewer preference, not per-message state: picking
// UTF-8 means "show me payloads as UTF-8" until the reader says
// otherwise, across message switches and across sessions. Same
// localStorage idiom as the timeline view (`app-state.ts`), owned
// here because the lens is this pane's concern.
const VIEW_MODE_STORAGE_KEY = "ocapnviz:payload-view-mode";

export function loadPersistedViewMode(): ViewMode {
  const storage = (globalThis as { localStorage?: Storage }).localStorage;
  const raw = storage?.getItem(VIEW_MODE_STORAGE_KEY);
  return (VIEW_MODES as readonly string[]).includes(raw ?? "") ? raw as ViewMode : "hex";
}

function savePersistedViewMode(mode: ViewMode): void {
  const storage = (globalThis as { localStorage?: Storage }).localStorage;
  try {
    storage?.setItem(VIEW_MODE_STORAGE_KEY, mode);
  } catch {
    // Quota / private-mode failures are non-fatal — the lens falls
    // back to the default on next load.
  }
}

const paneStyle = {
  margin: 0,
  padding: SPACE.sm,
  maxHeight: 220,
  overflow: "auto",
  background: c.surface,
  border: `1px solid ${c.border}`,
  borderRadius: RADIUS.md,
  fontFamily: FONT.mono,
  fontSize: SIZE.xs,
  lineHeight: 1.5,
  color: c.text,
  whiteSpace: "pre",
} satisfies React.CSSProperties;

const wrapPaneStyle = {
  ...paneStyle,
  whiteSpace: "pre-wrap",
  wordBreak: "break-all",
} satisfies React.CSSProperties;

const noteStyle = {
  color: c.textSubtle,
  fontSize: SIZE.xs,
  fontFamily: FONT.sans,
} satisfies React.CSSProperties;

/** Null on malformed input — feed lines are outside this app's
 *  control, and a bad payload should read as a fact about the
 *  payload, never crash the Inspector. */
function decodeBase64(b64: string): Uint8Array | null {
  try {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}

/**
 * What the pane has for one message. Three states, and only the
 * first has bytes in it: a message whose recording never carried a
 * frame says so, because a pane that renders nothing reads as a
 * broken viewer rather than as an absent payload.
 */
export type PayloadState =
  | { readonly kind: "frame"; readonly bytes: Uint8Array; readonly b64: string }
  | { readonly kind: "absent"; readonly note: string }
  | { readonly kind: "malformed"; readonly note: string };

/** The pane's whole reading of its input, with no React around it. */
export function payloadState(bytesB64: string | undefined): PayloadState {
  if (bytesB64 === undefined) {
    return {
      kind: "absent",
      note: "No frame was recorded for this message. The recording carries " +
        "the message, not its bytes.",
    };
  }
  const bytes = decodeBase64(bytesB64);
  if (bytes === null) {
    return {
      kind: "malformed",
      note: "The payload is not valid base64. The producer sent a " +
        "malformed line.",
    };
  }
  return { kind: "frame", bytes, b64: bytesB64 };
}

/** One line naming where a frame's bytes came from, when the
 *  recording said. Absent for a live capture that named no file. */
export function derivationNote(
  derivedFrom: readonly string[] | undefined,
): string | null {
  if (derivedFrom === undefined || derivedFrom.length === 0) return null;
  return `Bytes read from ${derivedFrom.join(", ")}.`;
}

/**
 * How the hex lens spaces a row, decided from the codec that
 * produced the frame. Cap'n Proto is a sequence of 64-bit words, so
 * its dump groups by eight and every word boundary is visible;
 * Syrup is a byte grammar with no such unit, so it keeps the plain
 * run. Nothing is hidden either way, only the spacing moves, and
 * that is why the app decides it instead of adding a fourth lens
 * the reader would have to re-pick per message.
 *
 * An unknown codec (an authored document with no session behind the
 * message) reads as bytes, the answer that assumes least.
 */
export function hexGroupFor(codec: Codec | undefined): HexGroupBytes {
  return codec === "capnp" ? 8 : 16;
}

/** The lens applied to one payload. Exported for tests: it is the
 *  whole of what the pane decides, with no React around it. */
export function renderPayload(
  mode: ViewMode,
  b64: string,
  bytes: Uint8Array,
  codec: Codec | undefined,
): string {
  switch (mode) {
    case "hex":
      return formatHexDump(bytes, hexGroupFor(codec));
    case "utf-8":
      return new TextDecoder("utf-8").decode(bytes);
    case "base64":
      return b64;
  }
}

export function PayloadViewer(
  { bytesB64, byteLen, codec, derivedFrom }: {
    /** The frame (or its producer-capped head), base64. Undefined
     *  when the recording carried no bytes for this message. */
    bytesB64?: string | undefined;
    /** The frame's true length; larger than the carried bytes when
     *  the producer truncated. */
    byteLen?: number | undefined;
    /** The codec that produced the frame. It shapes the hex lens
     *  and nothing else. */
    codec?: Codec | undefined;
    /** Where the bytes came from, as the recording stated it. */
    derivedFrom?: readonly string[] | undefined;
  },
) {
  const [mode, setModeState] = useState<ViewMode>(loadPersistedViewMode);
  const setMode = (next: ViewMode) => {
    setModeState(next);
    savePersistedViewMode(next);
  };
  const state = useMemo(() => payloadState(bytesB64), [bytesB64]);
  // Hooks run before the early return below, so the text is rendered
  // for a state that may carry no bytes. The empty string is that
  // case and nothing reads it.
  const text = useMemo(
    () => state.kind === "frame" ? renderPayload(mode, state.b64, state.bytes, codec) : "",
    [mode, state, codec],
  );
  if (state.kind !== "frame") {
    return <span style={noteStyle}>{state.note}</span>;
  }
  const bytes = state.bytes;
  const source = derivationNote(derivedFrom);
  const truncated = byteLen !== undefined && byteLen > bytes.length;
  return (
    <div style={{ display: "grid", rowGap: SPACE.xs }}>
      <div
        className="ocv-segment"
        role="radiogroup"
        aria-label="Payload view mode"
      >
        {VIEW_MODES.map((m) => (
          <button
            key={m}
            type="button"
            role="radio"
            aria-checked={mode === m}
            className={segmentCellClass(mode === m)}
            onClick={() => setMode(m)}
          >
            {m}
          </button>
        ))}
      </div>
      <pre style={mode === "hex" ? paneStyle : wrapPaneStyle}>{text}</pre>
      {mode === "hex" && hexGroupFor(codec) === 8 && (
        <span style={noteStyle}>
          Grouped in 8-byte words, the unit Cap'n Proto is built from.
        </span>
      )}
      {truncated && (
        <span style={noteStyle}>
          Showing the first {bytes.length} of {byteLen} bytes. The producer recorded no more.
        </span>
      )}
      {source !== null && <span style={noteStyle}>{source}</span>}
    </div>
  );
}
