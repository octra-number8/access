import { describe, expect, it } from "vitest";
import { fromVenueLocal, toVenueLocal } from "./permits";

describe("venue local time", () => {
  it("reads a London summer time as BST", () => {
    expect(fromVenueLocal("2026-07-01T09:00", "Europe/London")).toBe("2026-07-01T08:00:00.000Z");
  });
  it("reads a London winter time as GMT", () => {
    expect(fromVenueLocal("2026-12-01T09:00", "Europe/London")).toBe("2026-12-01T09:00:00.000Z");
  });
  it("round-trips across the October change", () => {
    expect(toVenueLocal(fromVenueLocal("2026-10-26T07:30", "Europe/London"), "Europe/London")).toBe("2026-10-26T07:30");
    expect(toVenueLocal("2026-10-24T23:00:00Z", "Europe/London")).toBe("2026-10-25T00:00");
  });
  it("takes the earlier of the two 01:00s when the clocks go back", () => {
    expect(fromVenueLocal("2026-10-25T01:00", "Europe/London")).toBe("2026-10-25T00:00:00.000Z");
    expect(fromVenueLocal("2026-10-25T01:30", "Europe/London")).toBe("2026-10-25T00:30:00.000Z");
  });
});
