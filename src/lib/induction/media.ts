// Identifies induction media by content (as P2-6 does for documents).
export type InductionMediaType = "image/jpeg" | "image/png" | "application/pdf" | "text/vtt" | "video/mp4";

export function sniffInductionMedia(file: Uint8Array): InductionMediaType | null {
  const starts = (bytes: number[], at = 0) => bytes.every((b, i) => file[at + i] === b);
  if (starts([0x25, 0x50, 0x44, 0x46, 0x2d])) return "application/pdf";
  if (starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return "image/png";
  if (starts([0xff, 0xd8, 0xff])) return "image/jpeg";
  if (starts([0x57, 0x45, 0x42, 0x56, 0x54, 0x54]) || starts([0xef, 0xbb, 0xbf, 0x57, 0x45, 0x42, 0x56, 0x54, 0x54])) return "text/vtt";
  if (starts([0x66, 0x74, 0x79, 0x70], 4)) return "video/mp4"; // ....ftyp
  return null;
}

export const maxInductionMediaBytes = (type: InductionMediaType) => (type === "video/mp4" ? 200 : 20) * 1024 * 1024;
