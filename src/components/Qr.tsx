import { qrMatrix } from "@/lib/qr";

/** A QR code as SVG, with its quiet zone. Black on white whatever the page colours. */
export function Qr({ value, label, size = 240 }: { value: string; label: string; size?: number }) {
  const m = qrMatrix(value);
  const n = m.length + 8;
  let d = "";
  m.forEach((row, y) => row.forEach((dark, x) => { if (dark) d += `M${x + 4} ${y + 4}h1v1h-1z`; }));
  return (
    <svg role="img" aria-label={label} width={size} height={size} viewBox={`0 0 ${n} ${n}`} shapeRendering="crispEdges" style={{ background: "#fff" }}>
      <rect width={n} height={n} fill="#fff" />
      <path d={d} fill="#000" />
    </svg>
  );
}
