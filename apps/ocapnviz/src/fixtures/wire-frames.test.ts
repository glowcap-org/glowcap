import { assertEquals } from "@std/assert";
import { allWireFrames, payloadOf, type WireFrame } from "./wire-frames.ts";
import { scenarios } from "./index.ts";
import { observationsOf } from "../engine/temporal/recording-access.ts";

/**
 * The anti-fabrication check. Every frame the recordings carry claims
 * to be a byte-for-byte copy of a file this repository commits, and
 * this test is what makes the claim cost something: it reads the file
 * and compares. Invented bytes, a stale copy, or a corpus that moved
 * under us all land here as a failure instead of as a convincing
 * hex dump in the Inspector.
 */

const repoRoot = new URL("../../../../", import.meta.url);

function committedBytes(frame: WireFrame): Uint8Array {
  return Deno.readFileSync(new URL(frame.source, repoRoot));
}

function decodeBase64(b64: string): Uint8Array {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

Deno.test("every shipped frame matches its committed source byte for byte", () => {
  for (const frame of allWireFrames) {
    assertEquals(
      decodeBase64(frame.bytesB64),
      committedBytes(frame),
      `${frame.source} does not match the bytes shipped for it`,
    );
  }
});

Deno.test("a payload names the file its bytes came from", () => {
  const [frame] = allWireFrames;
  if (frame === undefined) throw new Error("no frames to check");
  const payload = payloadOf(frame, "test-agent");
  assertEquals(payload.provenance["prov:wasDerivedFrom"], [frame.source]);
  assertEquals(payload.provenance["prov:wasAttributedTo"], "test-agent");
  assertEquals(payload.bytesCodec, frame.codec);
  assertEquals(payload.bytesB64, frame.bytesB64);
});

Deno.test("no recording invents a payload of its own", () => {
  // A fixture that hard-codes `bytesB64` instead of taking one from
  // `wire-frames.ts` would escape the byte comparison above, so the
  // recordings are checked for exactly that.
  const shipped = new Set(allWireFrames.map((f) => f.bytesB64));
  for (const doc of scenarios) {
    for (const obs of observationsOf(doc)) {
      if (obs.kind !== "message-sent" || obs.bytesB64 === undefined) continue;
      assertEquals(
        shipped.has(obs.bytesB64),
        true,
        `${doc.id}/${obs.id} carries bytes no committed frame accounts for`,
      );
      // At least one, not exactly one: a payload owes the reader a
      // source, and a frame reassembled from two would owe two.
      assertEquals(
        (obs.provenance?.["prov:wasDerivedFrom"] ?? []).length > 0,
        true,
        `${doc.id}/${obs.id} carries a payload but names no source file`,
      );
    }
  }
});
