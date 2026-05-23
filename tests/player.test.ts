import { describe, it, expect, vi, afterEach } from "vitest";
import * as cp from "child_process";
import { EventEmitter } from "events";

vi.mock("child_process", async (importOriginal) => {
  const orig = await importOriginal<typeof cp>();
  return { ...orig, spawn: vi.fn() };
});

import { speak } from "../src/player.js";

afterEach(() => vi.clearAllMocks());

function mockProc(exitCode: number) {
  const proc = new EventEmitter() as any;
  proc.stderr = new EventEmitter();
  vi.mocked(cp.spawn).mockReturnValue(proc as any);
  setImmediate(() => proc.emit("close", exitCode));
  return proc;
}

describe("speak", () => {
  it("say 성공 시 resolve", async () => {
    mockProc(0);
    await expect(speak("안녕")).resolves.toBeUndefined();
    expect(cp.spawn).toHaveBeenCalledWith("say", ["안녕"]);
  });

  it("say 실패 시 reject", async () => {
    mockProc(1);
    await expect(speak("안녕")).rejects.toThrow("say 명령 실패");
  });

  it("spawn 오류 시 reject", async () => {
    const proc = new EventEmitter() as any;
    proc.stderr = new EventEmitter();
    vi.mocked(cp.spawn).mockReturnValue(proc as any);
    setImmediate(() => proc.emit("error", new Error("ENOENT")));
    await expect(speak("안녕")).rejects.toThrow("ENOENT");
  });
});
