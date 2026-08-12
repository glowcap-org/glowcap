declare module "virtual:pancake-web" {
  export const init:
    import("./engine/pancake-web-api.ts").PancakeWebModule["init"];
}
