// A small QR code encoder for passes (phase 7c, D-020): byte mode, error correction level M,
// versions 1–10 (up to 213 bytes). Written here rather than added as a dependency; a pass
// payload is under 50 bytes. Follows ISO/IEC 18004 as laid out in Project Nayuki's reference
// implementation. Returns the module grid without the quiet zone (true = dark).

const EC_PER_BLOCK_M = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26];
const BLOCKS_M = [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5];
const MAX_VERSION = 10;

function rawCodewords(ver: number): number {
  let r = (16 * ver + 128) * ver + 64;
  if (ver >= 2) {
    const n = Math.floor(ver / 7) + 2;
    r -= (25 * n - 10) * n - 55;
    if (ver >= 7) r -= 36;
  }
  return Math.floor(r / 8);
}

function dataCodewords(ver: number): number {
  return rawCodewords(ver) - EC_PER_BLOCK_M[ver]! * BLOCKS_M[ver]!;
}

// ---- Reed–Solomon over GF(256), polynomial 0x11D -----------------------------------------------
function gfMul(x: number, y: number): number {
  let z = 0;
  for (let i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d);
    z ^= ((y >>> i) & 1) * x;
  }
  return z;
}

function rsDivisor(degree: number): number[] {
  const r = new Array<number>(degree).fill(0);
  r[degree - 1] = 1;
  let root = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < r.length; j++) {
      r[j] = gfMul(r[j]!, root);
      if (j + 1 < r.length) r[j]! ^= r[j + 1]!;
    }
    root = gfMul(root, 0x02);
  }
  return r;
}

export function rsRemainder(data: number[], degree: number): number[] {
  const divisor = rsDivisor(degree);
  const r = new Array<number>(degree).fill(0);
  for (const b of data) {
    const factor = b ^ r.shift()!;
    r.push(0);
    divisor.forEach((d, i) => { r[i]! ^= gfMul(d, factor); });
  }
  return r;
}

// ---- Codewords ------------------------------------------------------------------------------------
function codewords(bytes: Uint8Array, ver: number): number[] {
  const bits: number[] = [];
  const put = (v: number, n: number) => { for (let i = n - 1; i >= 0; i--) bits.push((v >>> i) & 1); };
  put(0b0100, 4);
  put(bytes.length, ver <= 9 ? 8 : 16);
  bytes.forEach((b) => put(b, 8));
  const capacity = dataCodewords(ver) * 8;
  put(0, Math.min(4, capacity - bits.length));
  put(0, (8 - (bits.length % 8)) % 8);
  const data: number[] = [];
  for (let i = 0; i < bits.length; i += 8) data.push(bits.slice(i, i + 8).reduce((a, b) => (a << 1) | b, 0));
  for (let pad = 0xec; data.length < dataCodewords(ver); pad ^= 0xec ^ 0x11) data.push(pad);

  const blocks = BLOCKS_M[ver]!;
  const ecLen = EC_PER_BLOCK_M[ver]!;
  const raw = rawCodewords(ver);
  const shortBlocks = blocks - (raw % blocks);
  const shortLen = Math.floor(raw / blocks);
  const dataBlocks: number[][] = [];
  const ecBlocks: number[][] = [];
  for (let i = 0, k = 0; i < blocks; i++) {
    const len = shortLen - ecLen + (i < shortBlocks ? 0 : 1);
    const d = data.slice(k, k + len);
    k += len;
    dataBlocks.push(d);
    ecBlocks.push(rsRemainder(d, ecLen));
  }
  const out: number[] = [];
  for (let i = 0; i <= shortLen - ecLen; i++) dataBlocks.forEach((d) => { if (i < d.length) out.push(d[i]!); });
  for (let i = 0; i < ecLen; i++) ecBlocks.forEach((e) => out.push(e[i]!));
  return out;
}

// ---- The matrix -----------------------------------------------------------------------------------
function alignmentPositions(ver: number): number[] {
  if (ver === 1) return [];
  const n = Math.floor(ver / 7) + 2;
  const size = ver * 4 + 17;
  const step = Math.ceil((ver * 4 + 4) / (n * 2 - 2)) * 2;
  const r = [6];
  for (let pos = size - 7; r.length < n; pos -= step) r.splice(1, 0, pos);
  return r;
}

function formatBits(mask: number): number {
  const data = (0 << 3) | mask; // level M is 0b00
  let rem = data;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
  return ((data << 10) | rem) ^ 0x5412;
}

