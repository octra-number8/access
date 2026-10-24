-- The fixture builds end to end through the API, and the root ceremony leaves the
-- expected state behind.
begin;
\ir _helpers.psql
select no_plan();

select is((select status from core.appointment where id = tests.w('ap_r')), 'in_force',
  'root appointment is in force after record, confirm and acknowledge');
select is((select confirmed_by_person_id from core.appointment where id = tests.w('ap_r')), tests.w('p_a2'),
  'root appointment was confirmed by the second administrator');
select is((select recorded_by_person_id from core.appointment where id = tests.w('ap_r')), tests.w('p_a1'),
  'root appointment records who recorded it');
select is((select appointed_by_person_id from core.appointment where id = tests.w('ap_r')), tests.w('p_d'),
  'root appointment is made by the duty holder');
select is((select appointed_under_appointment_id from core.appointment where id = tests.w('ap_h')), tests.w('ap_r'),
  'a granted appointment traces to the appointer''s appointment');
select is((select count(*)::int from core.status_history where record_id = tests.w('ap_r')), 3,
  'root appointment has three recorded states');
select ok((select acknowledged_at is not null from core.appointment where id = tests.w('ap_h')),
  'granted appointment was acknowledged by the appointee');
select is((select path from core.area where id = tests.w('stand1')),
  array[tests.w('site'), tests.w('hall1'), tests.w('stand1')], 'area path runs from the root');
select is((select count(*)::int from audit.verify_chain(tests.w('cust_a'))), 0, 'customer A audit chain verifies');
select is((select count(*)::int from audit.verify_chain(tests.w('cust_b'))), 0, 'customer B audit chain verifies');

select * from finish();
rollback;
