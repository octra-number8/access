-- 0064 Automatic manifest refresh (decision 7d-3, D-024)
--
-- The outage procedure gains an optional `manifest_refresh_minutes`: how often a gate device that
-- is online downloads a fresh manifest. There is no default (CLAUDE.md §9): without it, refresh
-- stays manual, as before. It must be shorter than the manifest's maximum age, so a device that
-- stays online never holds an expired manifest. Each refresh is an ordinary download: the same
-- appointment (`gate.download_manifest`), a new manifest record, and retention as for any other.
-- The interval is returned with each manifest, so the device follows the procedure it was made under.
--
-- Rollback / recovery: forward-only. To withdraw, restore core.validate_venue_config and
-- api.download_manifest from their earlier definitions; an approved procedure that sets the
-- interval keeps it, and the device ignores it.

do $$
declare d text; n text;
begin
  d := pg_get_functiondef('core.validate_venue_config(uuid,text,jsonb,boolean)'::regprocedure);
  n := $s$      errs := errs || text 'The manifest''s maximum age is a whole number of minutes, from 1 to 1440 (Q198).';
    end if;$s$;
  if position(n in d) = 0 then raise exception '0064: validate_venue_config anchor not found'; end if;
  d := replace(d, n, n || $s$
    if c ? 'manifest_refresh_minutes' and (jsonb_typeof(c -> 'manifest_refresh_minutes') is distinct from 'number'
         or (c ->> 'manifest_refresh_minutes')::numeric <> floor((c ->> 'manifest_refresh_minutes')::numeric)
         or (c ->> 'manifest_refresh_minutes')::numeric not between 1 and 1439) then
      errs := errs || text 'Automatic refresh is a whole number of minutes, from 1 to 1439 (7d-3).';
    elsif c ? 'manifest_refresh_minutes' and jsonb_typeof(c -> 'manifest_max_age_minutes') = 'number'
          and (c ->> 'manifest_refresh_minutes')::numeric >= (c ->> 'manifest_max_age_minutes')::numeric then
      errs := errs || text 'Refresh the manifest more often than its maximum age, so a device that stays online never holds an expired one.';
    end if;$s$);
  execute d;

  d := pg_get_functiondef('api.download_manifest(text,uuid)'::regprocedure);
  n := $s$'max_age_minutes', m.max_age_minutes,$s$;
  if position(n in d) = 0 then raise exception '0064: download_manifest anchor not found'; end if;
  execute replace(d, n, n || $s$ 'refresh_minutes', (cfg.content ->> 'manifest_refresh_minutes')::integer,$s$);
end $$;
