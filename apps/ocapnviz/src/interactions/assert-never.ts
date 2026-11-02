/** The `default` arm of a switch over a closed union. The type checker proves
 * the switch is total, and the throw covers a value that escaped it. */
export function assertNever(x: never): never {
	throw new Error(`unhandled discriminant: ${JSON.stringify(x)}`);
}
