// Identifies a file by its content (P2-6). Kept identical to
// services/scanner/src/filetype.ts; a parity test checks they agree.

export type AllowedMediaType = "application/pdf" | "image/jpeg" | "image/png";

const SIGNATURES: Array<{ type: AllowedMediaType; bytes: number[] }> = [
  { type: "application/pdf", bytes: [0x25, 0x50, 0x44, 0x46, 0x2d] }, // %PDF-
  { type: "image/png", bytes: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] },
  { type: "image/jpeg", bytes: [0xff, 0xd8, 0xff] },
];

export const MAX_UPLOAD_BYTES = 20 * 1024 * 1024;

export function sniff(file: Uint8Array): AllowedMediaType | null {
  for (const s of SIGNATURES) {
    if (file.length >= s.bytes.length && s.bytes.every((b, i) => file[i] === b)) return s.type;
  }
  return null;
}
