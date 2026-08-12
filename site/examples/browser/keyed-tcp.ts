import { init } from "@pancake/web";

const stack = await init({
	wasm: fetch("/pancake_host.wasm"),
	// a page cannot open raw TCP, so a relay carries the bytes
	wsUrl: (host, port) => `ws://127.0.0.1:9000/?to=${host}:${port}`,
});

// keyed-tcp locator (cleartext CapTP through the relay). Prefer noise-tcp
// when the page needs a sealed path — same paste, different transport symbol.
const session = await stack.connect("ocapn://…your service's keyed-tcp locator…");
const greeter = await session.fetch("greeter");
console.log(await session.send(greeter, "greet", ["world"]));
