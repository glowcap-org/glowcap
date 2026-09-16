// Inspect emitted ESM syntax, independent of the compiler's quote style,
// whitespace, shared-chunk names, and choice of side-effect imports.
import { init, parse } from "es-module-lexer";

await init();

export function bundleGraph(sources: Map<string, string>): Map<string, string[]> {
	const graph = new Map<string, string[]>();
	for (const [name, source] of sources) {
		const dependencies: string[] = [];
		for (const imported of parse(source, name)[0]) {
			if (imported.d === -2) continue; // import.meta is not a module edge.
			const specifier = imported.n;
			// React Router includes a runtime route loader. Computed dynamic
			// imports have no statically knowable target and add no boot edge;
			// browser journeys own evidence for those paths.
			if (specifier == null && imported.d >= 0) continue;
			if (specifier == null) throw new Error(`${name} has an unreadable static module import`);
			if (!/^\.\/[\w.-]+\.js$/.test(specifier)) {
				throw new Error(`${name} retained a non-bundle import ${specifier}`);
			}
			const target = specifier.slice(2);
			if (!sources.has(target)) throw new Error(`${name} imports missing chunk ${target}`);
			if (imported.d === -1) dependencies.push(target);
		}
		graph.set(name, dependencies);
	}
	return graph;
}

export function closure(start: string, graph: Map<string, string[]>): Set<string> {
	const seen = new Set<string>();
	const stack = [start];
	while (stack.length > 0) {
		const name = stack.pop();
		if (name == null || seen.has(name)) continue;
		const dependencies = graph.get(name);
		if (dependencies == null) throw new Error(`missing bundle entry ${name}`);
		seen.add(name);
		stack.push(...dependencies);
	}
	return seen;
}
