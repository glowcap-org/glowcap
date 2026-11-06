/**
 * Binding-only iroh dialing helpers used by transport composition.
 * Applications configure `provider` or `connector` from `@glowcap/iroh` and dial
 * through `Runtime.connect` instead of calling these helpers.
 *
 * @module
 */

export { _connectIroh, _ensureIrohProvider } from "./impl.ts";
