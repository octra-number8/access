// Minimal clamd client over TCP: PING, VERSION and INSTREAM.
// Files are streamed from memory and never written to disk.

import { connect } from "node:net";

export interface ClamdAddress {
  host: string;
  port: number;
  timeoutMs: number;
}

export type ClamdVerdict =
  | { kind: "clean" }
  | { kind: "infected"; signature: string }
  // clamd could not fully scan it (size, recursion or other limits): never clean.
  | { kind: "not_fully_scanned"; detail: string };

export interface ClamdVersion {
  engine: string;
  signatureVersion: string;
  signatureDate: Date;
}

const CHUNK = 64 * 1024;

function request(addr: ClamdAddress, payload: Buffer[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = connect({ host: addr.host, port: addr.port });
    const parts: Buffer[] = [];
    socket.setTimeout(addr.timeoutMs, () => socket.destroy(new Error("clamd timed out")));
    socket.on("connect", () => {
      for (const p of payload) socket.write(p);
    });
    socket.on("data", (d) => parts.push(typeof d === "string" ? Buffer.from(d) : d));
    socket.on("error", reject);
    socket.on("close", () => resolve(Buffer.concat(parts).toString("utf8").replace(/\0+$/, "").trim()));
  });
}

export async function ping(addr: ClamdAddress): Promise<boolean> {
  try {
    return (await request(addr, [Buffer.from("zPING\0")])) === "PONG";
  } catch {
    return false;
  }
}

/** "ClamAV 1.4.3/27800/Fri Oct 24 07:33:00 2026" */
export function parseVersion(reply: string): ClamdVersion {
  const m = /^(ClamAV [^/]+)\/(\d+)\/(.+)$/.exec(reply);
  if (!m) throw new Error(`unexpected clamd VERSION reply: ${reply}`);
  const date = new Date(`${m[3]} UTC`);
  if (Number.isNaN(date.getTime())) throw new Error(`unparseable signature date: ${m[3]}`);
  return { engine: m[1]!, signatureVersion: m[2]!, signatureDate: date };
}

/** Asks clamd to load the signatures on disk (freshclam's notice can be missed at start-up). */
export async function reload(addr: ClamdAddress): Promise<boolean> {
  try {
    return (await request(addr, [Buffer.from("zRELOAD\0")])) === "RELOADING";
  } catch {
    return false;
  }
}

export async function version(addr: ClamdAddress): Promise<ClamdVersion> {
  return parseVersion(await request(addr, [Buffer.from("zVERSION\0")]));
}

/** Interprets an INSTREAM reply. Anything not explicitly OK is never clean. */
export function parseScanReply(reply: string): ClamdVerdict {
  if (reply === "stream: OK") return { kind: "clean" };
  const found = /^stream: (.+) FOUND$/.exec(reply);
  if (found) {
    const signature = found[1]!;
    // AlertExceedsMax reports limit breaches as Heuristics.Limits.Exceeded.*
    if (signature.startsWith("Heuristics.Limits.Exceeded")) {
      return { kind: "not_fully_scanned", detail: signature };
    }
    return { kind: "infected", signature };
  }
  return { kind: "not_fully_scanned", detail: reply || "empty reply from clamd" };
}

export function instreamFrames(file: Buffer): Buffer[] {
  const frames: Buffer[] = [Buffer.from("zINSTREAM\0")];
  for (let i = 0; i < file.length; i += CHUNK) {
    const chunk = file.subarray(i, i + CHUNK);
    const len = Buffer.alloc(4);
    len.writeUInt32BE(chunk.length);
    frames.push(len, chunk);
  }
  frames.push(Buffer.alloc(4));
  return frames;
}

export async function scan(addr: ClamdAddress, file: Buffer): Promise<ClamdVerdict> {
  return parseScanReply(await request(addr, instreamFrames(file)));
}
