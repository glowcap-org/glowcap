// The second entry: the mycelium under the page. It is small and loads
// alongside page.js, so on a slow connection the threads come up under the
// opening screen while the rest of the page is still on its way.
import { startMycelium } from "./mycelium.ts";
import { holdGround } from "./ground_link.ts";

holdGround(startMycelium({ arriving: true }));
