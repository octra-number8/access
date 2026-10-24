# Scanner deployment (AWS, eu-west-2) — runbook

Deploys the malware scanner agreed in D-013 ([docs/scanner-design.md](../../docs/scanner-design.md)).
Nothing here has been deployed yet: it needs an AWS account owned by Octra Access Ltd.

## One-off set-up (an Octra operator with AWS access)

1. **Account and region.** Use eu-west-2 (London) for everything below.
2. **Container registry.** Create two ECR repositories: `octra-scanner-clamd`, `octra-scanner-worker`.
3. **Images.** Build and push, tagged with the git commit:
   - `services/scanner/clamd` → `octra-scanner-clamd`
   - `services/scanner` → `octra-scanner-worker`
4. **Scanner login.** In the Supabase project, create an Auth user for the scanner with a long random password (not a person's account). Then, as the database owner, register it:
   `insert into core.service_account (auth_user_id, purpose) values ('<uuid>', 'malware_scanner');`
5. **Secret.** In Secrets Manager, create `octra/scanner` with keys `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SCANNER_EMAIL`, `SCANNER_PASSWORD`. The Supabase **service-role key is never given to the scanner**.
6. **IAM.** `octra-scanner-execution`: pull from the two ECR repositories, read only `octra/scanner`, write to log group `/octra/scanner`. `octra-scanner-task`: no permissions.
7. **Network.** A private subnet with outbound access (NAT gateway), or a public subnet with a public IP and a security group allowing **no inbound traffic**. The scanner only makes outbound connections (Supabase, ClamAV signature mirrors).
8. **Service.** Register `scanner-task-definition.json` (substitute the placeholders) and create an ECS service with desired count 1 and the default restart behaviour.
9. **Logs.** Log group `/octra/scanner`, retention 90 days (retention to be confirmed with the privacy adviser; logs contain version ids and outcomes only).

## Alerts (D-013 S4)

From `api.scanner_status` (platform administrators), alert Octra operations when:
- no heartbeat for 5 minutes;
- `state` is not `scanning`;
- `signature_date` older than 24 hours;
- `oldest_pending_at` older than 15 minutes.

## Rotation (S5)

Quarterly: set a new scanner password in Supabase Auth, update `SCANNER_PASSWORD` in `octra/scanner`, then force a new deployment. Record the rotation in the operations log.
