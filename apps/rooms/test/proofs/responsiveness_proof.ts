// Independent transport and presentation proof: its slow traffic does not
// consume the unrelated whole-page journey's deadline.
import { type Browser, chromium } from "playwright";
import { run } from "../page/responsiveness.ts";
import { fail, freePort, ROOT, waitForHttp } from "../page/harness.ts";
import { spawnWeb } from "../support/web_front.ts";
import { reapOwned } from "../support/children.ts";

const port = freePort();
// This proof measures rendering a 64-post burst after warm-up, separately from
// policy acceptance. Both dispatch and browser mediation must admit its posts
// and separately guarded projections through the shipped configuration.
spawnWeb({
	args: [
		"--transport=tcp",
		"--admission-rates=message=256/512",
		"--browser-admission-rates=message=256/512",
		String(port),
		String(freePort()),
	],
	cwd: ROOT,
	stdout: "null",
	stderr: "inherit",
});
const deadline = setTimeout(() => fail("responsiveness proof timed out after 150s"), 150_000);
let browser: Browser | null = null;
try {
	await waitForHttp(port);
	browser = await chromium.launch({ args: ["--no-sandbox"] });
	await run(browser, port);
} finally {
	clearTimeout(deadline);
	await browser?.close();
	await reapOwned();
}
