// The `matchMedia` the UI reads while its modules load.
//
// Deno has no window, and the page projection, hooks, and mark modules ask
// `matchMedia` for the viewport and motion preferences as they evaluate. A
// test imports this first, before anything under `web/ui/`, so the stub exists
// when those modules run. It answers "no match" with listeners that never fire;
// a test that needs another answer installs its own.

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
