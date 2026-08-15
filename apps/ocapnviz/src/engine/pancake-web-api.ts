/** The narrow browser-runtime surface Live mode consumes. This type-only module
 * is the product boundary: ocapnviz does not inherit the binding workspace's
 * compiler policy, and Vite still resolves the implementation to @pancake/web. */
export type BrowserSession = {
  serve: () => Promise<void>;
  spawn: (
    behavior: (verb: string, args: readonly unknown[]) => unknown,
  ) => unknown;
  enliven: (sturdyref: string) => Promise<unknown>;
  send: (
    target: unknown,
    verb: string,
    args: readonly unknown[],
  ) => PromiseLike<unknown>;
  close: () => void | Promise<void>;
};

export type BrowserLocator = {
  transport: string;
  designator: string;
  hints: Map<string, unknown>;
  hintWireForm: "map" | "boolean-false";
};

export type BrowserRuntime = {
  connect: (locator: BrowserLocator) => Promise<BrowserSession>;
  parseSturdyRef: (
    sturdyref: string,
    captpVersion: "v1_0" | "next",
  ) => { locator: BrowserLocator };
};

export type PancakeWebModule = {
  init: (options: { wasm: Promise<Response> }) => Promise<BrowserRuntime>;
};
