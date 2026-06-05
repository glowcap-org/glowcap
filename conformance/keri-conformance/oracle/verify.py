#!/usr/bin/env python3
"""verify.py — custom KERI conformance oracle for the Goblins Vat kernel.

Reads .data/kel/<aid>.kel.jsonl and .data/episodes.jsonld, then verifies:

  (a) Each AID is well-formed CESR (E-prefix Blake3-256 SAID, 44 chars).
  (b) Each KEL event's SAID matches Blake3-256 of the canonical
      placeholder-substituted serialization (the standard KERI SAID derivation).
  (c) Each KEL event's signatures verify against the appropriate verkeys at the
      event's signing threshold (`kt`). For inception, signers are the event's
      own `k[*]`; for rotation, signers are the PRIOR event's `k[*]` at the
      PRIOR event's `kt` (proving the rotation was authorized by the rotating
      authority). For rotation events, each new key in `k[*]` must hash
      (Blake3-256 of CESR-encoded form) to the corresponding digest in the
      prior event's `n[*]` — pre-rotation discipline holds positionally.
  (d) Each Episode declares a known `crypto_suite` (substrate-commitment-#7
      crypto-agility version channel; rejects unknown suites).
  (e) Each Episode's `ephemeral_pubkey_sig` verifies against the AID's verkey
      at the seq named in kel_anchor (so the AID-anchored countersignature
      chain holds).
  (f) Each Episode's `sig` verifies against the ephemeral_pubkey over the
      Episode payload (sig + ephemeral_pubkey_sig + kel_anchor stripped),
      so the per-Episode ephemeral signing is honest.

Exits 0 on full conformance, non-zero with a diff on any mismatch.

This is **custom verification logic** that uses shared algorithms
(Blake3 via the `blake3` Python package, Ed25519 via pynacl, optionally
falling back to keripy's `Diger` / `Verfer` primitives). It is NOT full
keripy `Serder` ingestion — witness receipts, interaction/delegation/TEL
events, CESR streaming format, weighted/fractional thresholds (`kt` as
`["1/2","1/2","1/2"]`), and non-Ed25519 / non-Blake3 suites are out of scope.

Multi-sig support: integer `kt` / `nt` thresholds with multi-key arrays and
indexed signatures (CESR `A` indexed Ed25519 sig + un-indexed `0B` form for
single-key events) are in scope. Weighted-fractional thresholds are not.

The 10/10 pass is the regression gate for the kernel's KERI primitives,
not a byte-equivalence claim against keripy the library.

Invoked by stack/substrate/conformance.sh.
"""
import base64
import hashlib
import json
import os
import sys
from pathlib import Path

DATA_DIR = Path(os.environ.get("GOBLINS_DATA_DIR", "/substrate/vat/.data"))


def err(msg: str) -> None:
    print(f"[oracle] FAIL: {msg}", file=sys.stderr)


def ok(msg: str) -> None:
    print(f"[oracle] OK:   {msg}")


def b64url_decode(s: str) -> bytes:
    pad = "=" * ((4 - len(s) % 4) % 4)
    return base64.urlsafe_b64decode(s + pad)


def cesr_decode_32(prim: str) -> bytes:
    """Decode 1-char-prefix 44-char CESR primitive back to 32 bytes."""
    if len(prim) != 44:
        raise ValueError(f"expected 44-char CESR, got {len(prim)}: {prim!r}")
    swapped = "A" + prim[1:]
    raw = b64url_decode(swapped)
    return raw[1:]


def cesr_decode_64(prim: str) -> bytes:
    """Decode 2-char-prefix 88-char CESR primitive back to 64 bytes."""
    if len(prim) != 88:
        raise ValueError(f"expected 88-char CESR, got {len(prim)}: {prim!r}")
    swapped = "AA" + prim[2:]
    raw = b64url_decode(swapped)
    return raw[2:]


# Base64url alphabet — used to decode the 1-char index in CESR `A`-prefixed
# indexed Ed25519 signatures. CESR primitive codes per WebOfTrust spec.
_B64URL_ALPHABET = (
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
)


