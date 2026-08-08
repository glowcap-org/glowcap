// Print the Chromium executable path the pinned Playwright expects.
//
// `playwright-preflight.sh` compares this against what is on disk. Playwright
// names its browser by an internal build number that moves with the library, so
// only Playwright itself can say which directory a given version will look in.
// Asking it here is what lets the preflight tell a stale image apart from a
// missing one, and give each its own remedy.
//
// Resolution comes from the root `deno.json` import map, the same specifier the
// browser proofs use, so this cannot drift from what they load.

import { chromium } from "playwright";

console.log(chromium.executablePath());
