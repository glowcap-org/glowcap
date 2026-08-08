/**
 * Playback clock — simulated time decoupled from wall time. The
 * caller passes `wallDt` to `tick()`; the clock never reads
 * `performance.now()` itself. That keeps the engine deterministic
 * and lets tests drive a fixed timestep.
 */

export type PlaybackState = "paused" | "playing";

export type ClockSnapshot = {
  /** Simulated time, in milliseconds since the timeline's t=0. */
  t: number;
  state: PlaybackState;
  /** Multiplier applied to wallDt when computing sim dt. */
  speed: number;
  /** Inclusive upper bound on `t` (the document's duration). */
  duration: number;
};

/** UI-exposed speeds. `setSpeed` accepts any positive number. */
export const SPEED_PRESETS = [0.25, 0.5, 1, 2, 4] as const;

export class Clock {
  #t = 0;
  #state: PlaybackState = "paused";
  #speed = 1;
  #duration: number;
  // Cached snapshot for referential stability with
  // `useSyncExternalStore`. Mutators invalidate; reads rebuild lazily.
  #snapshotCache: ClockSnapshot | null = null;

  constructor(duration: number) {
    if (!Number.isFinite(duration) || duration < 0) {
      throw new RangeError(
        `Clock duration must be a non-negative finite number; got ${duration}`,
      );
    }
    this.#duration = duration;
  }

  get t(): number {
    return this.#t;
  }
  get state(): PlaybackState {
    return this.#state;
  }
  get speed(): number {
    return this.#speed;
  }
  get duration(): number {
    return this.#duration;
  }
  get isAtEnd(): boolean {
    return this.#t >= this.#duration;
  }

  snapshot(): ClockSnapshot {
    if (this.#snapshotCache === null) {
      this.#snapshotCache = {
        t: this.#t,
        state: this.#state,
        speed: this.#speed,
        duration: this.#duration,
      };
    }
    return this.#snapshotCache;
  }

  #invalidate(): void {
    this.#snapshotCache = null;
  }

  /** Start playing. Does NOT rewind `t` — "play after end →
   * restart" is engine-level, because rewinding the clock without
   * rewinding the world leaves the simulation inconsistent. */
  play(): void {
    this.#state = "playing";
    this.#invalidate();
  }
  pause(): void {
    this.#state = "paused";
    this.#invalidate();
  }
  toggle(): void {
    if (this.#state === "playing") this.pause();
    else this.play();
  }
  restart(): void {
    this.#t = 0;
    this.#state = "paused";
    this.#invalidate();
  }
  /** Jump to `t`, clamped to `[0, duration]`. Preserves playback state. */
  seekTo(t: number): void {
    if (!Number.isFinite(t)) {
      throw new RangeError(`seekTo target must be finite; got ${t}`);
    }
    this.#t = Math.max(0, Math.min(this.#duration, t));
    this.#invalidate();
  }
  setSpeed(speed: number): void {
    if (!Number.isFinite(speed) || speed <= 0) {
      throw new RangeError(`speed must be > 0; got ${speed}`);
    }
    this.#speed = speed;
    this.#invalidate();
  }
  /** Extend (or shrink) the playable upper bound. Build mode calls
   * this when authored events land past the previous duration. */
  setDuration(duration: number): void {
    if (!Number.isFinite(duration) || duration < 0) {
      throw new RangeError(
        `Clock duration must be a non-negative finite number; got ${duration}`,
      );
    }
    this.#duration = duration;
    if (this.#t > duration) this.#t = duration;
    this.#invalidate();
  }

  /**
   * Advance by `wallDt` ms; return the elapsed simulated dt
   * (`0` when paused). Pins `t` at `duration` and pauses there.
   */
  tick(wallDt: number): number {
    if (this.#state !== "playing") return 0;
    if (!Number.isFinite(wallDt) || wallDt < 0) {
      throw new RangeError(
        `wallDt must be a non-negative number; got ${wallDt}`,
      );
    }
    const next = Math.min(this.#duration, this.#t + wallDt * this.#speed);
    const simDt = next - this.#t;
    this.#t = next;
    if (this.isAtEnd) this.#state = "paused";
    this.#invalidate();
    return simDt;
  }
}
