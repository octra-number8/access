import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { parseScanReply, parseVersion } from "./clamd.js";
import { sniff } from "./filetype.js";
import { MAX_DOWNLOAD_ATTEMPTS, fromVerdict, onDownloadFailure, preflight, signaturesFresh, type ScanJob } from "./worker.js";

const pdf = Buffer.from("%PDF-1.7\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n");
const job = (file: Buffer, overrides: Partial<ScanJob> = {}): ScanJob => ({
  version_id: "v",
  storage_path: "c/d/v",
  media_type: "application/pdf",
  size_bytes: file.length,
  sha256: createHash("sha256").update(file).digest("hex"),
  attempts: 1,
  ...overrides,
});

describe("content type", () => {
  it("recognises the accepted types by their bytes", () => {
    expect(sniff(pdf)).toBe("application/pdf");
    expect(sniff(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0]))).toBe("image/png");
    expect(sniff(Buffer.from([0xff, 0xd8, 0xff, 0xe0]))).toBe("image/jpeg");
    expect(sniff(Buffer.from("GIF89a"))).toBeNull();
  });
});

describe("preflight", () => {
  it("passes a file that is exactly what was registered", () => {
    expect(preflight(job(pdf), pdf)).toBeNull();
  });
  it("rejects a different size", () => {
    expect(preflight(job(pdf, { size_bytes: 1 }), pdf)?.result).toBe("rejected");
  });
  it("rejects content that does not match the registered hash", () => {
    expect(preflight(job(pdf, { sha256: "0".repeat(64) }), pdf)?.result).toBe("rejected");
  });
  it("rejects a file whose content is not the declared type", () => {
    const gif = Buffer.from("GIF89a....");
    expect(preflight(job(gif), gif)).toEqual({ result: "rejected", detail: "declared application/pdf, content is not an accepted type" });
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    expect(preflight(job(png), png)?.detail).toBe("declared application/pdf, content is image/png");
  });
});

describe("clamd replies", () => {
  it("is clean only on an explicit OK", () => {
    expect(fromVerdict(parseScanReply("stream: OK")).result).toBe("clean");
  });
  it("reports a signature as infected", () => {
    expect(fromVerdict(parseScanReply("stream: Eicar-Test-Signature FOUND"))).toEqual({
      result: "infected",
      detail: "Eicar-Test-Signature",
    });
  });
  it("treats exceeded limits as not fully scanned, never clean", () => {
    expect(fromVerdict(parseScanReply("stream: Heuristics.Limits.Exceeded.MaxFileSize FOUND")).result).toBe("rejected");
  });
  it("treats errors and anything unexpected as rejected", () => {
    expect(fromVerdict(parseScanReply("INSTREAM size limit exceeded. ERROR")).result).toBe("rejected");
    expect(fromVerdict(parseScanReply("")).result).toBe("rejected");
    expect(fromVerdict(parseScanReply("stream: ok")).result).toBe("rejected");
  });
  it("parses the engine and signature version", () => {
    const v = parseVersion("ClamAV 1.4.3/27800/Fri Oct 24 07:33:00 2026");
    expect(v.engine).toBe("ClamAV 1.4.3");
    expect(v.signatureVersion).toBe("27800");
    expect(v.signatureDate.toISOString()).toBe("2026-10-24T07:33:00.000Z");
  });
});

describe("fail closed", () => {
  it("stops scanning when signatures are older than the limit", () => {
    const v = parseVersion("ClamAV 1.4.3/27800/Fri Oct 24 07:33:00 2026");
    expect(signaturesFresh(v, new Date("2026-10-24T20:00:00Z"), 24)).toBe(true);
    expect(signaturesFresh(v, new Date("2026-10-26T08:00:00Z"), 24)).toBe(false);
  });
  it("retries a failed download, then gives up as rejected", () => {
    expect(onDownloadFailure(job(pdf, { attempts: 1 }), "not found")).toBeNull();
    expect(onDownloadFailure(job(pdf, { attempts: MAX_DOWNLOAD_ATTEMPTS }), "not found")?.result).toBe("rejected");
  });
});
