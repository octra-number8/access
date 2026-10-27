import { describe, expect, it } from "vitest";
import { parseScope, toCsv } from "./dashboard";

describe("toCsv", () => {
  const cols = [{ key: "a", label: "A" }, { key: "b", label: "B, with comma" }];

  it("quotes commas, quotes and line breaks, and ends lines with CRLF", () => {
    expect(toCsv(cols, [{ a: 'Say "hi"', b: "one\ntwo" }])).toBe('A,"B, with comma"\r\n"Say ""hi""","one\ntwo"\r\n');
  });

  it("never lets text run as a spreadsheet formula", () => {
    const out = toCsv([{ key: "a", label: "A" }], [{ a: "=HYPERLINK(\"x\")" }, { a: "+1" }, { a: "@SUM(A1)" }, { a: "-cmd" }]);
    expect(out.split("\r\n").slice(1, 5)).toEqual(['"\'=HYPERLINK(""x"")"', "'+1", "'@SUM(A1)", "'-cmd"]);
  });

  it("leaves numbers, including negative ones, as numbers, and empty cells empty", () => {
    expect(toCsv([{ key: "a", label: "A" }, { key: "b", label: "B" }], [{ a: -1.5, b: null }])).toBe("A,B\r\n-1.5,\r\n");
  });
});

describe("parseScope", () => {
  const v = "11111111-1111-1111-1111-111111111111";
  const o = "22222222-2222-2222-2222-222222222222";
  it("reads a venue or an organisation at a venue, and nothing else", () => {
    expect(parseScope(`venue:${v}`)).toEqual({ venueId: v, organisationId: null });
    expect(parseScope(`org:${o}:${v}`)).toEqual({ venueId: v, organisationId: o });
    expect(parseScope(`venue:${v}' or 1=1`)).toBeNull();
    expect(parseScope(undefined)).toBeNull();
  });
});
