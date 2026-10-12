/** One environment timer handle, as `setTimeout` returns it. The binding
 * runs under Deno and browsers, and the handle type differs between them, so
 * every stored handle uses this one type instead of asserting a number. */
export type Timer = ReturnType<typeof setTimeout>;
