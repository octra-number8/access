import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  AUTHORITY_ACTIONS,
  ConflictError,
  check,
  explain,
  isDenied,
  write,
  type AuthzDenied,
  type RpcClient,
} from "./index";

function fakeClient(data: unknown, error: { code?: string; message: string } | null = null) {
  const calls: Array<{ fn: string; args: Record<string, unknown> }> = [];
  const client: RpcClient = {
    rpc: (fn, args) => {
      calls.push({ fn, args });
      return Promise.resolve({ data, error });
    },
  };
  return { client, calls };
}

const target = {
  customer_id: "c",
  venue_id: "v",
  area_id: "a",
  record_id: "r",
  target_type: "engagement",
};

const denial: AuthzDenied = {
  ok: false,
  allowed: false,
  action: "engagement.suspend",
  code: "no_covering_appointment",
  reason: "No current appointment or delegation of yours covers this.",
  missing: "An in-force appointment covering this action",
  resolvable_by: "The venue's appointing authority for this scope",
};

describe("check", () => {
  it("passes the database decision through unchanged", async () => {
    const allowed = {
      ok: true,
      allowed: true,
      action: "engagement.suspend",
      basis: "appointment",
      actor_kind: "user",
      acting_appointment_id: "ap",
    };
    const { client, calls } = fakeClient(allowed);
    const result = await check(client, "engagement.suspend", target, { appointmentId: "ap" });
    expect(result).toEqual(allowed);
    expect(calls).toEqual([
      {
        fn: "check",
        args: {
          p_action: "engagement.suspend",
          p_target: target,
          p_acting_appointment_id: "ap",
          p_acting_delegation_id: null,
        },
      },
    ]);
  });

  it("returns a denial as a value and never overrides it", async () => {
    const { client } = fakeClient(denial);
    const result = await check(client, "engagement.suspend", target);
    expect(isDenied(result)).toBe(true);
    expect(result).toEqual(denial);
  });
});

describe("explain", () => {
  it("states what, why, what is missing and who can resolve it", () => {
    expect(explain(denial, "Suspend this engagement")).toEqual({
      unavailable: "Suspend this engagement",
      why: denial.reason,
      missing: denial.missing,
      whoCanResolve: denial.resolvable_by,
    });
  });
});

describe("write", () => {
  it("turns a stale-version refusal into a ConflictError", async () => {
    const { client } = fakeClient(null, { code: "PT409", message: "record has changed" });
    await expect(write(client, "suspend_engagement", { p_idempotency_key: "k-00000001" })).rejects.toBeInstanceOf(
      ConflictError,
    );
  });

  it("returns a replay as success with the original id", async () => {
    const replay = { ok: true, replayed: true, id: "same", decision_context_id: "ctx" };
    const { client } = fakeClient(replay);
    expect(await write(client, "create_area", { p_idempotency_key: "k-00000002" })).toEqual(replay);
  });
});

describe("action catalogue", () => {
  it("matches the codes seeded by the migrations", () => {
    const dir = join(__dirname, "../../../supabase/migrations");
    const seeded = readdirSync(dir)
      .filter((f) => f.endsWith(".sql"))
      .sort()
      .flatMap((f) =>
        [
          ...readFileSync(join(dir, f), "utf8").matchAll(
            /^\s+\('([a-z_]+\.[a-z_]+)',\s*'(?:appointment|tenant_admin|platform_admin|subject|organisation_admin|invitee|service|derived|link_holder|permit_part)'/gm,
          ),
        ].map((m) => m[1]),
      );
    expect(seeded.length).toBe(286);
    expect(new Set(seeded)).toEqual(new Set(AUTHORITY_ACTIONS));
  });
});
