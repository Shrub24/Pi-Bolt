// Counts how many copies of this module the executable evaluates: compiled in, a plugin dependency is staged once and shared.
const loads = ((globalThis as { __piBoltCheckHelperLoads?: number }).__piBoltCheckHelperLoads ?? 0) + 1;
(globalThis as { __piBoltCheckHelperLoads?: number }).__piBoltCheckHelperLoads = loads;

export function greeting(): string {
	return "hello";
}