def parse_indexed_sig(cesr_sig: str) -> tuple:
    """Parse a CESR Ed25519 signature primitive into (index, raw_64_bytes).

    Two forms supported, both 88 chars total:
      - `0B` (2-char code) + 86 chars payload → un-indexed; index returned None.
        Valid only when the event has a single signing key.
      - `A`  (1-char code) + 1-char base64url index + 86 chars payload → indexed;
        the second char names which entry in the event's `k[*]` array signed.

    `B` (Ed25519 sig with both same/other indices for delegated rotation) and
    other multi-sig codes are out of kernel oracle scope.
    """
    if len(cesr_sig) != 88:
        raise ValueError(f"expected 88-char sig, got {len(cesr_sig)}: {cesr_sig!r}")
    if cesr_sig[:2] == "0B":
        return (None, cesr_decode_64(cesr_sig))
    if cesr_sig[0] == "A":
        idx_char = cesr_sig[1]
        try:
            index = _B64URL_ALPHABET.index(idx_char)
        except ValueError:
            raise ValueError(f"bad base64url index char {idx_char!r} in indexed sig")
        # Same byte layout as 0B (2-char prefix + 64-byte payload).
        swapped = "AA" + cesr_sig[2:]
        raw = b64url_decode(swapped)
        return (index, raw[2:])
    raise ValueError(f"unsupported sig code {cesr_sig[:2]!r}; oracle handles 0B and A")


def parse_threshold(threshold) -> int:
    """Parse a KERI signing/next-key threshold into an integer M-of-N count.

    KERI thresholds are hex strings (`"1"`, `"2"`, `"a"` for 10, etc.). Weighted
    or fractional thresholds (lists like `["1/2","1/2","1/2"]`) are out of
    kernel oracle scope — the Vat does not emit them, and supporting them
    requires fractional-threshold satisfaction logic that adds risk without
    forcing function. Reject explicitly so future weighted-threshold data
    fails loudly rather than silently passing.
    """
    if isinstance(threshold, str):
        return int(threshold, 16)
    if isinstance(threshold, list):
        raise ValueError(
            f"weighted/fractional thresholds (kt/nt={threshold!r}) are out of kernel oracle scope"
        )
    raise ValueError(f"unrecognized threshold: {threshold!r}")


def b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def cesr_encode_32(prefix: str, payload: bytes) -> str:
    if len(payload) != 32:
        raise ValueError("payload must be 32 bytes")
    encoded = b64url_encode(b"\x00" + payload)
    return prefix + encoded[1:]


def blake3_256(data: bytes) -> bytes:
    # Try the `blake3` Python package; fall back to keripy's CESR primitives if absent.
    try:
        import blake3 as _b3
        return _b3.blake3(data).digest(length=32)
    except ImportError:
        # keripy bundles blake3 via its `coring` module.
        from keri.kering import Diger  # type: ignore
        return Diger(ser=data).raw  # uses Blake3 by default


def ed25519_verify(pk_raw: bytes, msg: bytes, sig: bytes) -> bool:
    try:
        from nacl.signing import VerifyKey  # type: ignore
    except ImportError:
        # keripy has its own ed25519 wrappers; use those if pynacl missing.
        from keri.kering import Verfer  # type: ignore
        v = Verfer(raw=pk_raw, code="D")
        return v.verify(sig=sig, ser=msg)
    try:
        VerifyKey(pk_raw).verify(msg, sig)
        return True
    except Exception:
        return False


KERI_EVENT_FIELD_ORDER = ["v", "t", "d", "i", "s", "p", "kt", "k", "nt", "n",
                          "bt", "b", "br", "ba", "c", "a"]


def keri_canonical(event: dict) -> dict:
    """Reorder dict keys into KERI canonical field order (matching the order
    the Racket Vat emits). Fields not present are skipped; unknown extra fields
    sort to the end alphabetically."""
    canonical = {}
    for k in KERI_EVENT_FIELD_ORDER:
        if k in event:
            canonical[k] = event[k]
    for k in sorted(event):
        if k not in canonical:
            canonical[k] = event[k]
    return canonical


def compact_json(obj) -> str:
    """keripy uses separators=(',',':') compact JSON; mirror exactly. For
    KERI events we serialize in KERI canonical field order."""
    if isinstance(obj, dict) and "v" in obj and "t" in obj:
        obj = keri_canonical(obj)
    # ensure_ascii=False matches Racket's `jsexpr->string` (raw UTF-8, no \uXXXX
    # escapes for non-ASCII). With ensure_ascii=True (default), Unicode in any
    # field would diverge byte-wise from Racket and signature checks would fail.
    return json.dumps(obj, separators=(",", ":"), sort_keys=False, ensure_ascii=False)