const MASKS: Array<(x: number, y: number) => boolean> = [
  (x, y) => (x + y) % 2 === 0,
  (_x, y) => y % 2 === 0,
  (x) => x % 3 === 0,
  (x, y) => (x + y) % 3 === 0,
  (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0,
  (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
  (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
  (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
];

function build(ver: number, data: number[], mask: number): boolean[][] {
  const size = ver * 4 + 17;
  const m = Array.from({ length: size }, () => new Array<boolean>(size).fill(false));
  const fn = Array.from({ length: size }, () => new Array<boolean>(size).fill(false));
  const set = (x: number, y: number, dark: boolean) => { m[y]![x] = dark; fn[y]![x] = true; };

  for (let i = 0; i < size; i++) { set(6, i, i % 2 === 0); set(i, 6, i % 2 === 0); }
  for (const [cx, cy] of [[3, 3], [size - 4, 3], [3, size - 4]] as const) {
    for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) {
      const x = cx + dx, y = cy + dy;
      if (x < 0 || y < 0 || x >= size || y >= size) continue;
      const d = Math.max(Math.abs(dx), Math.abs(dy));
      set(x, y, d !== 2 && d !== 4);
    }
  }
  const al = alignmentPositions(ver);
  al.forEach((ax, i) => al.forEach((ay, j) => {
    if ((i === 0 && j === 0) || (i === 0 && j === al.length - 1) || (i === al.length - 1 && j === 0)) return;
    for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) set(ax + dx, ay + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
  }));

  const f = formatBits(mask);
  const bit = (v: number, i: number) => ((v >>> i) & 1) !== 0;
  for (let i = 0; i <= 5; i++) set(8, i, bit(f, i));
  set(8, 7, bit(f, 6)); set(8, 8, bit(f, 7)); set(7, 8, bit(f, 8));
  for (let i = 9; i < 15; i++) set(14 - i, 8, bit(f, i));
  for (let i = 0; i < 8; i++) set(size - 1 - i, 8, bit(f, i));
  for (let i = 8; i < 15; i++) set(8, size - 15 + i, bit(f, i));
  set(8, size - 8, true);

  if (ver >= 7) {
    let rem = ver;
    for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
    const v = (ver << 12) | rem;
    for (let i = 0; i < 18; i++) {
      const a = size - 11 + (i % 3), b = Math.floor(i / 3);
      set(a, b, bit(v, i)); set(b, a, bit(v, i));
    }
  }

  let i = 0;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vert = 0; vert < size; vert++) {
      for (let j = 0; j < 2; j++) {
        const x = right - j;
        const y = ((right + 1) & 2) === 0 ? size - 1 - vert : vert;
        if (!fn[y]![x] && i < data.length * 8) {
          m[y]![x] = bit(data[i >>> 3]!, 7 - (i & 7));
          i++;
        }
      }
    }
  }
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (!fn[y]![x] && MASKS[mask]!(x, y)) m[y]![x] = !m[y]![x];
  return m;
}

// Penalty rules 1, 2 and 4 of the standard, and rule 3's finder-like runs.
function penalty(m: boolean[][]): number {
  const size = m.length;
  let p = 0;
  const lines = [...m, ...m.map((_, x) => m.map((row) => row[x]!))];
  for (const line of lines) {
    let run = 1;
    for (let i = 1; i <= size; i++) {
      if (i < size && line[i] === line[i - 1]) run++;
      else { if (run >= 5) p += run - 2; run = 1; }
    }
    const s = line.map((d) => (d ? "1" : "0")).join("");
    for (const pat of ["10111010000", "00001011101"]) for (let k = s.indexOf(pat); k >= 0; k = s.indexOf(pat, k + 1)) p += 40;
  }
  for (let y = 0; y + 1 < size; y++) for (let x = 0; x + 1 < size; x++) {
    const c = m[y]![x];
    if (c === m[y]![x + 1] && c === m[y + 1]![x] && c === m[y + 1]![x + 1]) p += 3;
  }
  const dark = m.flat().filter(Boolean).length;
  p += Math.floor(Math.abs(dark * 20 - size * size * 10) / (size * size)) * 10;
  return p;
}

export function qrMatrix(text: string): boolean[][] {
  const bytes = new TextEncoder().encode(text);
  let ver = 1;
  while (ver <= MAX_VERSION && 4 + (ver <= 9 ? 8 : 16) + bytes.length * 8 > dataCodewords(ver) * 8) ver++;
  if (ver > MAX_VERSION) throw new Error("Too long for a pass code.");
  const data = codewords(bytes, ver);
  let best: boolean[][] | null = null;
  let bestScore = Infinity;
  for (let mask = 0; mask < 8; mask++) {
    const m = build(ver, data, mask);
    const score = penalty(m);
    if (score < bestScore) { best = m; bestScore = score; }
  }
  return best!;
}
