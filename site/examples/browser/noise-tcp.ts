import { init } from "@pancake/web";

const stack = await init({
	wasm: fetch("/pancake_host.wasm"),
	// a page cannot open raw TCP, so a relay carries the bytes
	wsUrl: (host, port) => `ws://127.0.0.1:9000/?to=${host}:${port}`,
});

// noise-tcp locator: CapTP is sealed end to end; the relay only sees ciphertext.
const session = await stack.connect("ocapn://…your service's noise-tcp locator…");
const greeter = await session.fetch("greeter");
console.log(await session.send(greeter, "greet", ["world"]));
