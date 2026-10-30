import http from "node:http";
import type { AddressInfo } from "node:net";
import * as undici from "undici";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type * as Config from "../src/config.ts";
import { configureHttpDispatcher, createBunIdleTimeoutFetch } from "../src/core/http-dispatcher.ts";

vi.mock("../src/config.ts", async (importOriginal) => ({
	...(await importOriginal<typeof Config>()),
	isBunRuntime: true,
}));

// Stands in for Bun's fetch: http-dispatcher.ts takes the global fetch as Bun's own when it loads.
const runtimeFetch = vi.hoisted(() => {
	const nodeFetch = globalThis.fetch;
	const inits: (RequestInit | undefined)[] = [];
	const fetch = (input: RequestInfo | URL, init?: RequestInit) => {
		inits.push(init);
		return nodeFetch(input, init);
	};
	globalThis.fetch = fetch as typeof globalThis.fetch;
	return { nodeFetch, fetch, inits };
});

afterAll(() => {
	globalThis.fetch = runtimeFetch.nodeFetch;
});

describe("http dispatcher on Bun", () => {
	afterEach(() => {
		configureHttpDispatcher();
		runtimeFetch.inits.length = 0;
	});

	it("leaves the global dispatcher and fetch alone with the default timeout", () => {
		const dispatcher = undici.getGlobalDispatcher();
		configureHttpDispatcher();
		expect(undici.getGlobalDispatcher()).toBe(dispatcher);
		expect(globalThis.fetch).toBe(runtimeFetch.fetch);
	});

	it("still rejects an invalid timeout", () => {
		expect(() => configureHttpDispatcher(-1)).toThrow("Invalid HTTP idle timeout: -1");
	});

	// #206: Bun's own 5-minute idle timer ignored httpIdleTimeoutMs, so "disabled" still failed with
	// "The operation timed out." when a slow local model sent nothing for about 6 minutes.
	it("turns off Bun's own idle timer when the timeout is disabled or changed, and restores the default", async () => {
		configureHttpDispatcher(0);
		expect(globalThis.fetch).not.toBe(runtimeFetch.fetch);
		await globalThis.fetch("data:,x");
		expect(runtimeFetch.inits.at(-1)).toMatchObject({ timeout: false });

		configureHttpDispatcher(60_000);
		await globalThis.fetch("data:,x");
		expect(runtimeFetch.inits.at(-1)).toMatchObject({ timeout: false });

		configureHttpDispatcher();
		expect(globalThis.fetch).toBe(runtimeFetch.fetch);
	});

	it("keeps a fetch another module installed", () => {
		const replaced = async () => new Response("replaced");
		globalThis.fetch = replaced as typeof globalThis.fetch;
		try {
			configureHttpDispatcher(0);
			expect(globalThis.fetch).toBe(replaced);
		} finally {
			globalThis.fetch = runtimeFetch.fetch;
		}
	});
});

// #206: the idle timeout Bun's fetch gets instead of its own timer.
describe("Bun idle timeout fetch", () => {
	const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
	let server: http.Server;
	let baseUrl: string;

	beforeAll(async () => {
		server = http.createServer(async (request, response) => {
			const [, headerDelay = "0", gap = "0"] = request.url?.split("/") ?? [];
			await sleep(Number(headerDelay));
			response.writeHead(200, { "content-type": "text/event-stream" });
			response.write("data: 1\n\n");
			await sleep(Number(gap));
			response.end("data: 2\n\n");
		});
		await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
		baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
	});

	afterAll(async () => {
		server.closeAllConnections();
		await new Promise<void>((resolve) => server.close(() => resolve()));
	});

	it("waits for slow headers and a slow stream when disabled", async () => {
		const fetch = createBunIdleTimeoutFetch(runtimeFetch.nodeFetch, 0);
		const response = await fetch(`${baseUrl}/300/300`);
		expect(await response.text()).toBe("data: 1\n\ndata: 2\n\n");
	});

	it("waits for headers and a stream that are slower than Bun's timer but within the timeout", async () => {
		const fetch = createBunIdleTimeoutFetch(runtimeFetch.nodeFetch, 1_000);
		const response = await fetch(`${baseUrl}/300/300`);
		expect(response.status).toBe(200);
		expect(response.url).toBe(`${baseUrl}/300/300`);
		expect(await response.text()).toBe("data: 1\n\ndata: 2\n\n");
	});

	it("fails when the headers take longer than the timeout", async () => {
		const fetch = createBunIdleTimeoutFetch(runtimeFetch.nodeFetch, 100);
		await expect(fetch(`${baseUrl}/1000/0`)).rejects.toMatchObject({
			name: "TimeoutError",
			message: "No data from the server for 0.1 s (HTTP idle timeout)",
		});
	});

	it("fails when the stream stalls longer than the timeout", async () => {
		const fetch = createBunIdleTimeoutFetch(runtimeFetch.nodeFetch, 100);
		const response = await fetch(`${baseUrl}/0/1000`);
		const reader = (response.body as ReadableStream<Uint8Array>).getReader();
		expect(new TextDecoder().decode((await reader.read()).value)).toBe("data: 1\n\n");
		await expect(reader.read()).rejects.toMatchObject({ name: "TimeoutError" });
	});

	it("does not count the time the reader spends between reads", async () => {
		const fetch = createBunIdleTimeoutFetch(runtimeFetch.nodeFetch, 200);
		const response = await fetch(`${baseUrl}/0/0`);
		await sleep(400);
		expect(await response.text()).toBe("data: 1\n\ndata: 2\n\n");
	});

	it("still ends the request when the caller aborts", async () => {
		const fetch = createBunIdleTimeoutFetch(runtimeFetch.nodeFetch, 0);
		const controller = new AbortController();
		const request = fetch(`${baseUrl}/1000/0`, { signal: controller.signal });
		controller.abort();
		await expect(request).rejects.toMatchObject({ name: "AbortError" });
	});
});
