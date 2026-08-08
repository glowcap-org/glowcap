/**
 * Display formatting — the one authority for turning a stored
 * value (a time, a coordinate, raw bytes) into text. Two roles,
 * deliberately different:
 *
 * - **A fact reads at full fidelity.** Inspector values and typed-
 *   edit seeds show every digit the value carries, up to a per-kind
 *   cap, with trailing zeros trimmed so authored values stay short
 *   (`2.3s`, not `2.30000s`). Live producers stamp nanoseconds;
 *   rounding a stored fact for display hid real spacing and read
 *   as "the app is imprecise". A typed-edit SEED especially must
 *   not round: committing a rounded seed writes the rounding back
 *   into the doc (a focused-then-blurred coordinate used to
 *   quantize its pin to integers and cold-recompute the layout).
 *
 * - **A moving readout reads coarse and stable.** The transport
 *   clock and the playhead tick many times a second; five decimal
 *   places there is flicker, not information. `formatClockTime`
 *   shows centiseconds under a minute and scales its unit as the
 *   magnitude grows (a Live doc runs to an hour).
 */

const MS_PER_SEC = 1000;

/** The finest resolution a displayed time fact carries: 5 decimal
 *  places of a second = 10 µs. */
const TIME_DECIMALS_MAX = 5;

/** The finest resolution a displayed coordinate carries: 3 decimal
 *  places of a world unit — sub-pixel at any practical zoom, and
 *  finer than the force layout's meaningful convergence. */
const COORD_DECIMALS_MAX = 3;

/** `value.toFixed(decimals)` with trailing zeros (and a bare
 *  trailing point) trimmed. */
function trimmedFixed(value: number, decimals: number): string {
  const fixed = value.toFixed(decimals);
  if (!fixed.includes(".")) return fixed;
  return fixed.replace(/0+$/, "").replace(/\.$/, "");
}

/** A stored time fact as a bare number in seconds, full fidelity,
 *  trailing zeros trimmed. The seed for typed edits. */
export function formatTimeInput(ms: number): string {
  return trimmedFixed(ms / MS_PER_SEC, TIME_DECIMALS_MAX);
}

/** A stored coordinate as a bare number in world units, full
 *  fidelity, trailing zeros trimmed. Display and typed-edit seed
 *  alike — the seed must round-trip, see the module header. */
export function formatCoord(v: number): string {
  return trimmedFixed(v, COORD_DECIMALS_MAX);
}

/** A stored time fact as display text (`2.3s`, `43.26563s`). */
export const formatTime = (ms: number): string => `${formatTimeInput(ms)}s`;

export const parseTime = (text: string): number | null => {
  // Accept "1.5", "1.5s", "1500ms"; reject anything that doesn't
  // parse to a finite non-negative number.
  const stripped = text.trim().replace(/s$/i, "");
  const isMs = /ms$/i.test(stripped);
  const numericText = stripped.replace(/ms$/i, "");
  const n = Number.parseFloat(numericText);
  if (!Number.isFinite(n) || n < 0) return null;
  return isMs ? n : n * MS_PER_SEC;
};

/** A moving readout (transport clock, playhead): centisecond
 *  precision under a minute (`12.34s`), then coarser units so the
 *  text stays short at any magnitude. Months and years use the
 *  30d / 365d approximation — the timeline measures elapsed
 *  simulation time, not wall-clock dates. */
export function formatClockTime(ms: number): string {
  const abs = Math.abs(ms);
  const sign = ms < 0 ? "-" : "";
  if (abs < 60_000) {
    const s = ms / 1000;
    const whole = Math.floor(s);
    const cents = Math.floor((s - whole) * 100);
    return `${whole}.${cents.toString().padStart(2, "0")}s`;
  }
  if (abs < 3_600_000) {
    const totalSec = Math.round(abs / 1000);
    const min = Math.floor(totalSec / 60);
    const sec = totalSec - min * 60;
    return sec === 0 ? `${sign}${min}min` : `${sign}${min}m${sec}s`;
  }
  if (abs < 86_400_000) {
    const totalMin = Math.round(abs / 60_000);
    const hr = Math.floor(totalMin / 60);
    const min = totalMin - hr * 60;
    return min === 0 ? `${sign}${hr}h` : `${sign}${hr}h${min}m`;
  }
  if (abs < 30 * 86_400_000) {
    const d = abs / 86_400_000;
    return `${sign}${Number.isInteger(d) ? d : d.toFixed(1)}d`;
  }
  if (abs < 365 * 86_400_000) {
    const mo = abs / (30 * 86_400_000);
    return `${sign}${Number.isInteger(mo) ? mo : mo.toFixed(1)}mo`;
  }
  const y = abs / (365 * 86_400_000);
  return `${sign}${Number.isInteger(y) ? y : y.toFixed(1)}yr`;
}

/** Bytes per row in a hex dump. Sixteen is the convention every
 *  other hex tool prints, so a reader can line an Inspector dump up
 *  against `hexdump` output byte for byte. */
const HEX_ROW_BYTES = 16;

/**
 * How many bytes share a hex group inside a row. The default groups
 * the whole row, which prints the familiar run of byte pairs.
 *
 * Eight is for Cap'n Proto. A capnp message is a sequence of 64-bit
 * words — a struct pointer is one word, a list pointer is one word,
 * a struct's data section is a whole number of words — so grouping
 * the dump by eight puts a visible break at every boundary the
 * format actually has, and each row reads as exactly two words. The
 * bytes and their order are the same either way; only the spacing
 * moves, which is why this is a display decision the app makes from
 * the session's codec rather than a question it asks the reader.
 * `hexdump -e` and `xxd -g 8` group the same way for the same
 * reason.
 */
export type HexGroupBytes = 8 | 16;

/** The column the ASCII gutter starts at, so a short final row lines
 *  up with the rows above it. */
function hexColumnWidth(groupBytes: HexGroupBytes): number {
  const groups = HEX_ROW_BYTES / groupBytes;
  const pairs = HEX_ROW_BYTES * 2;
  const withinGroups = groups * (groupBytes - 1);
  const betweenGroups = (groups - 1) * 2;
  return pairs + withinGroups + betweenGroups;
}

/** Classic hex dump: 8-digit offset, 16 hex bytes, ASCII gutter.
 *  Non-printables render as `·` so structure stays scannable.
 *  `groupBytes` sets the spacing inside a row. See `HexGroupBytes`
 *  for why a Cap'n Proto payload wants eight. */
export function formatHexDump(
  bytes: Uint8Array,
  groupBytes: HexGroupBytes = HEX_ROW_BYTES,
): string {
  const lines: string[] = [];
  const width = hexColumnWidth(groupBytes);
  for (let off = 0; off < bytes.length; off += HEX_ROW_BYTES) {
    const row = bytes.subarray(off, off + HEX_ROW_BYTES);
    const groups: string[] = [];
    for (let g = 0; g < row.length; g += groupBytes) {
      groups.push(
        [...row.subarray(g, g + groupBytes)]
          .map((b) => b.toString(16).padStart(2, "0"))
          .join(" "),
      );
    }
    const hex = groups.join("  ");
    // The gutter is not split: a text run inside a payload reads as
    // one run, and a break at the word boundary would cut it up.
    const ascii = [...row]
      .map((b) => (b >= 0x20 && b <= 0x7e ? String.fromCharCode(b) : "·"))
      .join("");
    lines.push(
      `${off.toString(16).padStart(8, "0")}  ${hex.padEnd(width)}  ${ascii}`,
    );
  }
  return lines.join("\n");
}
