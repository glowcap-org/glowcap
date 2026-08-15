import { assertEquals, assertStringIncludes } from "@std/assert";
import { derivationNote, hexGroupFor, loadPersistedViewMode, payloadState, renderPayload } from "./PayloadViewer.tsx";

// Deno provides a real localStorage, so the round trip runs against
// the same storage the browser uses.

Deno.test("the payload lens persists and survives a malformed store", () => {
  localStorage.setItem("ocapnviz:payload-view-mode", "utf-8");
  assertEquals(loadPersistedViewMode(), "utf-8");
  // A value outside the lens vocabulary falls back to the default
  // instead of poisoning the picker.
  localStorage.setItem("ocapnviz:payload-view-mode", "yaml");
  assertEquals(loadPersistedViewMode(), "hex");
  localStorage.removeItem("ocapnviz:payload-view-mode");
  assertEquals(loadPersistedViewMode(), "hex");
});

Deno.test("hex grouping follows the codec, and defaults to bytes", () => {
  assertEquals(hexGroupFor("capnp"), 8);
  assertEquals(hexGroupFor("syrup"), 16);
  // An authored document can hold a message with no session behind
  // it. Guessing capnp there would space a Syrup frame wrongly, so
  // the unknown case reads as plain bytes.
  assertEquals(hexGroupFor(undefined), 16);
});

// The head of `test/codec/capnp_fixtures/op_deliver.bin`: a segment
// table word, then the root struct pointer. Real capnp, so the word
// boundary the grouping exposes is a real one.
const CAPNP_HEAD = new Uint8Array([
  0x00,
  0x00,
  0x00,
  0x00,
  0x11,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x00,
]);

Deno.test("a capnp payload reads as words, a syrup one as bytes", () => {
  const b64 = "AA==";
  const capnp = renderPayload("hex", b64, CAPNP_HEAD, "capnp");
  // Two words on the row, with the boundary between them visible.
  assertStringIncludes(
    capnp,
    "00 00 00 00 11 00 00 00  00 00 00 00 01 00 01 00",
  );
  // The same bytes under Syrup keep the single-spaced run: grouping
  // is the codec's answer, not a global switch.
  const syrup = renderPayload("hex", b64, CAPNP_HEAD, "syrup");
  assertStringIncludes(
    syrup,
    "00 00 00 00 11 00 00 00 00 00 00 00 01 00 01 00",
  );
  // Same bytes either way. Only the spacing moved.
  assertEquals(
    capnp.replace(/ +/g, " "),
    syrup.replace(/ +/g, " "),
  );
});

Deno.test("grouping touches the hex lens alone", () => {
  const bytes = new TextEncoder().encode("Syrup!");
  const b64 = "U3lydXAh";
  assertEquals(renderPayload("base64", b64, bytes, "capnp"), b64);
  assertEquals(renderPayload("utf-8", b64, bytes, "capnp"), "Syrup!");
});

// A message the recording never carried bytes for used to render an
// empty pane, which reads as a viewer that failed rather than as a
// payload nobody captured. These two hold the three readings apart.

Deno.test("a message with no recorded frame gets a sentence, not silence", () => {
  const state = payloadState(undefined);
  assertEquals(state.kind, "absent");
  if (state.kind === "frame") throw new Error("unreachable");
  assertStringIncludes(state.note, "No frame was recorded");
});

Deno.test("bytes and malformed bytes stay distinguishable", () => {
  const frame = payloadState("U3lydXAh");
  assertEquals(frame.kind, "frame");
  if (frame.kind !== "frame") throw new Error("unreachable");
  assertEquals(new TextDecoder().decode(frame.bytes), "Syrup!");
  // A producer line the app does not control. It reads as a fact
  // about the payload, and never as the absent case: an operator who
  // sees "no frame was recorded" would go looking in the wrong place.
  const bad = payloadState("not base64 at all!!");
  assertEquals(bad.kind, "malformed");
});

Deno.test("a frame says where its bytes came from, when the recording said", () => {
  assertEquals(
    derivationNote(["test/oracle/corpus/op_deliver.bin"]),
    "Bytes read from test/oracle/corpus/op_deliver.bin.",
  );
  // A live capture names no file, and inventing one would be the
  // exact claim this line exists to avoid making.
  assertEquals(derivationNote(undefined), null);
  assertEquals(derivationNote([]), null);
});
