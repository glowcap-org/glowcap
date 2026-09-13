// Load the production Rust application once, before any test module runs. The
// Deno batches preload this file; a test that needs the application ready
// before a top-level await of its own imports `initializeApplication` instead.
import { initializeApplication } from "./application.ts";

await initializeApplication();
