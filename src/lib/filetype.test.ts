import { describe, expect, it } from "vitest";
import { sniff as scannerSniff } from "../../services/scanner/src/filetype";
import { MAX_UPLOAD_BYTES, sniff } from "./filetype";

// The upload server and the scanner must judge file types identically (P2-6).
describe("file type parity", () => {
  const samples: Array<[string, number[]]> = [
    ["pdf", [0x25, 0x50, 0x44, 0x46, 0x2d, 0x31]],
    ["png", [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]],
    ["jpeg", [0xff, 0xd8, 0xff, 0xe0]],
    ["gif", [0x47, 0x49, 0x46, 0x38]],
    ["empty", []],
    ["truncated png", [0x89, 0x50, 0x4e]],
  ];
  it.each(samples)("agrees on %s", (_, bytes) => {
    expect(sniff(Uint8Array.from(bytes))).toBe(scannerSniff(Buffer.from(bytes)));
  });
  it("matches the database's 20 MB limit", () => {
    expect(MAX_UPLOAD_BYTES).toBe(20_971_520);
  });
});
