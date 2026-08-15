import { assertEquals } from "@std/assert";
import { formatClockTime, formatCoord, formatHexDump, formatTime, formatTimeInput } from "./format.ts";

Deno.test("a time fact shows every digit it carries, up to 10 µs", () => {
  // Facts read at full fidelity: live producers stamp nanoseconds,
  // and rounding a stored value to centiseconds displayed real
  // spacing as "imprecise". Five decimals of a second is the cap.
  assertEquals(formatTime(43_265.63), "43.26563s");
  assertEquals(formatTime(43_265.625), "43.26563s"); // 6th decimal rounds
  assertEquals(formatTimeInput(43_265.63), "43.26563");
});

Deno.test("a short authored value stays short (trailing zeros trim)", () => {
  assertEquals(formatTime(2_300), "2.3s");
  assertEquals(formatTime(5_000), "5s");
  assertEquals(formatTime(0), "0s");
  assertEquals(formatTimeInput(2_300), "2.3");
});

Deno.test("the clock readout stays coarse and magnitude-scaled", () => {
  assertEquals(formatClockTime(12_500), "12.50s");
  assertEquals(formatClockTime(78_000), "1m18s");
  assertEquals(formatClockTime(3_600_000), "1h");
});

Deno.test("a coordinate fact reads at full fidelity, trimmed", () => {
  // The typed-edit seed must round-trip: committing a rounded seed
  // used to quantize a pin to integers on focus-then-blur, moving
  // the peer and cold-recomputing the layout.
  assertEquals(formatCoord(312.4375), "312.438");
  assertEquals(formatCoord(-41.5), "-41.5");
  assertEquals(formatCoord(100), "100");
});

Deno.test("formatHexDump: offsets, hex, ascii gutter, non-printables", () => {
  const bytes = new TextEncoder().encode("Syrup!\x01\x02");
  assertEquals(
    formatHexDump(bytes),
    "00000000  53 79 72 75 70 21 01 02" + " ".repeat(26) + "Syrup!··",
  );
});

Deno.test("formatHexDump: rows split at 16 bytes", () => {
  const bytes = new Uint8Array(17).fill(0x41);
  const lines = formatHexDump(bytes).split("\n");
  assertEquals(lines.length, 2);
  assertEquals(lines[1]!.startsWith("00000010  41"), true);
});

Deno.test("formatHexDump: 8-byte groups break the row at the word", () => {
  // A Cap'n Proto payload is a run of 64-bit words, and a dump that
  // ran them together read as one undifferentiated wall. Grouping by
  // eight puts the break where the format has one; the row still
  // holds sixteen bytes, so an offset still lines up with any other
  // hex tool.
  const bytes = new Uint8Array(16).fill(0x41);
  const line = formatHexDump(bytes, 8);
  assertEquals(
    line,
    "00000000  41 41 41 41 41 41 41 41  41 41 41 41 41 41 41 41" +
      "  AAAAAAAAAAAAAAAA",
  );
});

Deno.test("formatHexDump: a short grouped row keeps the gutter aligned", () => {
  // The last row of a payload is usually partial. Its ASCII gutter
  // has to start in the same column as the rows above, or the dump
  // shears at the bottom.
  const bytes = new Uint8Array(19).fill(0x41);
  const lines = formatHexDump(bytes, 8).split("\n");
  assertEquals(lines.length, 2);
  assertEquals(lines[0]!.indexOf("AAAA"), lines[1]!.indexOf("AAA"));
});
