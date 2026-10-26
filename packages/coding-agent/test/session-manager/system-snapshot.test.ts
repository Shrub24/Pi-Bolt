import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { type CompactionEntry, SessionManager } from "../../src/core/session-manager.ts";
import { assistantMsg, userMsg } from "../utilities.ts";

const SNAPSHOT_RECORD = "pi-bolt:system-snapshot";

function systemMsg(content: string, timestamp: number, sections?: Record<string, string>) {
	return { role: "system" as const, content, sections, timestamp };
}

/** Records of the snapshot storage type in a session file, in file order. */
function snapshotRecords(file: string): Array<{ id: string }> {
	return readFileSync(file, "utf8")
		.split("\n")
		.filter((line) => line.trim())
		.map((line) => JSON.parse(line) as { type: string; id: string })
		.filter((record) => record.type === SNAPSHOT_RECORD);
}

function compactions(session: SessionManager): CompactionEntry[] {
	return session.getEntries().filter((e): e is CompactionEntry => e.type === "compaction");
}

describe("compaction system snapshots on disk", () => {
	let dir: string;

	beforeEach(() => {
		dir = mkdtempSync(join(tmpdir(), "pi-snapshot-"));
	});

	afterEach(() => {
		rmSync(dir, { recursive: true, force: true });
	});

	/** A persisted session with one user turn and the given prompt in place. */
	function persistedSession(prompt: string) {
		const session = SessionManager.create(dir, dir);
		session.appendMessage(systemMsg(prompt, 1));
		const kept = session.appendMessage(userMsg("hi"));
		session.appendMessage(assistantMsg("ok"));
		return { session, kept };
	}

	it("stores one body for repeated compactions of the same state and reloads them unchanged", () => {
		const { session, kept } = persistedSession("prompt A");
		session.appendCompaction("first", kept, 100);
		session.appendMessage(userMsg("again"));
		session.appendCompaction("second", kept, 100);
		const file = session.getSessionFile()!;

		expect(snapshotRecords(file)).toHaveLength(1);
		expect(SessionManager.open(file).getEntries()).toEqual(session.getEntries());
	});

	it("stores a new body when the prompt or its sections change", () => {
		const { session, kept } = persistedSession("prompt A");
		session.appendCompaction("first", kept, 100);
		session.appendMessage(systemMsg("prompt A", 2, { guide: "<guide>" }));
		session.appendCompaction("second", kept, 100);
		const file = session.getSessionFile()!;

		expect(snapshotRecords(file)).toHaveLength(2);
		expect(SessionManager.open(file).getEntries()).toEqual(session.getEntries());
	});

	it("keeps the boundary timestamp of each compaction on the reloaded snapshot", () => {
		const { session, kept } = persistedSession("prompt A");
		session.appendCompaction("first", kept, 100);
		session.appendMessage(userMsg("again"));
		session.appendCompaction("second", kept, 100);
		const reloaded = compactions(SessionManager.open(session.getSessionFile()!));

		expect(reloaded.map((c) => c.systemMessage?.timestamp)).toEqual(
			compactions(session).map((c) => c.systemMessage?.timestamp),
		);
	});

	it("reuses a stored body when a session resumes and compacts in the same state", () => {
		const { session, kept } = persistedSession("prompt A");
		session.appendCompaction("first", kept, 100);
		const file = session.getSessionFile()!;

		const resumed = SessionManager.open(file, dir);
		resumed.appendMessage(userMsg("later"));
		resumed.appendCompaction("second", kept, 100);

		expect(snapshotRecords(file)).toHaveLength(1);
		expect(SessionManager.open(file).getEntries()).toEqual(resumed.getEntries());
	});

	it("writes the body of every referenced snapshot into a branch extracted from the file", () => {
		const { session, kept } = persistedSession("prompt A");
		const first = session.appendCompaction("first", kept, 100);
		session.appendMessage(systemMsg("prompt B", 2));
		session.appendCompaction("second", kept, 100);
		session.branch(first);
		session.appendMessage(userMsg("alternative"));

		const branchFile = session.createBranchedSession(session.getLeafId()!);
		expect(branchFile).toBeDefined();
		const branched = SessionManager.open(branchFile!);
		expect(branched.buildSessionContext().messages[0]).toEqual(
			expect.objectContaining({ role: "system", content: "prompt A" }),
		);
		expect(snapshotRecords(branchFile!)).toHaveLength(1);
	});

	it("forks a whole persisted session with the bodies its compactions reference", () => {
		const { session, kept } = persistedSession("prompt A");
		session.appendCompaction("first", kept, 100);
		session.appendMessage(systemMsg("prompt B", 2));
		session.appendCompaction("second", kept, 100);

		const forked = SessionManager.forkFrom(session.getSessionFile()!, dir, dir);
		expect(SessionManager.open(forked.getSessionFile()!).getEntries()).toEqual(session.getEntries());
	});

	it("loads a legacy inline snapshot unchanged and leaves the file as it was", () => {
		const file = join(dir, "legacy.jsonl");
		const lines = [
			{ type: "session", version: 3, id: "legacy-session", timestamp: "2026-01-01T00:00:00.000Z", cwd: dir },
			{
				type: "message",
				id: "m1",
				parentId: null,
				timestamp: "2026-01-01T00:00:01.000Z",
				message: { role: "user", content: "hi", timestamp: 1 },
			},
			{
				type: "compaction",
				id: "c1",
				parentId: "m1",
				timestamp: "2026-01-01T00:00:02.000Z",
				summary: "summary",
				firstKeptEntryId: "m1",
				tokensBefore: 100,
				systemMessage: { role: "system", content: "legacy", timestamp: 1767225602000 },
			},
		];
		const text = `${lines.map((line) => JSON.stringify(line)).join("\n")}\n`;
		writeFileSync(file, text);

		const session = SessionManager.open(file);
		expect(compactions(session)[0].systemMessage).toEqual({
			role: "system",
			content: "legacy",
			timestamp: 1767225602000,
		});
		expect(readFileSync(file, "utf8")).toBe(text);
	});

	it("loads an unreferenced body left by an interrupted write", () => {
		const { session, kept } = persistedSession("prompt A");
		session.appendCompaction("first", kept, 100);
		const file = session.getSessionFile()!;

		const other = persistedSession("prompt B");
		other.session.appendCompaction("other", other.kept, 100);
		const orphan = readFileSync(other.session.getSessionFile()!, "utf8")
			.split("\n")
			.find((line) => line.includes(SNAPSHOT_RECORD))!;
		writeFileSync(file, `${readFileSync(file, "utf8")}${orphan}\n`);

		expect(SessionManager.open(file).getEntries()).toEqual(session.getEntries());
	});

	describe("integrity", () => {
		/** A persisted file with one compaction, and the text of its snapshot record. */
		function fileWithCompaction(): { file: string; record: string; compaction: string } {
			const { session, kept } = persistedSession("prompt A");
			session.appendCompaction("first", kept, 100);
			const file = session.getSessionFile()!;
			const lines = readFileSync(file, "utf8").trimEnd().split("\n");
			const record = lines.find((line) => line.includes(SNAPSHOT_RECORD))!;
			const compaction = lines.find((line) => line.includes('"type":"compaction"'))!;
			return { file, record, compaction };
		}

		it("fails when a referenced body is missing and does not modify the file", () => {
			const { file, record, compaction } = fileWithCompaction();
			const text = readFileSync(file, "utf8").replace(`${record}\n`, "");
			writeFileSync(file, text);

			expect(() => SessionManager.open(file)).toThrow(/is not defined before it/);
			expect(readFileSync(file, "utf8")).toBe(text);
			expect(compaction).toContain("systemMessageRef");
		});

		it("fails when a body's contents no longer match its id", () => {
			const { file, record } = fileWithCompaction();
			const tampered = record.replace("prompt A", "prompt Z");
			writeFileSync(file, readFileSync(file, "utf8").replace(record, tampered));

			expect(() => SessionManager.open(file)).toThrow(/do not match its id/);
		});

		it("fails on an unsupported snapshot record version", () => {
			const { file, record } = fileWithCompaction();
			const future = record.replace('"version":1', '"version":2');
			writeFileSync(file, readFileSync(file, "utf8").replace(record, future));

			expect(() => SessionManager.open(file)).toThrow(/unsupported system snapshot record version/);
		});
	});
});
