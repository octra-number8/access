-- Dashboards and reports 8b (Q204, Q205, Q208, Q209, Q96, P8-7, P8-15, P5-6, CLAUDE.md §6):
-- lists of actions with what is needed, who owns it and when, built from the same checks the
-- decisions use; visible only to the venue's side or the organisation's administrators;
-- restrictions as a fact, never their grounds; the occupier and the venue's appointees never
-- named to the contractor; reports that follow record visibility.
begin;
\ir _helpers.psql
\ir _phase2.psql
\ir _phase3.psql
\ir _phase4.psql
select tests.approve_screening();
\ir _phase5.psql
\ir _phase6.psql
\ir _phase6b.psql
select no_plan();

create temp table t_r (name text primary key, v jsonb);
grant all on t_r to authenticated;

-- Items of a group whose title or text mentions something.
create function tests.items(p jsonb, p_group text, p_like text) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(i), '[]') from jsonb_array_elements(p -> p_group) i where i::text like p_like $$;
grant execute on function tests.items(jsonb, text, text) to authenticated;
create function tests.today() returns date language sql stable security definer as $$
  select (now() at time zone (select timezone from core.venue where id = tests.w('v1')))::date $$;
grant execute on function tests.today() to authenticated;

-- ---- The world: a live job, a job waiting for decisions, a job asked for information --------------------
select tests.set_w('wp_live', tests.live_job('Lamps in the halls'));
select tests.set_w('wah', tests.permit_of(tests.w('wp_live'), tests.w('pc_wah')));
select tests.set_w('wp_wait', tests.today_job('Rig the truss', array[tests.w('pc_wah')]));
select tests.login(tests.w('u_op'));
select tests.must(api.save_permit_draft(tests.key(), tests.permit_of(tests.w('wp_wait'), tests.w('pc_wa')), '{}', now() + interval '2 hours', now() + interval '1 day'));
select tests.must(api.set_permit_team(tests.key(), tests.permit_of(tests.w('wp_wait'), tests.w('pc_wa')), jsonb_build_array(
  jsonb_build_object('person_id', tests.w('p_op'), 'role', 'supervisor'), jsonb_build_object('person_id', tests.w('p_owen'), 'role', 'operative'))));
select tests.must(api.submit_permit(tests.key(), tests.permit_of(tests.w('wp_wait'), tests.w('pc_wa')),
  tests.version('core.permit', tests.permit_of(tests.w('wp_wait'), tests.w('pc_wa')))));
select tests.must(api.save_permit_draft(tests.key(), tests.permit_of(tests.w('wp_wait'), tests.w('pc_wah')), '{"access": ["mewp"]}', now() + interval '2 hours', now() + interval '1 day'));
select tests.must(api.set_permit_team(tests.key(), tests.permit_of(tests.w('wp_wait'), tests.w('pc_wah')), jsonb_build_array(
  jsonb_build_object('person_id', tests.w('p_op'), 'role', 'supervisor'))));
select tests.must(api.submit_permit(tests.key(), tests.permit_of(tests.w('wp_wait'), tests.w('pc_wah')),
  tests.version('core.permit', tests.permit_of(tests.w('wp_wait'), tests.w('pc_wah')))));
select tests.login(tests.w('u_pam'));
select tests.must(api.decide_step(tests.key(), (select s.id from core.permit_step s join core.permit p on p.current_version_id = s.permit_version_id
   where p.id = tests.permit_of(tests.w('wp_wait'), tests.w('pc_wah')) and s.kind = 'review' order by s.group_no, s.step_key limit 1), 'more_information', 'Need the MEWP details',
  p_rfi => '{"message": "Please confirm the MEWP and its operator.", "items": [{"about": "access", "text": "MEWP make and model"}, {"about": "job", "text": "Operator name and IPAF card"}]}'));
