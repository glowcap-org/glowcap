/**
 * pump.ts — the single-thread cooperative poll pump.
 *
 * Deno runs the FFI on the isolate's only thread, so a blocking FFI
 * call freezes everything. The pattern (faithful to the Racket
 * `tcp-bridge.rkt`): set a short read timeout on the connection
 * (`set_read_timeout_ms(50)`) so `read_frame` returns WOULD_BLOCK
 * instead of blocking forever, then `await` a `setTimeout` between
 * ticks to hand the event loop back to other tasks.
 *
 * Each tick, per bridge:
 *   1. read one inbound frame (poll-style) → feed_inbound on bytes.
 *   2. step + drain take_outbound → write_frame.
 *   3. inspect session state for completion / close.
 */

import type { Conn } from "./netlayer.ts";
import { Peer } from "./host.ts";
import { PANCAKE_SESSION_CLOSED, PANCAKE_SESSION_OPEN } from "./constants.ts";

export const DEFAULT_READ_TIMEOUT_MS = 50;

/** A peer wired to a connection — the pump's unit of work. */
export interface Bridge {
  peer: Peer;
  conn: Conn;
}

/** Yield to the event loop (the single-thread "between ticks" pause). */
export function yieldToEventLoop(ms = 1): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Step the peer once and drain every pending outbound frame to the wire. */
export function stepAndFlush(peer: Peer, conn: Conn): void {
  peer.step();
  for (let out = peer.takeOutbound(); out !== null; out = peer.takeOutbound()) {
    conn.writeFrame(out);
  }
}

export type InboundStatus = "fed" | "would-block" | "closed" | "malformed";

/** Read one inbound frame (poll-style) and feed it if present. */
export function readAndFeed(peer: Peer, conn: Conn): InboundStatus {
  const frame = conn.readFrame();
  if (frame === "would-block") return "would-block";
  if (frame === "closed") return "closed";
  if (frame === "malformed") return "malformed";
  peer.feedInbound(frame);
  return "fed";
}

/** Run one cooperative tick across all bridges. */
export function tick(bridges: Bridge[]): InboundStatus[] {
  const statuses: InboundStatus[] = [];
  for (const { peer, conn } of bridges) {
    statuses.push(readAndFeed(peer, conn));
    stepAndFlush(peer, conn);
  }
  return statuses;
}

/**
 * Pump the bridges until every peer reaches SESSION_OPEN, a peer
 * closes, or `timeoutMs` elapses. Returns true iff all peers opened.
 */
export async function runUntilAllOpen(
  bridges: Bridge[],
  { timeoutMs = 15_000, yieldMs = 1 }: { timeoutMs?: number; yieldMs?: number } = {},
): Promise<boolean> {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    const statuses = tick(bridges);
    if (statuses.includes("malformed")) {
      throw new Error("pump: malformed inbound frame");
    }
    const states = bridges.map((b) => b.peer.sessionState());
    if (states.every((s) => s === PANCAKE_SESSION_OPEN)) return true;
    if (states.some((s) => s === PANCAKE_SESSION_CLOSED) || statuses.includes("closed")) {
      return false;
    }
    await yieldToEventLoop(yieldMs);
  }
  return false;
}
