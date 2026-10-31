# Call-Completed Webhook Service

FastAPI service that receives call-completion webhooks from a voice platform, stores the result in Aurora PostgreSQL, and asks the CRM to schedule a retry. It runs on ECS Fargate behind an ALB in `ap-south-1`.

This README has three parts:

1. [What was deployed](#1-what-was-deployed)
2. [Answers to the assignment questions](#2-answers-to-the-assignment-questions)
3. [Change log: what was wrong and why it was fixed](#3-change-log-what-was-wrong-and-why-it-was-fixed)

---

## 1. What was deployed

| Choice | What we use | Not used |
|---|---|---|
| Compute | ECS Fargate in private subnets | Lambda |
| Database | Aurora PostgreSQL, IAM auth (no DB password in the app) | SQLite |
| Image registry | Docker Hub (public repo, tag = commit SHA) | ECR |
| CRM URL | Plain environment variable | Secrets Manager |
| Entry point | ALB over plain HTTP (port 80), reached by its own DNS name | Route 53, ACM certificate |
| Network | Hand-written VPC, subnets, NAT, route tables | `terraform-aws-modules/vpc` |
| Deploys | GitOps: CI commits the image tag, Terraform applies it | `aws ecs update-service` from CI |
| AWS auth in CI | GitHub OIDC (no stored AWS keys) | Long-lived access keys |

### Repository layout

```
app/          main.py, tests, Dockerfile, requirements
bootstrap/    run once by hand: state bucket + GitHub OIDC role
infra/        network, security, database, iam, alb, ecs, autoscaling, outputs
.github/workflows/
  app.yml        test -> build -> push -> commit new tag -> call terraform.yml
  terraform.yml  terraform apply (the only thing that touches AWS)
```

### Deploy flow

```
push to app/**  -> test -> build + push image (tag = commit SHA)
                -> commit tag to infra/image.auto.tfvars
                -> terraform apply -> new task definition -> ECS rolling deploy
                   (circuit breaker rolls back if new tasks are unhealthy)

Rollback        -> git revert the "deploy: image xxxx" commit -> terraform applies the old tag
```

---

## 2. Answers to the assignment questions

### A1. Defects in the original service

I assumed `attempt` = retries already done (0 = the original call).

| # | Where | What goes wrong in production | Severity | Fix |
|---|---|---|---|---|
| 1 | `if disposition == "NO_ANSWER" or "BUSY":` | `"BUSY"` is always truthy, so every call (even answered ones) gets a retry. | High | `disposition in {"NO_ANSWER", "BUSY"}` |
| 2 | f-string SQL insert | SQL injection. A quote in the data also breaks the insert. | High | Parameterized query (`%s`) |
| 3 | No `commit()` | Nothing is saved. Looks fine locally because the same connection sees its own uncommitted rows. | High | `with conn:` commits |
| 4 | Global `sqlite3` file | Container disk is ephemeral and each task has its own file, so data is lost and split. | High | Aurora with IAM token per connection |
| 5 | `datetime.now()` | AWS runs in UTC, so the 08:00-19:00 IST window is evaluated in the wrong timezone. | High | `datetime.now(ZoneInfo("Asia/Kolkata"))` |
| 6 | `attempt > len(RETRY_GAPS_MIN)` then `[attempt]` | Off by one. `attempt == 3` passes the guard, then `IndexError` gives a 500. | High | `attempt >= len(...)` |
| 7 | `json={"next_call": nxt}` | `datetime` is not JSON serializable. The bare `except` hides it, so the CRM never gets a single call. | High | `nxt.isoformat()` |
| 8 | `timeout=None` and `async def` + blocking `requests` | A slow CRM hangs forever and blocks the event loop for every request. | High | `timeout=5`, plain `def` handler (runs in a threadpool) |
| 9 | `next_time.hour > 19` | 19:30 passes as allowed. Times before 08:00 are not handled. | Medium | Compare against `time(8,0)` and `time(19,0)` |
| 10 | `.replace(hour=9) + timedelta(days=1)` | Window opens at 08:00, not 09:00. Old minutes are kept. A time after midnight is pushed an extra day. | Medium | Set exactly 08:00, add a day only when past 19:00 |
| 11 | `history=[]` | Mutable default argument is shared across calls. A memory leak, and never used. | Medium | Remove it |
| 12 | `except:` + `sleep(1)` | Hides every error. No `raise_for_status`, so CRM 500s count as success. Returns `None` after 5 silent failures. | Medium | Catch `requests.RequestException`, log, back off, return 502 if all tries fail |
| 13 | `notify_crm` when `nxt is None` | Sends `null` to the CRM once retries are exhausted. | Medium | Only notify if a next time exists |
| 14 | `body["account_id"]` | Missing key gives a 500. `attempt` can be a string or negative. | Medium | Pydantic model |
| 15 | No idempotency | Voice platforms redeliver webhooks, causing duplicate rows and duplicate CRM retries. | Medium | `UNIQUE (account_id, attempt)` + idempotency key to the CRM |
| 16 | `CRM_URL` may be `None` | Every post fails silently. | Low | Check and fail loudly |
| 17 | No logging, no `/health` | Cannot debug, and the ALB has nothing to check. | Low | JSON logs and `/health` |

### 1. Production architecture (ap-south-1, 500 req/s peak, PII in India, CRM down for minutes)

```
 Voice platform
       | HTTP (HTTPS recommended for real production)
       v
 ALB (public subnets, 2 AZs)
       |
 ------+-------------------- private subnets -------------------
       v
 ECS Fargate service (2 to 20 tasks, autoscaling on request count)
    |            |                |
    |            |                +--> NAT Gateway --> CRM (internet)
    |            +--> CloudWatch Logs
    v
 ------------ database subnets (no internet route) ------------
   Aurora PostgreSQL (writer + reader, 2 AZs, encrypted, IAM auth)

 Recommended addition for "CRM down for minutes":
   Fargate --> SQS queue --> worker (Fargate) --> CRM
                  +--> DLQ + alarm on queue age
```

| Service | Why |
|---|---|
| ALB | Spreads 500 req/s over tasks in several AZs. Runs the `/health` check and provides the autoscaling metric. |
| ECS Fargate | Runs the container with no servers to patch. Scales on request count. |
| Aurora PostgreSQL | Multi-AZ, automatic failover, encrypted. IAM auth means no DB password. |
| NAT Gateway (one per AZ) | Lets private tasks reach the external CRM and Docker Hub while staying unreachable from outside. |
| CloudWatch | Logs, metrics, alarms (5xx, unhealthy hosts, queue age). |
| S3 (Terraform state) | Versioned, encrypted state bucket in `ap-south-1`. |
| SQS + DLQ + worker (recommended, not built) | Absorbs CRM outages: save the call, queue the CRM work, return 200 fast, retry with backoff. |

**Keeping PII in India**
- Use only `ap-south-1`. For disaster recovery use `ap-south-2` (Hyderabad).
- Add an SCP that denies other regions.
- Keep encryption keys in-region and do not enable cross-region copies outside India.
- Never log phone numbers. This service only handles `account_id`.

**Known gap at 500 req/s:** the app opens one new IAM-auth DB connection per request. Aurora IAM auth is meant for under about 200 new connections per second. Add RDS Proxy or a small connection pool before real peak load.

**Known gap on security:** plain HTTP means webhook bodies are unencrypted and anyone can send requests. Add HTTPS and a shared-secret header check before real borrower data flows.

### 2. Task role vs task execution role

- **Execution role:** used by ECS/Fargate itself to start the task. It pulls the image, writes logs to CloudWatch, and reads secrets to inject them as environment variables.
- **Task role:** used by your code while it runs (through boto3). Here it only needs `rds-db:connect`.

Least-privilege statement on the **execution role** to read one secret:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "secretsmanager:GetSecretValue",
    "Resource": "arn:aws:secretsmanager:ap-south-1:<ACCOUNT_ID>:secret:call-webhook/crm-url-*"
  }]
}
```

The `-*` is needed because AWS appends a random 6-character suffix to a secret's ARN. If the secret uses a customer-managed KMS key, also allow `kms:Decrypt` on that key. (This project currently keeps the CRM URL as a plain environment variable, so the execution role only has the standard logging policy.)

### 3. Triage after a deploy with a 5xx spike

1. **Confirm timing and scope.** Does the spike start at the deploy time? Check the ECS service Deployments/Events tab to see whether the circuit breaker already fired.
2. **Which 5xx?** Compare `HTTPCode_ELB_5XX` (502/503/504) with `HTTPCode_Target_5XX` (the app returned 500).
3. **If ELB 5xx:** check `UnHealthyHostCount` and the stopped tasks and their reasons. Typical causes: image pull failure, OOM kill, wrong port or health path.
4. **If target 5xx:** query CloudWatch Logs Insights on the new tasks: `fields @timestamp, event, error | filter level="ERROR" | sort @timestamp desc`. Typical causes: DB IAM auth failure, missing env var, schema mismatch.
5. **Check dependencies:** Aurora connections and CPU, and CRM errors. The cause may not be the deploy.
6. **Decide fast.** If users are affected, roll back first and debug afterwards.

**Rollback**
- Automatic: the deployment circuit breaker (`rollback = true`) reverts when new tasks keep failing.
- Permanent (GitOps): `git revert` the `deploy: image xxxx` commit and push. `terraform.yml` applies the previous tag.
- Emergency manual: `aws ecs update-service --cluster call-webhook --service call-webhook --task-definition call-webhook:<last-good-revision>`. Follow up with a git revert so git matches reality.
- Keep DB changes backward-compatible so the old version works with the new schema.

### 4. Lambda + API Gateway vs ECS Fargate

| Pick Lambda + API Gateway when | Pick ECS Fargate when |
|---|---|
| Traffic is low or spiky, idle most of the time | Traffic is steady and high (500 req/s peaks) |
| You want zero servers and pay per request | You want predictable cost at sustained load |
| Requests are short and stateless | You want connection pools and long-lived workers |
| Few or no DB connections | Heavy DB use (Lambda concurrency explodes connections without RDS Proxy) |
| Cold starts are acceptable | You need consistent low latency |

**For this service: Fargate.** Steady traffic, a database, and a slow external CRM. API Gateway also has a 29-second timeout. Lambda would suit a small SQS worker if CRM traffic is light.

---

## 3. Change log: what was wrong and why it was fixed

### 3.1 Application code (`app/main.py`)

All 17 defects in the table in section 2 were fixed. The design changes behind them:

| Change | Why |
|---|---|
| `schedule_retry(attempt, now=None)` takes an injectable time | Makes the 07:30, 18:45 and 23:00 IST cases testable without waiting for real time. |
| Per-request DB connection with a fresh IAM token | IAM tokens expire after 15 minutes. A new token per connection never uses an expired one. |
| `ON CONFLICT (account_id, attempt) DO NOTHING` | Redelivered webhooks do not create duplicate rows. |
| Return 502 when the CRM fails | The voice platform redelivers. The insert is idempotent, so it is safe to repeat. |
| JSON log lines | CloudWatch Logs Insights can filter by field (`event`, `account_id`). |
| `/health` does not touch the DB | A brief Aurora failover does not make the ALB kill healthy tasks. |

### 3.2 Things that remain open (be honest about these)

- **Not fully tested.** The plan succeeds (43 resources). The apply surfaced the Aurora version error. The `null_resource.db_init` Data API step and the first ECS rollout have not been confirmed yet.
- **Plain HTTP and no auth** on the webhook. Add HTTPS and a shared-secret header check before production.
- **500 req/s DB connections:** add RDS Proxy or a pool.
- **CRM outages of several minutes:** the 502-and-redeliver approach covers short outages only. Add SQS + worker for long ones.
- **Docker Hub public repo:** Fargate can pull without credentials, but many tasks share the NAT IPs. Watch for `CannotPullContainerError` from pull rate limits.
- **`deletion_protection = true`** on Aurora means `terraform destroy` fails until it is set to false and applied. Two NAT gateways and two Aurora instances cost money while running.
- **Branch protection on `main`** blocks the bot's tag commit unless the Actions bot is allowed to bypass it.
- **Broad CI role:** `PowerUserAccess` plus scoped IAM is limited by the OIDC trust (only `main` of this repo). Tighten it later.

---

## 4. Setup order

1. **Bootstrap** (once, with admin AWS credentials):
   ```bash
   cd bootstrap
   terraform init
   terraform apply -var github_repo=my-org/call-webhook -var state_bucket=my-unique-tfstate-bucket
   ```
2. Put the state bucket name in `infra/versions.tf`.
3. Create a **public** Docker Hub repo `call-webhook` and an access token. Build and push a first image by hand.
4. Set `image_repo` in `infra/terraform.tfvars` and `image_tag` in `infra/image.auto.tfvars`.
5. Check the Aurora version is valid in your region (see change 10) and set `aurora_engine_version`.
6. Add GitHub secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `AWS_DEPLOY_ROLE_ARN`, `CRM_URL`. Set workflow permissions to **Read and write**.
7. Push to `main`. The first apply takes about 15-20 minutes (mostly Aurora).
8. Test:
   ```bash
   curl http://$(terraform output -raw alb_dns)/health      # {"status":"ok"}
   ```
   Give `terraform output webhook_url` to the voice platform.

### Evidence commands

```bash
# Terraform
cd infra
terraform init
terraform validate
terraform plan | tee plan.txt

# Container
cd ../app
docker build -t call-webhook .
docker run --rm -p 8000:8000 -e CRM_URL=http://x call-webhook &
curl -s localhost:8000/health
docker inspect --format '{{.Config.User}}' call-webhook   # appuser

# Tests
pip install -r requirements-dev.txt && pytest -q
```