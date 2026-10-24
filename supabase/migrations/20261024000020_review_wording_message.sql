-- 0020 Plain-language refusal for review wording (CLAUDE.md §1, §6)
--
-- The check constraint on review_decision.scope_wording stays as the backstop; this
-- makes api.review_document refuse first, with a reason a reviewer can act on, instead
-- of surfacing the constraint's internal name.
--
-- Recovery: pre-pilot, `supabase db reset`. Afterwards, forward fix only.
do $m$
declare d text;
begin
  d := pg_get_functiondef('api.review_document(text,uuid,uuid,text,jsonb,text,text,uuid,uuid)'::regprocedure);
  if position('  insert into core.review_decision (' in d) = 0 then
    raise exception 'review_document no longer has the expected insert';
  end if;
  d := replace(d, '  insert into core.review_decision (', $r$  if p_scope_wording ~* '(approv|certif|verif|guarant|complian|safe to)' then
    raise exception 'Describe the scope you reviewed. Review wording cannot claim approval, certification, verification, a guarantee or compliance.'
      using errcode = '22023';
  end if;

  insert into core.review_decision ($r$);
  execute d;
end $m$;
