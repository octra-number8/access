// Runs against a real clamd: `docker compose up -d clamd`, then CLAMD_PORT=55310 npm test.
import { describe, expect, it } from "vitest";
import { ping, scan, version } from "./clamd.js";

const port = Number(process.env.CLAMD_PORT ?? 0);
const addr = { host: "127.0.0.1", port, timeoutMs: 60_000 };
// The EICAR test file, assembled at run time so the repository holds no copy of it.
const eicar = Buffer.from(
  ["X5O!P%@AP[4\\PZX54(P^)7CC)7}$", "EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"].join(""),
);

describe.skipIf(!port)("clamd (integration)", () => {
  it("answers ping and reports its signature version", async () => {
    expect(await ping(addr)).toBe(true);
    expect((await version(addr)).engine).toMatch(/^ClamAV 1\.4/);
  });
  it("finds the EICAR test file", async () => {
    const v = await scan(addr, eicar);
    expect(v.kind).toBe("infected");
  });
  it("passes an ordinary PDF", async () => {
    expect((await scan(addr, Buffer.from("%PDF-1.7\n%%EOF\n"))).kind).toBe("clean");
  });
  it("does not call an oversized stream clean", async () => {
    const big = Buffer.alloc(26 * 1024 * 1024, 0x41);
    expect((await scan(addr, big)).kind).toBe("not_fully_scanned");
  });
});
