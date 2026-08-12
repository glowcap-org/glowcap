// Binding-internal iroh dial behind `@pancake/stack`'s `connect(locator)`.
// Not part of the application contract — do not import from application code.

export { _connectIroh, _ensureIrohProvider } from "./impl.ts";
