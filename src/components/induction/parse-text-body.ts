// Copied from OCTRA Induct (src/components/induction/parse-text-body.ts), D-015.
/**
 * Induction text is stored as plain text, never HTML, so nothing an author types can run
 * in a participant's browser. Two conventions give it shape: a blank line starts a new
 * paragraph, and a line starting with "- " or "• " is a bullet point.
 */
export type TextPart = { kind: "paragraph"; text: string } | { kind: "list"; items: string[] };

const BULLET = /^\s*(?:-|•)\s+/;

export function parseTextBody(source: string): TextPart[] {
  const parts: TextPart[] = [];
  let paragraph: string[] = [];
  let list: string[] = [];

  const flushParagraph = () => {
    if (paragraph.length) parts.push({ kind: "paragraph", text: paragraph.join("\n") });
    paragraph = [];
  };
  const flushList = () => {
    if (list.length) parts.push({ kind: "list", items: list });
    list = [];
  };

  for (const line of source.replace(/\r\n?/g, "\n").split("\n")) {
    if (line.trim() === "") {
      flushParagraph();
      flushList();
    } else if (BULLET.test(line)) {
      flushParagraph();
      list.push(line.replace(BULLET, "").trim());
    } else {
      flushList();
      paragraph.push(line.trim());
    }
  }
  flushParagraph();
  flushList();
  return parts;
}
