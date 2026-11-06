// Mycelium's drawing and recurring light share one activity lifetime.
// Hidden pages, reduced motion, and device loss cancel every scheduled tick.
// Dimming stops ambient light and breathing but keeps pointer responses.

interface Effects {
	ready(): boolean;
	frame(now: number): boolean;
	ambient(): void;
	breath(now: number): void;
	suspend(): void;
	resume(): void;
}

export class Activity {
	readonly #motion = matchMedia("(prefers-reduced-motion: reduce)");
	#stopped = false;
	#dimmed = false;
	#frame = 0;
	#ambient: ReturnType<typeof setTimeout> | undefined;
	#breathing: ReturnType<typeof setTimeout> | undefined;

	constructor(private readonly effects: Effects) {
		document.addEventListener("visibilitychange", this.refresh);
		this.#motion.addEventListener("change", this.refresh);
	}

	get active(): boolean {
		return !this.#stopped && !document.hidden && !this.#motion.matches && this.effects.ready();
	}

	readonly refresh = () => {
		if (this.#stopped) return;
		this.cancelFrame();
		this.cancelBreath();
		clearTimeout(this.#ambient);
		this.effects.suspend();
		if (this.active) this.effects.resume();
	};

	wake(): void {
		if (!this.active || this.#frame !== 0) return;
		this.#frame = requestAnimationFrame((now) => {
			this.#frame = 0;
			if (this.active && this.effects.frame(now)) this.wake();
		});
	}

	cancelFrame(): void {
		cancelAnimationFrame(this.#frame);
		this.#frame = 0;
	}

	scheduleAmbient(delay = 2200 + Math.random() * 3800): void {
		clearTimeout(this.#ambient);
		if (!this.active || this.#dimmed) return;
		this.#ambient = setTimeout(() => {
			if (!this.active || this.#dimmed) return;
			this.effects.ambient();
			this.scheduleAmbient();
		}, delay);
	}

	breathe(): void {
		this.cancelBreath();
		if (!this.active || this.#dimmed) return;
		this.effects.breath(performance.now());
		// At the steepest part of a breath, opacity changes by one 8-bit
		// channel step in 125 ms. Faster ticks would repeat the same shade.
		this.#breathing = setTimeout(() => this.breathe(), 125);
	}

	cancelBreath(): void {
		clearTimeout(this.#breathing);
	}

	setDimmed(dimmed: boolean): void {
		this.#dimmed = dimmed;
		if (dimmed) {
			clearTimeout(this.#ambient);
			this.cancelBreath();
		}
	}

	stop(): void {
		this.#stopped = true;
		this.cancelFrame();
		this.cancelBreath();
		clearTimeout(this.#ambient);
		document.removeEventListener("visibilitychange", this.refresh);
		this.#motion.removeEventListener("change", this.refresh);
	}
}