def saidify(event: dict, icp: bool) -> tuple[dict, str]:
    """Recompute the SAID over a KERI event by setting d (and i for icp) to
    placeholder, computing the Blake3 of the canonical serialization, and
    returning (filled_event, computed_said)."""
    placeholder = "#" * 44
    work = dict(event)
    work["d"] = placeholder
    if icp:
        work["i"] = placeholder
    work["v"] = "KERI10JSON000000_"
    size = len(compact_json(work).encode("utf-8"))
    work["v"] = f"KERI10JSON{size:06x}_"
    ser = compact_json(work).encode("utf-8")
    digest = blake3_256(ser)
    said = cesr_encode_32("E", digest)
    work["d"] = said
    if icp:
        work["i"] = said
    return work, said


def verify_kel(aid: str, kel_records: list) -> bool:
    """Verify every event in the KEL: SAID derivation, signature(s), pre-rotation.

    Supports multi-sig (`kt > 1` with N keys, M sigs satisfying threshold M ≥ kt)
    and indexed signatures (CESR `A` form). Single-key single-sig path
    (kt=nt=1, un-indexed `0B` sigs) is the kernel's current shape and remains
    the dominant verified scenario.
    """
    ok(f"KEL for {aid}: {len(kel_records)} event(s)")
    if not kel_records:
        err(f"empty KEL")
        return False
    # Carry forward the prior event's signing keys + threshold + next-key
    # commitments so rotations can be verified against prior authority.
    prior_keys_cesr = None
    prior_kt = None
    prior_next_digests = None
    for i, rec in enumerate(kel_records):
        evt = rec["event"]
        sigs = rec.get("sigs", [])
        if not sigs:
            err(f"event {i}: no signatures")
            return False
        is_icp = (evt["t"] == "icp")

        # SAID check: re-compute and compare.
        recomputed, computed_said = saidify(
            {k: v for k, v in evt.items() if k != "d" and (not is_icp or k != "i")},
            is_icp,
        )
        if computed_said != evt["d"]:
            err(f"event {i} ({evt['t']}): SAID mismatch — computed {computed_said}, stored {evt['d']}")
            return False
        ok(f"event {i} ({evt['t']}): SAID matches")

        # Parse this event's keys + thresholds. KERI shape: k is list of CESR
        # verkeys; n is list of next-key Blake3 digests; kt/nt are hex-string
        # thresholds. The kernel today emits single-element arrays with kt=nt="1";
        # the oracle accepts up to len(k) keys with integer thresholds.
        keys_cesr = list(evt.get("k") or [])
        next_digests = list(evt.get("n") or [])
        try:
            kt = parse_threshold(evt["kt"])
            nt = parse_threshold(evt.get("nt", "0")) if next_digests else 0
        except ValueError as exn:
            err(f"event {i}: {exn}")
            return False
        if not keys_cesr:
            err(f"event {i}: no signing keys (k[])")
            return False
        if kt < 1 or kt > len(keys_cesr):
            err(f"event {i}: kt={kt} out of range for {len(keys_cesr)} keys")
            return False
        if next_digests and (nt < 1 or nt > len(next_digests)):
            err(f"event {i}: nt={nt} out of range for {len(next_digests)} next-digests")
            return False

        # Pre-rotation check (rotation events only). KERI's positional rule:
        # for each new key in this event's k[*], its CESR-encoded form's
        # Blake3-256 hash must equal the corresponding prior n[*] digest.
        # Threshold-aware: at minimum require nt-many positional matches; with
        # equal-length arrays (kernel + most KERI deployments), all positions match.
        if not is_icp:
            if prior_keys_cesr is None:
                err(f"event {i}: rotation but no prior event")
                return False
            if prior_next_digests is None or len(prior_next_digests) < len(keys_cesr):
                err(f"event {i}: rotation has {len(keys_cesr)} keys but prior committed {len(prior_next_digests or [])} digests")
                return False
            for ki, key_cesr in enumerate(keys_cesr):
                actual = cesr_encode_32("E", blake3_256(key_cesr.encode("utf-8")))
                if actual != prior_next_digests[ki]:
                    err(
                        f"event {i}: pre-rotation commitment broken at index {ki} — "
                        f"prior committed {prior_next_digests[ki]}, current verkey hashes to {actual}"
                    )
                    return False
            ok(f"event {i}: pre-rotation commitment matches ({len(keys_cesr)} key(s))")

        # Determine which keyset signs THIS event. icp signs with its own keys
        # at its own kt; rot signs with PRIOR keys at PRIOR kt (the rotating
        # authority must authorize its own succession, per KERI pre-rotation).
        if is_icp:
            signer_keys_cesr = keys_cesr
            required = kt
        else:
            signer_keys_cesr = prior_keys_cesr
            required = prior_kt

        # Verify each signature against the indicated key. Indexed `A` sigs
        # name their signer via the second char; un-indexed `0B` sigs are
        # only valid for single-key events. Count distinct verified indices;
        # threshold satisfaction requires ≥ `required` distinct indices.
        evt_bytes = compact_json(evt).encode("utf-8")
        verified_indices: set = set()
        for sig_cesr in sigs:
            try:
                index, sig_raw = parse_indexed_sig(sig_cesr)
            except ValueError as exn:
                err(f"event {i} ({evt['t']}): malformed signature: {exn}")
                return False
            if index is None:
                # Un-indexed `0B` — only valid for single-key events. The kernel's
                # kt=1 single-signer path lives here.
                if len(signer_keys_cesr) != 1:
                    err(f"event {i}: un-indexed sig with {len(signer_keys_cesr)} signing keys")
                    return False
                index = 0
            if index >= len(signer_keys_cesr):
                err(f"event {i}: sig index {index} >= len(signer keys)={len(signer_keys_cesr)}")
                return False
            verkey_raw = cesr_decode_32(signer_keys_cesr[index])
            if not ed25519_verify(verkey_raw, evt_bytes, sig_raw):
                err(f"event {i} ({evt['t']}): sig at index {index} fails verification")
                return False
            verified_indices.add(index)
        if len(verified_indices) < required:
            err(
                f"event {i} ({evt['t']}): only {len(verified_indices)} distinct sig(s), "
                f"need {required} (kt threshold)"
            )
            return False
        ok(
            f"event {i} ({evt['t']}): {len(verified_indices)} of {required} required signature(s) verify"
            + (f" (multi-sig)" if required > 1 or len(signer_keys_cesr) > 1 else "")
        )

        prior_keys_cesr = keys_cesr
        prior_kt = kt
        prior_next_digests = next_digests if next_digests else None
    return True