select tests.logout();
select is((select count(*)::int from core.notification n join core.rfi f on f.id = n.record_id
            where n.event = 'information_requested' and n.recipient_person_id = tests.w('p_op') and n.class = 'routine'
              and f.permit_version_id = (select current_version_id from core.permit where id = tests.permit_of(tests.w('wp_wait'), tests.w('pc_wah')))), 1,
  'the job''s contact is told, once, that information was requested (8a, routine)');

-- ---- Who sees the venue dashboard ---------------------------------------------------------------------
select tests.login(tests.w('u_platform'));
select is(api.venue_dashboard(tests.w('v1')) ->> 'code', 'not_visible', 'a platform administrator sees no venue''s work (invariant 9)');
select tests.login(tests.w('u_b1'));
select is(api.venue_dashboard(tests.w('v1')) ->> 'code', 'not_visible', 'nor does another customer''s administrator');
select tests.login(tests.w('u_cara'));
select is(api.venue_dashboard(tests.w('v1')) ->> 'code', 'not_visible', 'nor a contractor''s administrator with no appointment there');
select is(api.venue_dashboard(gen_random_uuid()) ->> 'code', 'not_visible', 'an unknown venue looks the same as one you cannot see');
select tests.login(tests.w('u_pam'));
insert into t_r select 'pam', api.venue_dashboard(tests.w('v1'));
select is((select v ->> 'ok' from t_r where name = 'pam'), 'true', 'an appointee at the venue sees it');
select tests.login(tests.w('u_a1'));
insert into t_r select 'a1', api.venue_dashboard(tests.w('v1'));
select is((select v ->> 'ok' from t_r where name = 'a1'), 'true', 'and so does its tenant administrator');
select ok(not ((select v from t_r where name = 'a1')::text ~* '"(count|total|score|percent|rag|colour)"'),
  'no counts, scores, percentages or colours anywhere in it (CLAUDE.md §6)');

-- ---- 1. Today's work -----------------------------------------------------------------------------------
select is((select count(*)::int from t_r, jsonb_array_elements(v -> 'work') p where name = 'a1'
            and (p ->> 'id')::uuid in (select id from core.permit where work_package_id = tests.w('wp_live'))), 2,
  'today''s work lists both live permits on the job');
select is((select string_agg(distinct p ->> 'status', ',') from t_r, jsonb_array_elements(v -> 'work') p where name = 'a1'
            and (p ->> 'id')::uuid in (select id from core.permit where work_package_id = tests.w('wp_live'))), 'active',
  'with their recorded state');
select ok((select bool_and(p ? 'starts_at' and p ? 'areas' and p ? 'phase') from t_r, jsonb_array_elements(v -> 'work') p where name = 'a1'),
  'each with where, its start and its event phase');
select is((select count(*)::int from t_r, jsonb_array_elements(v -> 'work') p where name = 'a1'
            and (p ->> 'id')::uuid in (select id from core.permit where work_package_id = tests.w('wp_wait'))), 0,
  'work still under review is not shown as today''s work');

-- ---- 2. Decisions due, with owners and the start time ----------------------------------------------------
select is(jsonb_array_length(tests.items((select v from t_r where name = 'a1'), 'due', '%Decide:%')) > 0, true,
  'the open step on the waiting Work Approval is a decision due');
select ok((select bool_and(i ->> 'who' = 'Pam Authority' and i ->> 'at_label' = 'Starts' and (i ->> 'at')::timestamptz > now())
             from jsonb_array_elements(tests.items((select v from t_r where name = 'a1'), 'due', '%Decide:%')) i),
  'owned by the people whose appointment covers it, by name, with the work''s start time');
select is((select i ->> 'what' from jsonb_array_elements(tests.items((select v from t_r where name = 'a1'), 'due', '%information request%')) i limit 1),
  'Answer the information request: Please confirm the MEWP and its operator.', 'the information request is due from the applicant');
select is((select i ->> 'who' from jsonb_array_elements(tests.items((select v from t_r where name = 'a1'), 'due', '%information request%')) i limit 1),
  'Oli Operative', 'owned by the job''s contact and supervisor, by name');
select tests.logout();
select is(core.owner_names('{}'), 'Nobody currently holds an appointment for this', 'an item nobody can act on says so, rather than being hidden');

