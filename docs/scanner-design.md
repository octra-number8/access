# Malware scanner (P2-5): self-hosted ClamAV — proposal

**Status:** Approved 24 October 2026 (D-013); **held off** by D-014. Built and tested, not deployed. Uploads are currently recorded as not scanned.

## 1. What it has to do

Every uploaded file starts `scan_pending` and cannot be opened by anyone until the scanner records `clean` (phase 2a, built and tested). The scanner must:

- scan each new document version once, and record the result through `api.record_scan_result` as the `malware_scanner` service account;
- **fail closed**: if it is down, behind, or its signatures are stale, files stay pending; nothing is ever marked clean by default or by timeout;
- never hold the Supabase service-role key, and never accept inbound connections;
- keep file contents and personal data out of its logs;
- run in the UK, alongside the database (assumption A8: Supabase London region).

## 2. Where it runs — recommendation

**AWS ECS Fargate, eu-west-2 (London), one always-on task.**

| | AWS Fargate, London (recommended) | Fly.io, London | Not suitable |
|---|---|---|---|
| Region | eu-west-2, same AWS region as Supabase London | lhr | Vercel functions: no long-running process, too little memory for ClamAV's signature database |
| Operations | Task restarts automatically; logs to CloudWatch; secrets in Secrets Manager | Simplest to deploy; less procurement familiarity | Render, Railway: no UK region |
| Approximate cost | 1 vCPU, 4 GB: about £30–40 a month | 4 GB machine: about £20–30 a month | |
| Network | No load balancer, no public IP needed (outbound only via NAT or public subnet with no inbound rules) | Outbound only | |

ClamAV keeps its full signature set in memory, so the task needs 3–4 GB; scanning is CPU-light at pilot volumes.

**Why AWS:** traffic between scanner and storage stays inside the same region and provider as Supabase, and AWS is the easiest answer to insurer and customer security questionnaires. **Fly.io London** is a reasonable alternative if you would rather not run an AWS account; the container is identical, so the choice can be changed later.

## 3. How it works

```
 contractor ──upload──▶ Next.js server (Vercel)
                         • checks size and type by content (magic bytes), not file name
                         • stores to private bucket  customer/document/version
                         • calls api.submit_document  → scan_pending
                                    │
 ┌──────────── scanner task (Fargate, London) ────────────┐
 │ worker (TypeScript)                   clamd + freshclam │
 │ 1. api.claim_scan_job()  ── leases one pending version  │
 │ 2. downloads the object with its own JWT                │
 │ 3. streams it to clamd (INSTREAM), never to disk        │
 │ 4. checks content type matches what was declared        │
 │ 5. api.record_scan_result(clean | infected | rejected)  │
 │ 6. api.scanner_heartbeat(signature version, queue)      │
 └─────────────────────────────────────────────────────────┘
```

- **Pull, not push.** The worker polls for work, so there is no endpoint to attack and no webhook secret to manage. Uploads wait at most one polling interval (proposed 5 seconds) plus scan time.
- **Claiming.** `api.claim_scan_job()` hands out one pending version with a short lease (`for update skip locked`), so a crashed scan is retried and two workers never scan the same file. Running a second task later needs no change.
- **Least privilege.** The scanner signs in as its own Supabase Auth user (the `malware_scanner` service account from phase 2a). A storage policy lets that account read only objects whose version is still `scan_pending`. It cannot read clean files, write files, or call any non-scanner action.
- **Signatures.** `freshclam` updates the signatures several times a day. If they are older than a set maximum, the worker stops scanning and raises an alert; files simply wait.
- **Limits.** clamd is configured to scan PDFs and images fully, with stream and file size limits just above the 20 MB upload limit, and archive and recursion limits set to resist decompression bombs. Anything it cannot fully scan is **not** clean.
- **Infected or rejected files** are never served. Removing the object and telling the uploader arrive with retention and notifications (phase 8); until then the record and object stay, locked.

## 4. Changes to the database (small, phase 2b migration)

- `api.claim_scan_job()` (service basis): lease a pending version; returns version id and storage path only.
- `api.scanner_heartbeat(...)` (service basis): records signature version and date, queue depth, last scan; readable by platform operations.
- Scan outcomes gain **`rejected`** (decision S3): the declared type does not match the content, or clamd could not fully scan it. Treated exactly like `infected` for release, but tells the contractor it is a file problem, not a virus.
- A storage policy on the documents bucket for the scanner account (read, pending versions only).

## 5. Monitoring and alerting

- **Queue age:** alert when the oldest pending file is older than a set threshold (proposed 15 minutes).
- **Heartbeat:** alert when no heartbeat for 5 minutes.
- **Signature age:** alert above the set maximum (proposed 24 hours; ClamAV publishes several times a day).
- **Alerts go to:** Octra platform operations. The service commitment (Q230) is still a founder decision.

These are platform settings, not venue configuration; the numbers above are proposals.

## 6. Local development and tests

- A `docker compose` service runs the official `clamav/clamav` image next to the test database. Pulling it is a one-off download of about 300 MB, which I will ask before doing.
- Tests use the EICAR test string (a harmless file every scanner flags) to prove `infected`, plus a type-mismatch file to prove `rejected`.
- There is **no "skip scanning" switch** anywhere, including in development (CLAUDE.md §5).

## 7. Decisions needed

| Ref | Decision | Recommendation |
|---|---|---|
| S1 | Hosting | AWS ECS Fargate, eu-west-2, one always-on task. Needs an AWS account owned by Octra Access Ltd. |
| S2 | Pull-based worker with leased jobs, no inbound endpoint | Yes. |
| S3 | Add a `rejected` scan outcome for type mismatch or incomplete scans | Yes. |
| S4 | Platform thresholds: poll 5 s, queue alert 15 min, heartbeat 5 min, signature maximum 24 h | Accept as starting values; review after the pilot. |
| S5 | Scanner credential: its own Supabase Auth login, stored in AWS Secrets Manager, rotated quarterly | Yes. |
| S6 | Pull the `clamav/clamav` image (~300 MB) for local tests | Yes, when 2b starts. |