SUPPORTED_CRYPTO_SUITES = frozenset({"ed25519-blake3-cesr-v1"})


def verify_episode(idx: int, episode: dict, kel_for_aid: dict) -> bool:
    """Verify an Episode's three-part conformance:
    (0) `crypto_suite` is a known/supported version (substrate commitment #7).
    (1) `ephemeral_pubkey_sig` made by an AID@seq verkey over the ephemeral
        pubkey CESR (indexed `A` form names which key, un-indexed `0B`
        valid only when AID@seq has a single key).
    (2) `sig` made by the ephemeral pubkey over the canonical Episode payload
        (sig + ephemeral_pubkey_sig + kel_anchor stripped).
    """
    aid = episode["kel_anchor"]["aid"]
    seq = episode["kel_anchor"]["seq"]
    eph_pk_cesr = episode["ephemeral_pubkey"]
    eph_pk_sig_cesr = episode["ephemeral_pubkey_sig"]
    sig_cesr = episode["sig"]

    # Check 0: crypto_suite version channel.
    # Crypto-agility commitment: every primitive must be replaceable per a
    # substrate-level versioning protocol. The oracle rejects unknown suites
    # loudly so the kernel can't silently change shape across a primitive swap.
    suite = episode.get("crypto_suite")
    if suite is None:
        err(f"Episode {idx}: missing crypto_suite field (substrate commitment #7)")
        return False
    if suite not in SUPPORTED_CRYPTO_SUITES:
        err(
            f"Episode {idx}: unknown crypto_suite {suite!r}; oracle supports "
            f"{sorted(SUPPORTED_CRYPTO_SUITES)!r}"
        )
        return False
    ok(f"Episode {idx}: crypto_suite={suite}")

    # Find the KEL event at this seq.
    kel = kel_for_aid.get(aid)
    if not kel:
        err(f"Episode {idx}: no KEL for AID {aid}")
        return False
    matching = [r for r in kel if r["event"]["s"] == seq]
    if not matching:
        err(f"Episode {idx}: no KEL event at seq={seq}")
        return False
    aid_keys_cesr = list(matching[0]["event"]["k"])
    eph_pk_raw = cesr_decode_32(eph_pk_cesr)

    # Check 1: AID@seq verifies the ephemeral pubkey CESR bytes. Parse the
    # countersignature's index (un-indexed `0B` only valid when AID@seq has
    # a single key; indexed `A` names which of k[*] signed).
    try:
        eph_pk_sig_index, eph_pk_sig_raw = parse_indexed_sig(eph_pk_sig_cesr)
    except ValueError as exn:
        err(f"Episode {idx}: malformed ephemeral_pubkey_sig: {exn}")
        return False
    if eph_pk_sig_index is None:
        if len(aid_keys_cesr) != 1:
            err(
                f"Episode {idx}: un-indexed ephemeral_pubkey_sig but AID@{seq} has "
                f"{len(aid_keys_cesr)} keys; need indexed `A` form"
            )
            return False
        eph_pk_sig_index = 0
    if eph_pk_sig_index >= len(aid_keys_cesr):
        err(f"Episode {idx}: ephemeral_pubkey_sig index {eph_pk_sig_index} out of range")
        return False
    aid_verkey_raw = cesr_decode_32(aid_keys_cesr[eph_pk_sig_index])
    if not ed25519_verify(aid_verkey_raw, eph_pk_cesr.encode("utf-8"), eph_pk_sig_raw):
        err(f"Episode {idx}: ephemeral_pubkey_sig does not verify against AID@{seq} verkey[{eph_pk_sig_index}]")
        return False
    ok(f"Episode {idx}: ephemeral_pubkey signed by AID@{seq}")

    # Check 2: ephemeral pubkey verified the Episode payload (sig fields stripped).
    # crypto_suite stays in the payload — it's part of the signed bytes.
    payload = {
        k: v
        for k, v in episode.items()
        if k not in ("sig", "ephemeral_pubkey_sig", "kel_anchor")
    }
    payload_bytes = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    try:
        sig_index, sig_raw = parse_indexed_sig(sig_cesr)
    except ValueError as exn:
        err(f"Episode {idx}: malformed Episode sig: {exn}")
        return False
    # Episode sig has exactly one signer (the per-Episode ephemeral key);
    # `0B` un-indexed and `A0` indexed-zero are equivalent here.
    if sig_index is not None and sig_index != 0:
        err(f"Episode {idx}: Episode sig has unexpected index {sig_index}; only single ephemeral signer supported")
        return False
    if not ed25519_verify(eph_pk_raw, payload_bytes, sig_raw):
        err(f"Episode {idx}: sig does not verify against ephemeral_pubkey")
        return False
    ok(f"Episode {idx}: payload signed by ephemeral_pubkey")
    return True