-- ---- 3. Stopped work ------------------------------------------------------------------------------------
select tests.login(tests.w('u_op'));
select tests.must(api.stop_work(tests.key(), tests.w('wah'), 'weather', 'Wind over the limit'));
select tests.login(tests.w('u_a1'));
insert into t_r select 'a1b', api.venue_dashboard(tests.w('v1'));
select is(jsonb_array_length(tests.items((select v from t_r where name = 'a1b'), 'stopped', '%Wind over the limit%')), 2,
  'the stop shows on the stopped permit and its Work Approval');
select ok((select bool_and(i ->> 'who' = 'An issuer for this permit''s class and area' or i ->> 'who' like 'Whoever can lift%')
             from jsonb_array_elements(tests.items((select v from t_r where name = 'a1b'), 'stopped', '%Wind over the limit%')) i),
  'each with whoever can lift it');
select is(tests.status_of(tests.w('wah')), 'suspended', 'reading the dashboard changes nothing');

-- ---- 4. Hand-backs due ------------------------------------------------------------------------------------
select tests.login(tests.w('u_ivy'));
select tests.must(api.lift_suspension(tests.key(), (select id from core.permit_suspension where permit_id = tests.w('wah') and kind = 'stop'), 'Wind dropped'));
select tests.must(tests.reaccept(tests.permit_of(tests.w('wp_live'), tests.w('pc_wa'))));
select tests.must(tests.reaccept(tests.w('wah')));
select tests.login(tests.w('u_op'));
select tests.must(api.hand_back_permit(tests.key(), tests.w('wah'), tests.version('core.permit', tests.w('wah')), true, null, 'Lamps replaced', true));
select tests.login(tests.w('u_a1'));
insert into t_r select 'a1d', api.venue_dashboard(tests.w('v1'));
select is((select i ->> 'what' from jsonb_array_elements(tests.items((select v from t_r where name = 'a1d'), 'closing', '%Work at height%')) i limit 1),
  'Handed back: accept or reject it', 'a hand-back waiting for its decision is listed');
select is((select i ->> 'who' from jsonb_array_elements(tests.items((select v from t_r where name = 'a1d'), 'closing', '%Work at height%')) i limit 1),
  'A hand-back acceptor', 'with who decides it');

-- ---- 5. Restrictions affecting today's work: the fact, never the grounds (Q208) ----------------------------
select tests.login(tests.w('u_r'));
select tests.must(api.impose_restriction(tests.key(), tests.w('v1'), 'person', tests.w('p_owen'), 'Abusive to gate staff'));
select tests.login(tests.w('u_a1'));
insert into t_r select 'a1c', api.venue_dashboard(tests.w('v1'));
select ok(jsonb_array_length(tests.items((select v from t_r where name = 'a1c'), 'affecting', '%Owen%is restricted at this venue%')) > 0,
  'a restricted team member on today''s work is listed');
select ok(not ((select v -> 'affecting' from t_r where name = 'a1c')::text like '%Abusive%'), 'without the grounds');
select ok((select bool_and(i ->> 'who' = 'The authority that imposed the restriction')
             from jsonb_array_elements(tests.items((select v from t_r where name = 'a1c'), 'affecting', '%Owen%')) i),
  'naming who can resolve it');

-- ---- Organisation dashboard: who sees it -------------------------------------------------------------------
select tests.login(tests.w('u_cara'));
select is(api.organisation_dashboard(tests.w('org_o')) ->> 'code', 'not_visible', 'another organisation''s administrator cannot see it');
select tests.login(tests.w('u_a1'));
select is(api.organisation_dashboard(tests.w('org_o')) ->> 'code', 'not_visible', 'nor the venue''s tenant administrator: it is the organisation''s own view');
select tests.login(tests.w('u_platform'));
select is(api.organisation_dashboard(tests.w('org_o')) ->> 'code', 'not_visible', 'nor a platform administrator');
select tests.login(tests.w('u_op'));
insert into t_r select 'op', api.organisation_dashboard(tests.w('org_o'));
select is((select v ->> 'ok' from t_r where name = 'op'), 'true', 'its accountable administrator sees it');
select tests.login(tests.w('u_cara'));
select is(api.organisation_dashboard(tests.w('org_c')) ->> 'ok', 'true', 'Cara sees her own organisation''s');
select is((select jsonb_array_length(api.organisation_dashboard(tests.w('org_c')) -> 'jobs')), 0, 'which has none of Orbit''s jobs');

