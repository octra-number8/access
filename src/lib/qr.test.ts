import { describe, expect, it } from "vitest";
import { qrMatrix, rsRemainder } from "./qr";

describe("QR encoder", () => {
  it("computes Reed–Solomon error correction (the 1-M HELLO WORLD example)", () => {
    const data = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17];
    expect(rsRemainder(data, 10)).toEqual([196, 35, 39, 119, 235, 215, 231, 226, 93, 23]);
  });

  it("chooses the smallest version that fits", () => {
    expect(qrMatrix("OCTRA1:P:M-000001:123456").length).toBe(25); // a phone pass: 24 bytes, version 2
    expect(qrMatrix(`OCTRA1:C:C-000001:${"x".repeat(24)}`).length).toBe(29); // a card: 42 bytes, version 3
    expect(qrMatrix("x".repeat(100)).length).toBe(41); // version 6 (version 5-M holds 84 bytes)
  });

  it("draws the finder patterns", () => {
    const m = qrMatrix("OCTRA1:P:M-000001:123456");
    const n = m.length;
    for (const [x, y] of [[0, 0], [n - 7, 0], [0, n - 7]] as const) {
      expect(m[y]![x]).toBe(true);
      expect(m[y + 1]![x + 1]).toBe(false);
      expect(m[y + 3]![x + 3]).toBe(true);
    }
    expect(m[n - 8]![8]).toBe(true); // the dark module
  });

  it("refuses text too long for a pass", () => {
    expect(() => qrMatrix("x".repeat(300))).toThrow();
  });
});
