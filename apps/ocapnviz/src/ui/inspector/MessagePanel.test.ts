import { assertEquals } from "@std/assert";
import { payloadProps } from "./MessagePanel.tsx";
import { threeVatHandoffMixed } from "../../fixtures/three-vat-handoff-mixed.ts";
import { observationsOf } from "../../engine/temporal/recording-access.ts";

// The Payload group is rendered for every message, so these three
// answers are what a reader actually sees. The bytes staying
// `undefined` is the point of the first test: suppressing the group
// instead is what made a recording with no payloads look like a
// broken viewer.

Deno.test("a message with no recorded frame still reaches the viewer", () => {
  const props = payloadProps(undefined, "syrup");
  assertEquals(props.bytesB64, undefined);
  assertEquals(props.byteLen, undefined);
  assertEquals(props.derivedFrom, undefined);
  // The session's codec is still the answer: it decides how an
  // absent payload's sibling frames would have been spaced, and
  // guessing is not this function's job either way.
  assertEquals(props.codec, "syrup");
});

Deno.test("a recorded frame reaches the viewer whole", () => {
  const props = payloadProps(
    { bytesB64: "U3lydXAh", byteLen: 6, bytesCodec: "syrup" },
    "capnp",
  );
  assertEquals(props.bytesB64, "U3lydXAh");
  assertEquals(props.byteLen, 6);
});

Deno.test("a frame's own codec wins over its session's", () => {
  // The handshake case (ADR-0103): a Cap'n Proto session's
  // `op:start-session` is Syrup, and spacing it in 8-byte words
  // would draw word boundaries a byte grammar does not have.
  const props = payloadProps(
    { bytesB64: "AAAA", byteLen: 3, bytesCodec: "syrup" },
    "capnp",
  );
  assertEquals(props.codec, "syrup");
});

Deno.test("a frame with no stated codec takes its session's", () => {
  const props = payloadProps({ bytesB64: "AAAA", byteLen: 3 }, "capnp");
  assertEquals(props.codec, "capnp");
});

Deno.test("the source of a frame's bytes reaches the viewer", () => {
  const props = payloadProps(
    {
      bytesB64: "AAAA",
      provenance: {
        "prov:wasDerivedFrom": ["test/oracle/corpus/op_deliver.bin"],
      },
    },
    "syrup",
  );
  assertEquals(props.derivedFrom, ["test/oracle/corpus/op_deliver.bin"]);
});

// The headline recording's own claim, checked against the recording
// rather than asserted in its header comment. The Alice-Carol
// session is Cap'n Proto; its handshake is Syrup and its deposit is
// Cap'n Proto, and the Inspector has to say so for either message.
Deno.test("the mixed-codec recording shows both codecs on one session", () => {
  const sent = new Map(
    observationsOf(threeVatHandoffMixed)
      .filter((o) => o.kind === "message-sent")
      .map((o) => [o.messageId, o]),
  );
  const aliceCarolCodec = "capnp";

  const hello = sent.get("ss-alice-carol-out");
  if (hello === undefined) throw new Error("handshake message missing");
  const deposit = sent.get("deposit-gift");
  if (deposit === undefined) throw new Error("deposit message missing");

  // One session carrying both, which is the whole claim. Asserted as the
  // two ids agreeing rather than against a literal: a session's id is the
  // OCapN Session ID, 64 hex digits neither this test nor a reader can
  // recognize on sight, and a copy of it here would only ever be a second
  // spelling to keep in step.
  assertEquals(hello.sessionId, deposit.sessionId);

  const helloProps = payloadProps(hello, aliceCarolCodec);
  assertEquals(helloProps.codec, "syrup");
  assertEquals(typeof helloProps.bytesB64, "string");

  assertEquals(payloadProps(deposit, aliceCarolCodec).codec, "capnp");
});