-- ---- Organisation dashboard: the five groups ----------------------------------------------------------------
select ok((select v -> 'jobs' from t_r where name = 'op') @> jsonb_build_array(jsonb_build_object('id', tests.w('wp_wait'))),
  '1. the job due next is listed');
select ok((select bool_and(j ? 'permits') from t_r, jsonb_array_elements(v -> 'jobs') j where name = 'op'), 'with the state of each permit it needs');
select is((select i -> 'items' from jsonb_array_elements(tests.items((select v from t_r where name = 'op'), 'returned', '%MEWP%')) i limit 1),
  '["MEWP make and model", "Operator name and IPAF card"]'::jsonb, '2. the information request shows exactly what was asked');
select ok(jsonb_array_length(tests.items((select v from t_r where name = 'op'), 'workers', '%Owen%is restricted at this venue%')) > 0,
  '3. a worker on planned work who cannot take part is listed');
select ok(not ((select v from t_r where name = 'op')::text like '%Abusive%'), 'without the grounds');
select tests.logout();
select is((select string_agg(distinct core.step_owner_words(s), ',') from core.permit_step s where s.kind = 'occupier'), 'The affected occupier',
  'an occupier''s step is owned by "the affected occupier", never by name');
select tests.login(tests.w('u_op'));
select ok(jsonb_array_length(tests.items((select v from t_r where name = 'op'), 'venue_decisions', '%Waiting for:%')) > 0,
  '4. the venue decisions it is waiting for are listed');
select ok((select bool_and(i ->> 'who' in ('The affected occupier', 'The landlord or operator', 'The venue''s reviewer'))
             from jsonb_array_elements(tests.items((select v from t_r where name = 'op'), 'venue_decisions', '%Waiting for:%')) i),
  'each owned by a role, not a person');
select ok(not ((select v from t_r where name = 'op')::text like '%Olga Authority%' or (select v from t_r where name = 'op')::text like '%Pam Authority%'
               or (select v from t_r where name = 'op')::text like '%Other Rigging%'),
  'the occupier and the venue''s appointees are never named to the contractor (P5-6)');
select ok((select v -> 'live' from t_r where name = 'op') @> jsonb_build_array(jsonb_build_object('id', tests.w('wah'), 'status', 'hand_back_pending')),
  '5. the permit waiting for its hand-back is among its live permits');

-- ---- Visits: entry only, on both dashboards -----------------------------------------------------------------
select tests.set_w('tv_aa', tests.new_type('AA', 'Access Authority', array['access.approve', 'venue_config.approve'], '{}'));
select tests.set_w('tv_oa', tests.new_type('OA', 'Occupier Access', array['access.consent_occupier'], '{}'));
select tests.set_w('u_axel', (tests.root_ta('axel@a.test', 'Axel', tests.w('tv_aa'), array[tests.w('pc_wa')], tests.w('site')))[1]);
select tests.set_w('u_opal', (tests.root_ta('opal@a.test', 'Opal', tests.w('tv_oa'), array[tests.w('pc_wa')], tests.w('hall2')))[1]);
select tests.login(tests.w('u_a1'));
select tests.set_w('pc1', (api.create_venue_config_draft(tests.key(), tests.w('v1'), 'access_purposes') ->> 'id')::uuid);
select tests.must(api.save_venue_config_draft(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1')),
  '{"purposes": [{"key": "survey", "name": "Escorted survey", "allows": "Looking and measuring", "prohibits": "Any work",
      "induction_course_ids": [], "escort": "always", "occupier_consent": true}]}', 'Visitor rules (test values)'));