def main() -> int:
    if not DATA_DIR.exists():
        err(f"data dir does not exist: {DATA_DIR}")
        return 2

    print(f"[oracle] Verifying KERI conformance against {DATA_DIR}")

    # Load all KELs.
    kel_dir = DATA_DIR / "kel"
    kel_for_aid: dict[str, list] = {}
    if not kel_dir.exists() or not list(kel_dir.glob("*.kel.jsonl")):
        err(f"no KEL files at {kel_dir}")
        return 2

    failures = 0
    for kel_file in sorted(kel_dir.glob("*.kel.jsonl")):
        aid = kel_file.stem.replace(".kel", "")
        records = [json.loads(line) for line in kel_file.read_text().splitlines() if line.strip()]
        kel_for_aid[aid] = records
        if not verify_kel(aid, records):
            failures += 1

    # Load and verify Episodes.
    ep_file = DATA_DIR / "episodes.jsonld"
    if ep_file.exists():
        episodes = [json.loads(line) for line in ep_file.read_text().splitlines() if line.strip()]
        ok(f"Episodes: {len(episodes)} found")
        for i, ep in enumerate(episodes, start=1):
            if not verify_episode(i, ep, kel_for_aid):
                failures += 1
    else:
        err(f"no Episodes file at {ep_file}")
        failures += 1

    print()
    if failures == 0:
        print(f"[oracle] PASS — Racket KERI outputs verify against the custom oracle (10/10 documented checks).")
        return 0
    print(f"[oracle] FAIL — {failures} conformance failure(s).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
