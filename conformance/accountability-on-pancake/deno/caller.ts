// Deno caller for the accountability-on-pancake cross-seam demo.
//
// Connects to a running Zig host, generates an Ed25519 identity, signs the
// request with the attestation preimage `invoke|<request>`, and invokes the
// Affordance capability. The host verifies the attestation and returns an
// ack — or refuses an unattested call with a broken promise. Both paths
// are exercised.
//
// Usage:
//   deno run --allow-ffi --allow-read --allow-net caller.ts <port>
//
// Or driven by the demo.ts orchestrator, which starts the Zig host first.

import {
  type AppValue,
  connect,
  far,
  Ref,
} from "../../../bindings/deno/pancake.ts";

const AFFORDANCE_EXPORT = 5n;

function base64urlEncode(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fail(msg: string): never {
  console.error(`FAIL: ${msg}`);
  Deno.exit(1);
}

async function main(): Promise<void> {
  const port = Number(Deno.args[0]);
  if (!port) {
    console.error("usage: caller.ts <port>");
    Deno.exit(2);
  }

  console.log("accountability-on-pancake deno caller");
  console.log(`  connecting to 127.0.0.1:${port}…`);

  // `connect` completes the keyed op:start-session handshake before returning.
  const conn = await connect("127.0.0.1", port);
  conn.serve().catch(() => {}); // the host hanging up ends the serve loop
  conn.peer.registerImport(AFFORDANCE_EXPORT);
  const affordance = new Ref(far(AFFORDANCE_EXPORT), null);

  // Generate an Ed25519 identity (above pancake, just like the Zig side).
  // `generateKey` is typed `CryptoKeyPair | CryptoKey`; an asymmetric algorithm
  // always yields a pair.
  const keyPair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]) as CryptoKeyPair;
  const pubRaw = new Uint8Array(await crypto.subtle.exportKey("raw", keyPair.publicKey));
  const subject = "E" + base64urlEncode(pubRaw);
  const verkey = "D" + base64urlEncode(pubRaw);

  console.log(`  subject (AID): ${subject}`);

  // --- Legitimate invocation -------------------------------------------------
  const request = "read-thermostat";
  const preimage = new TextEncoder().encode(`invoke|${request}`);
  const sigRaw = new Uint8Array(await crypto.subtle.sign("Ed25519", keyPair.privateKey, preimage));
  const sigB64 = base64urlEncode(sigRaw);

  console.log("  sending legitimate invoke…");
  let result: AppValue;
  try {
    result = await conn.send(affordance, "invoke", [subject, verkey, request, sigB64]);
  } catch (err) {
    fail(`legitimate invoke broke: ${err instanceof Error ? err.message : err}`);
  }

  if (typeof result! !== "string" || !result!.startsWith("ack:")) {
    fail(`unexpected result: ${result!}`);
  }
  console.log(`  result: ${result!}`);

  // --- Tampered invocation (should be refused) -------------------------------
  console.log("  sending tampered invoke (should be refused)…");
  const badSig = new Uint8Array(sigRaw);
  badSig[0] ^= 0xff;
  const badSigB64 = base64urlEncode(badSig);

  let refused = false;
  let breakMsg = "";
  try {
    await conn.send(affordance, "invoke", [subject, verkey, request, badSigB64]);
  } catch (err) {
    refused = true;
    breakMsg = err instanceof Error ? err.message : String(err);
  }

  if (!refused) fail("tampered invoke was NOT refused");
  console.log(`  correctly refused: ${breakMsg}`);

  conn.close();
  console.log("\naccountability-on-pancake deno caller OK: same application, two languages.");
}

await main();