select tests.must(api.propose_venue_config(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1'))));
select tests.login(tests.w('u_axel'));
select tests.must(api.decide_venue_config(tests.key(), tests.w('pc1'), tests.version('core.venue_config_version', tests.w('pc1')), 'approve', 'Agreed'));
select tests.login(tests.w('u_op'));
select tests.set_w('av1', tests.must(api.request_access(tests.key(), tests.w('v1'), tests.w('org_o'), 'survey', 'Survey the lighting bar',
  array[tests.w('hall1'), tests.w('hall2')], now() + interval '1 hour', now() + interval '1 day', array[tests.w('p_nia')])));
select tests.login(tests.w('u_a1'));
insert into t_r select 'a1v', api.venue_dashboard(tests.w('v1'));
select ok((select v -> 'visits' from t_r where name = 'a1v') @> jsonb_build_array(jsonb_build_object('id', tests.w('av1'), 'status', 'requested', 'purpose', 'Escorted survey')),
  'the venue sees the visit in the period, as a visit (entry only)');
select ok((select bool_or(i ->> 'kind' = 'visit' and i ->> 'what' = 'Decide the visit request (entry only)' and i ->> 'who' = 'Axel Authority')
             from jsonb_array_elements((select v -> 'due' from t_r where name = 'a1v')) i),
  'and the request is a decision due, owned by the access authority who can decide it');
select tests.login(tests.w('u_op'));
insert into t_r select 'opv', api.organisation_dashboard(tests.w('org_o'));
select ok((select v -> 'visits' from t_r where name = 'opv') @> jsonb_build_array(jsonb_build_object('id', tests.w('av1'), 'consents_waiting', true)),
  'the organisation sees its visit waiting for an occupier''s consent');
select ok((select bool_or(i ->> 'what' like 'Visit request: waiting for an affected occupier''s consent%' and i ->> 'who' = 'The venue''s access authority')
             from jsonb_array_elements((select v -> 'venue_decisions' from t_r where name = 'opv')) i),
  'with whose decision it waits for, as a role');
select ok(not ((select v from t_r where name = 'opv')::text like '%Opal%' or (select v from t_r where name = 'opv')::text like '%Axel%'),
  'never naming the occupier''s representative or the access authority');
select tests.login(tests.w('u_opal'));
select tests.must(api.consent_access(tests.key(), tests.w('av1'), tests.w('hall2'), tests.w('org_o2'), 'given', 'Stand closed that morning'));
select tests.login(tests.w('u_axel'));
select tests.must(api.decide_access(tests.key(), tests.w('av1'), tests.version('core.access_authorisation', tests.w('av1')), 'approve', 'Fine',
  '{"escort": "Vic from security"}'));
select tests.login(tests.w('u_r'));
select tests.must(api.impose_restriction(tests.key(), tests.w('v1'), 'person', tests.w('p_nia'), 'Lent her pass to someone'));
select tests.login(tests.w('u_a1'));
select ok((select bool_or(i ->> 'title' = (select reference from core.access_authorisation where id = tests.w('av1')) and i ->> 'what' like '%is restricted at this venue')
             from jsonb_array_elements(api.venue_dashboard(tests.w('v1')) -> 'affecting') i),
  'a restricted person on the roster affects the visit, for the venue');
select tests.login(tests.w('u_op'));
select ok((select bool_or(i ->> 'what' like '%is restricted at this venue and will not be admitted' and not (i::text like '%Lent her pass%'))
             from jsonb_array_elements(api.organisation_dashboard(tests.w('org_o')) -> 'workers') i),
  'and for the organisation, without the grounds');
select tests.login(tests.w('u_pam'));
select ok((select bool_or(r ->> 'arrived_at' = 'did not attend' and r ->> 'purpose' = 'Escorted survey')
             from jsonb_array_elements(api.report('visit_attendance', tests.w('v1'), tests.today(), tests.today() + 1) -> 'rows') r),
  'the attendance report lists the roster, including who did not attend');

-- ---- Reports ----------------------------------------------------------------------------------------------
select tests.login(tests.w('u_pam'));
insert into t_r select 'lead', api.report('approval_lead_times', tests.w('v1'), tests.today(), tests.today());
select is((select v ->> 'ok' from t_r where name = 'lead'), 'true', 'an appointee reports on the venue');
select ok((select jsonb_array_length(v -> 'rows') from t_r where name = 'lead') >= 4, 'every step decided today is a row');
select ok((select bool_and(r ->> 'decided_by' in ('Pam Authority', 'Olga Authority'))
             from t_r, jsonb_array_elements(v -> 'rows') r where name = 'lead'), 'with who decided it');
select ok((select bool_and((r ->> 'hours')::numeric >= 0) from t_r, jsonb_array_elements(v -> 'rows') r where name = 'lead'),
  'and how long after the request was submitted');
select is((select jsonb_agg(c ->> 'key') from t_r, jsonb_array_elements(v -> 'columns') c where name = 'lead'),
  '["decided_at", "permit", "organisation", "step", "outcome", "decided_by", "submitted_at", "hours"]'::jsonb, 'with its columns stated once, for the screen and the CSV');
select is((select r ->> 'questions' from t_r, jsonb_array_elements((api.report('returns', tests.w('v1'), tests.today(), tests.today())) -> 'rows') r limit 1),
  'MEWP make and model; Operator name and IPAF card', 'the returns report gives exactly what was asked');
select is((select r ->> 'outcome' from jsonb_array_elements((api.report('hand_backs', tests.w('v1'), tests.today(), tests.today())) -> 'rows') r limit 1),
  'waiting', 'the hand-back report shows the hand-back still waiting');
select ok(jsonb_typeof(api.report('gate_activity', tests.w('v1'), tests.today(), tests.today()) -> 'rows') = 'array', 'gate activity reports for the venue''s side');
select is(api.report('scores', tests.w('v1'), tests.today(), tests.today()) ->> 'code', 'invalid_content', 'only the defined reports');
select is(api.report('returns', tests.w('v1'), tests.today(), tests.today() - 1) ->> 'code', 'invalid_content', 'the period runs forwards');
select is(api.report('returns', tests.w('v1'), tests.today() - 400, tests.today()) ->> 'code', 'invalid_content', 'and is at most 366 days');

-- Late notice: one row per request, with its stated cause (Q96).
-- Owen's restriction is lifted; hot works now needs three working days' notice, which a job for
-- today cannot meet.
select tests.login(tests.w('u_r'));
select tests.must(api.lift_restriction(tests.key(), (select id from core.restriction where person_id = tests.w('p_owen') and status = 'active'),
  tests.version('core.restriction', (select id from core.restriction where person_id = tests.w('p_owen') and status = 'active')), 'Apologised; briefed again'));
select tests.logout();
select tests.configure_class(tests.w('pc_hw'), jsonb_set(tests.class_config(
  '[{"key": "hw-review", "name": "Hot works review", "kind": "review", "group": 1}]'), '{notice,amount}', '3'));
select tests.set_w('wp_late', tests.today_job('Fix the bracket', array[tests.w('pc_hw')]));
select tests.approve_permit(tests.permit_of(tests.w('wp_late'), tests.w('pc_wa')), '{}');
select tests.approve_permit(tests.permit_of(tests.w('wp_late'), tests.w('pc_hw')), '{}');
select tests.login(tests.w('u_op'));
select tests.must(api.request_exception(tests.key(), tests.permit_of(tests.w('wp_late'), tests.w('pc_hw')), 'late_notice',
  'A lighting bracket failed overnight', 'The stand cannot open safely without it'));
select tests.login(tests.w('u_pam'));
select is((select count(*)::int from jsonb_array_elements((api.report('late_requests', tests.w('v1'), tests.today(), tests.today())) -> 'rows') r
            where r ->> 'cause' like 'A lighting bracket failed overnight%' and r ->> 'route' = 'Late notice'
              and r ->> 'organisation' = 'Orbit Electrical Ltd' and r ->> 'outcome' = 'not yet decided'),
  (select count(*)::int from core.exception_request where kind = 'late_notice' and reason = 'A lighting bracket failed overnight'),
  'late requests are reported by organisation, route and stated cause, with their outcome');
select is((select count(*)::int from jsonb_array_elements((api.report('late_requests', tests.w('v1'), tests.today() - 2, tests.today() - 1)) -> 'rows') r
            where r ->> 'cause' like 'A lighting bracket failed overnight%'), 0, 'and only in the period asked for');

select tests.login(tests.w('u_op'));
select ok((select bool_and(case when (pm ->> 'kind') = 'child' then jsonb_array_length(pm -> 'missing') > 0 else jsonb_array_length(pm -> 'missing') = 0 end)
             from jsonb_array_elements(api.organisation_dashboard(tests.w('org_o')) -> 'jobs') j, jsonb_array_elements(j -> 'permits') pm
            where (j ->> 'id')::uuid = tests.w('wp_late')),
  'the organisation sees what its approved hot works still needs before issue, and nothing against its ready Work Approval');

-- Approved requests: ready to issue, with who can issue it, or what is missing before issue.
select tests.login(tests.w('u_a1'));
insert into t_r select 'a1e', api.venue_dashboard(tests.w('v1'));
select ok((select bool_or(i ->> 'kind' = 'issue' and i ->> 'what' = 'Ready to issue' and i ->> 'who' = 'Ivy Authority')
             from jsonb_array_elements(tests.items((select v from t_r where name = 'a1e'), 'due', '%Work Approval for ' ||
               (select reference from core.work_package where id = tests.w('wp_late')) || '%')) i),
  'an approved Work Approval with nothing missing is ready to issue, by the issuers who can');
select ok((select bool_or(i ->> 'kind' = 'prerequisite' and i ->> 'what' like 'Missing before issue: %')
             from jsonb_array_elements(tests.items((select v from t_r where name = 'a1e'), 'due', '%Hot works for ' ||
               (select reference from core.work_package where id = tests.w('wp_late')) || '%')) i),
  'the late hot works lists what is missing before it can be issued');

-- Visibility of reports.
select tests.login(tests.w('u_cara'));
select is(api.report('returns', tests.w('v1'), tests.today(), tests.today()) ->> 'code', 'not_visible', 'a contractor cannot read the venue''s report');
select is(api.report('returns', tests.w('v1'), tests.today(), tests.today(), tests.w('org_o')) ->> 'code', 'not_visible', 'nor another organisation''s rows');
select is(jsonb_array_length(api.report('returns', tests.w('v1'), tests.today(), tests.today(), tests.w('org_c')) -> 'rows'), 0, 'only its own, which has none');
select tests.login(tests.w('u_op'));
select ok(jsonb_array_length(api.report('returns', tests.w('v1'), tests.today(), tests.today(), tests.w('org_o')) -> 'rows') > 0, 'Orbit sees its own returns');
select is(api.report('gate_activity', tests.w('v1'), tests.today(), tests.today(), tests.w('org_o')) ->> 'code', 'not_visible',
  'but not gate activity, which is about everyone');
select tests.login(tests.w('u_b1'));
select is(api.report('returns', tests.w('v1'), tests.today(), tests.today()) ->> 'code', 'not_visible', 'another customer''s administrator cannot report on this venue');
select tests.login(tests.w('u_platform'));
select is(api.report('approval_lead_times', tests.w('v1'), tests.today(), tests.today()) ->> 'code', 'not_visible', 'nor can a platform administrator');
select is(jsonb_array_length(api.report_scopes() -> 'venues'), 0, 'who is offered no venue to report on');
select tests.login(tests.w('u_op'));
select ok((api.report_scopes() -> 'organisations') @> jsonb_build_array(jsonb_build_object('id', tests.w('org_o'))), 'an administrator is offered their organisation');

select * from finish();
rollback;
