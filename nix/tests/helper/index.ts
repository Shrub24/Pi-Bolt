import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { greeting } from "./greet.ts";

export default function helper(pi: ExtensionAPI) {
	pi.registerCommand("greet", { description: "Greets", handler: async () => console.log(greeting()) });
}
