// The check plugin of nix/tests: a model whose id says what the compiled build got right.
//   <greeting>  a plugin dependency, imported by its package name
//   <data>      a file beside this source, located by an explicit Nix patch
//   <ms>        an npm library from the plugin's node_modules
//   loads<n>    how many copies of the dependency were evaluated (1: staged once, though also registered)
//   <tool>      the runtime tool declared by the dependency
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { greeting } from "@pi-bolt-check/helper/greet.ts";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import ms from "ms";

export default function consumer(pi: ExtensionAPI) {
	// This is source text, not an import.meta expression to rewrite.
	const sourceText = "import.meta.url";
	if (sourceText !== ["import", "meta", "url"].join(".")) throw new Error("Source text was rewritten");
	const data = readFileSync(new URL("./data.txt", import.meta.url), "utf8").trim();
	const tool = execFileSync("pi-bolt-check-tool", { encoding: "utf8" }).trim();
	const loads = (globalThis as { __piBoltCheckHelperLoads?: number }).__piBoltCheckHelperLoads;
	pi.registerProvider("pi-bolt-check", {
		baseUrl: "http://127.0.0.1:9",
		apiKey: "none",
		api: "openai-completions",
		models: [
			{
				id: `${greeting()}-${data}-${ms("1h")}-loads${loads}-${tool}`,
				name: "Pi-Bolt Nix check",
				reasoning: false,
				input: ["text"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 1000,
				maxTokens: 100,
			},
		],
	});
}
