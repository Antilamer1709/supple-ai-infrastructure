# Monitoring

How the production backend, database and CloudFront are watched, where to look when an alert
arrives, and how to change who gets the alerts. Everything is CloudWatch, defined in
`monitoring.tf` (plus a few settings in `backend.tf`), and it all fits CloudWatch's always-free
tier. That tier also applies on the Paid plan, so monitoring costs $0.

Everything is in **eu-north-1** except CloudFront's metrics, which AWS keeps only in
**us-east-1**. The account's SCP denies SNS there, and an alarm can only notify a topic in its
own region, so there is no CloudFront alarm. The API's problems are caught on the Beanstalk
side instead (`api-5xx`, `api-slow`, `app-errors`).

## What emails you

Every address in `alert_emails` gets:

| Email | From | When |
|---|---|---|
| `ALARM: "supple-ai-prod-…"` / `OK: …` | CloudWatch alarms (the table below) | An alarm fires, and again when it clears |
| Beanstalk notifications | Elastic Beanstalk | Deploys, health changes, platform updates, failures |
| AWS Budgets | AWS Budgets | Actual or forecast monthly spend exceeds `budget_limit_usd` |

The alarm and Beanstalk emails come through the SNS topic `supple-ai-prod-alerts`. The budget
emails each address directly.

The Beanstalk email "Environment health has transitioned from Ok to Warning" is the only memory
alert: EC2 doesn't report memory to CloudWatch. While the Warning lasts, Elastic Beanstalk →
`supple-ai-prod-backend` → Health shows the cause, for example "90 % of memory is in use" (the
reason the instance moved from 1 GiB to 2 GiB). The cause disappears once health is Ok again.

## Where to look

| What | Where |
|---|---|
| Dashboard | `terraform output -raw monitoring_dashboard_url`, or CloudWatch → Dashboards → `supple-ai-prod-overview`. Shows the alarm states and graphs of everything below |
| Alarms | CloudWatch → Alarms → All alarms (all nine are in eu-north-1) |
| App metrics | CloudWatch → Metrics → All metrics → Custom namespaces → `SuppleAI/Backend` |
| Beanstalk metrics | All metrics → `ElasticBeanstalk` → Environment metrics |
| Instance metrics | All metrics → `EC2` → By Auto Scaling Group (the instance is replaced on platform updates; the group isn't) |
| Database metrics | All metrics → `RDS` → Per-Database Metrics → `supple-ai-prod-db` |
| CloudFront metrics | The dashboard's last graph (the app and API distribution), or switch to us-east-1 → All metrics → `CloudFront` → Per-Distribution Metrics, which also lists the media distribution |
| Logs | CloudWatch → Logs → **Log Analytics** for queries and the saved queries, **Log Management** for the log groups ("Where to click" below) |
| Health and events | Elastic Beanstalk → `supple-ai-prod-backend` → Health, Events |
| Every JVM meter | `/actuator/metrics` isn't reachable through CloudFront. Open a Session Manager shell on the instance (README, "Operations") and run `curl -s localhost:5000/actuator/metrics` |

### Metrics

| Metric | Namespace | Source | Meaning |
|---|---|---|---|
| `EnvironmentHealth` | `AWS/ElasticBeanstalk` | Beanstalk, free | 0 OK, 15 Warning, 20 Degraded, 25 Severe |
| `ApplicationRequests5xx` | `AWS/ElasticBeanstalk` | Beanstalk enhanced health, from nginx's log | API responses with a 5xx status |
| `ApplicationLatencyP95` | `AWS/ElasticBeanstalk` | Beanstalk enhanced health, from nginx's log | 95th-percentile API response time, in seconds |
| `supple.jvm.heap.used.value` | `SuppleAI/Backend` | Backend (Micrometer), every minute | Heap in use, in bytes |
| `supple.jvm.heap.max.value` | `SuppleAI/Backend` | Backend (Micrometer) | Maximum heap: 50% of the instance's memory |
| `hikaricp.connections.pending.value` | `SuppleAI/Backend` | Backend (Micrometer) | Requests waiting for a database connection |
| `ErrorLogLines` | `SuppleAI/Backend` | Log metric filter on the app log | ERROR lines the app wrote |
| `CPUUtilization`, `CPUCreditBalance` | `AWS/EC2`, `AWS/RDS` | AWS, free | CPU, and the burst credits a t4g instance has left |
| `FreeStorageSpace`, `DatabaseConnections` | `AWS/RDS` | AWS, free | Database disk left, open connections |
| `Requests`, `5xxErrorRate` | `AWS/CloudFront` (us-east-1) | AWS, free | Every request to the app and the API, and the share answered with a 5xx |

The two Beanstalk enhanced-health metrics and the four `SuppleAI/Backend` ones are custom
metrics: 6 of the 10 free.

## Alarms

Each alarm emails when it fires and again (`OK`) when it clears.

| Alarm | Fires when | Check first |
|---|---|---|
| `environment-unhealthy` | Beanstalk health is Degraded or Severe for 5 minutes, or Beanstalk stops reporting | Beanstalk → Health and Events for the cause. A deploy or platform update that didn't finish shows there. If the app crashed, the end of `web.stdout.log` |
| `api-5xx` | 5 or more API requests got a 5xx within 5 minutes | Saved queries *Recent errors* and *5xx responses by endpoint*. A 502 with no app error means the app was down or restarting: check `nginx/error.log` |
| `api-slow` | The API's p95 response time stayed above 2 seconds for 15 minutes | Saved query *Slowest endpoints*, then the database CPU graph and `db-pool-starved`. One slow endpoint means a query or code problem; everything slow means the instance or the database is overloaded |
| `heap-pressure` | Heap above 90% of its maximum for 15 minutes | The dashboard's heap graph. Steady growth points to a leak; a plateau near the max means the instance is too small. Restart from the Beanstalk console as a stopgap |
| `db-pool-starved` | Requests waited for a database connection for 5 minutes | Slow queries: *Slowest endpoints*, the database CPU graph, `DatabaseConnections` |
| `app-errors` | The app logged at least one ERROR line within 5 minutes | Saved query *Recent errors*, then *One request* with its `requestId` ("Following one request") |
| `db-storage-low` | Less than 2 GiB of the database's 20 GiB left | `FreeStorageSpace` trend. Raise `allocated_storage` in `database.tf`, or turn on storage autoscaling |
| `db-cpu-credits-low` | The database's CPU credit balance is below 30 | The database CPU graph. At 0, AWS bills surplus CPU (unlimited mode). Look for expensive queries |
| `backend-cpu-credits-low` | The instance's CPU credit balance is below 30 | The instance CPU graph. At 0, surplus CPU is billed if the instance runs in unlimited mode |

Alarms treat "no data" as fine, so a quiet night with no traffic doesn't alert. The exceptions
are `environment-unhealthy` and `db-storage-low`: those two metrics always have data, so a gap
means something stopped reporting.

## Logs

| Log group | Contents |
|---|---|
| `/aws/elasticbeanstalk/supple-ai-prod-backend/var/log/web.stdout.log` | The app: one JSON line per log statement, plus one per API request |
| `/aws/elasticbeanstalk/supple-ai-prod-backend/var/log/nginx/access.log` | Every request nginx passed on, with status, but no response time |
| `/aws/elasticbeanstalk/supple-ai-prod-backend/var/log/nginx/error.log` | nginx errors, e.g. "connect() failed" while the app is down |
| `/aws/elasticbeanstalk/supple-ai-prod-backend/var/log/eb-engine.log` | Beanstalk deploys and platform updates on the instance |
| `/aws/elasticbeanstalk/supple-ai-prod-backend/var/log/eb-hooks.log` | Beanstalk's deployment hooks on the instance |

Logs are kept for 30 days. Each group has one log stream per instance, named after its EC2
instance id, so a platform update starts a new stream.

### Where to click

In June 2026 AWS reorganised CloudWatch's **Logs** menu. Logs Insights, Live Tail and Contributor
Insights became one page, **Log Analytics**, and the log groups moved to **Log Management**. There
is no "Logs Insights" menu item any more (unless the account opted out of Log Analytics), and
many AWS help pages still use the old names.

**Query the logs** (most of the time):

1. Open CloudWatch in **eu-north-1** (Europe (Stockholm)) → **Logs** → **Log Analytics**.
2. Open **Saved and sample queries** (the panel on the right) → folder `supple-ai-prod` → pick a
   query (next section). It opens with its log group already selected. For a query of your own,
   keep the language on **Logs Insights QL** and select the log group by name: type
   `web.stdout.log` or `supple-ai-prod-backend` to find it.
3. **Widen the time range.** The default is the last hour, and the app is often idle for hours,
   so an empty result usually means a quiet hour, not a broken query. Choose 1 day, 1 week, or an
   absolute range around the problem.
4. **Run query.** The arrow at the left of a result shows all of its fields, the stack trace
   (`error.stack_trace`) included. **Surrounding logs** on a result shows what was logged just
   before and after it.

**Browse a group's lines without a query:** **Logs** → **Log Management** → **Log Groups** → the
group → a log stream, or **Search log group** to search every stream. This view shows the original
lines, syslog prefix included, and doesn't use the fields.

**Shortcut from Beanstalk:** Elastic Beanstalk → `supple-ai-prod-backend` → **Logs** tab → the
CloudWatch Logs section lists each group, with links to it, to the query page and to Live Tail.

**Watch lines arrive:** start **Live Tail** from Log Analytics or from a log group, select
`web.stdout.log` and, optionally, a filter pattern such as a request id. It's free for 1,800
minutes a month, then $0.01 a minute, so close it when you're done.

### The app's log lines

On Beanstalk the backend logs JSON (`LOGGING_STRUCTURED_FORMAT_CONSOLE=ecs`). Beanstalk's
rsyslog adds a syslog prefix, so a line looks like this:

```
Nov 14 10:45:55 ip-10-0-1-65 web[629314]: {"@timestamp":"2026-11-14T10:45:55.835Z","log":{"level":"INFO","logger":"com.healthytech.supple.config.logging.RequestLoggingFilter"},"process":{"pid":629314,"thread":{"name":"http-nio-5000-exec-9"}},"service":{"name":"supple","version":"0.0.1-SNAPSHOT","node":{}},"message":"GET /api/internal/v1/dictionaries/tags 200 81ms","path":"/api/internal/v1/dictionaries/tags","route":"/api/internal/v1/dictionaries/tags","method":"GET","requestId":"68625b90-79a5-4815-a760-f04de86946e7","durationMs":"81","userSub":"0b7c…","status":"200","ecs":{"version":"8.11"}}
```

- Every line written while handling a request carries `requestId`, `method`, `path` and, for a
  signed-in user, `userSub` (the Cognito `sub`, the id on the Users screen). Swagger UI and
  API-docs requests carry none of them.
- When a request finishes, `RequestLoggingFilter` writes one line with `status`, `durationMs` and
  `route` (the endpoint pattern, e.g. `…/tags/{id}`). That's the app's access log. It's the only
  line with `durationMs`, which is how the saved queries find it.
- An exception's line has `error.type`, `error.message` and `error.stack_trace`. The stack trace
  starts with the root cause and stops at 4,096 characters, because rsyslog cuts every line at
  8 KB. Before that cap, every logged exception lost its root cause and wasn't valid JSON.
- A log transformer (`monitoring.tf`) strips the prefix and parses the JSON. In Log Analytics
  every key is therefore a field (`requestId`, `path`, `status`, `log.level`, `error.type`, …)
  that `fields`, `filter` and `stats` use directly, without `parse`. It only applies to lines
  logged after it was applied, so for the first 30 days older lines have no fields. Find those
  with `filter @message like "…"`, which searches the raw line. The transformer is part of the
  ingestion price: CloudWatch stores both the original and the parsed line, a few hundred KB here.
- Locally the app logs plain text, with `[<requestId>]` after the thread name.

### Following one request

Every response carries an `X-Request-Id` header, and every error body carries the same value as
`requestId`. The back office shows it on server-error toasts ("Request ID: …"), and the mobile app
is asked to put it in bug reports.

1. Copy the id from the toast, from the response headers (browser devtools → Network → the
   request), or from the `requestId` column of *Recent errors*.
2. Run the saved query *One request* with `REPLACE-WITH-REQUEST-ID` replaced by the id, over a
   wide enough time range. It lists every line the request wrote, in order: an error with its
   stack trace, then the access-log line with status and duration.

You don't have to add `requestId` to a query to see it: it's a field, so expand a row or add it to
`fields`. On lines older than the transformer, `filter @message like "<id>"` finds the id anywhere
in the line.

A client may send its own `X-Request-Id` (the mobile app may, the back office doesn't), so an id
isn't guaranteed to be unique. *One request* can therefore return more than one request, for
example a retry that reused the id. A 401 for an invalid token never reaches the app's request
logging and has no id; *Requests that never reached the app* shows those.

### SQL budget warnings

The backend logs one WARN when a request exceeds `supple.sql-budget.read` (default 30
statements for GET/HEAD/OPTIONS) or `supple.sql-budget.write` (default 100 for other methods).
The message contains `ran … SQL statements, over the budget of …` and the request id. Requests
still complete normally; these warnings do not trigger the ERROR alarm.

In the backend's `web.stdout.log` group, search for `filter @message like "over the budget"`,
then use the request id with *One request*. Compare query growth and response size before
changing a threshold: several batched queries are expected, while one query per returned row
signals a regression. Large writes can legitimately insert one row per item; raise a budget
only after confirming the workload is expected.

The count covers Hibernate statements during the request. Direct JDBC work (the audit log, the dashboard)
and background jobs are excluded, so it is not a total database-work or latency measurement.

### Saved queries

`monitoring.tf` defines them, and Log Analytics lists them under **Saved and sample queries** →
`supple-ai-prod`. Change them in `monitoring.tf`: the next `terraform apply` undoes an edit saved
in the console. To keep a variation, save it under a new name.

| Query | What it shows |
|---|---|
| *Recent errors* | The latest 50 ERROR lines, with path, message, exception type and request id |
| *One request* | Every line one request wrote. Replace the placeholder with its id |
| *Slowest endpoints* | Requests, average, p95 and maximum duration per endpoint. The endpoint is `route`, or the raw `path` when no controller matched (a 403 before routing) |
| *5xx responses by endpoint* | 5xx responses per endpoint and status. Change `/^5/` to `/^4/` for 4xx |
| *One user's requests* | One user's requests, newest first. Replace the placeholder with their Cognito `sub` (Users screen) |
| *Traffic per hour by status* | Requests per hour by status class (2, 3, 4, 5) |
| *Requests that never reached the app* | From nginx's `access.log`: 5xx responses (502s while the app restarts) and 401s for invalid tokens, which the app doesn't log |

## Changing who gets alerts

All recipients come from one variable, `alert_emails` in `terraform.tfvars`. It feeds the SNS
topic, which carries the alarms and the Beanstalk events, and the budget.

1. Download the current file. It lives in the state bucket (README, "Setup", path B):

   ```bash
   aws s3 cp "s3://$(awk -F'"' '/bucket/ {print $2}' backend.hcl)/terraform.tfvars" terraform.tfvars
   ```

2. Edit the list. Use 1 to 10 distinct addresses, the AWS Budgets limit:

   ```hcl
   alert_emails = ["you@example.com", "teammate@example.com"]
   ```

3. Apply. The plan should show only `aws_sns_topic_subscription` resources being added or
   removed, the budget being updated in place, and the expected Beanstalk line (README, "Setup",
   B step 6):

   ```bash
   terraform plan
   terraform apply
   ```

4. **Every new address confirms once.** It receives an "AWS Notification - Subscription
   Confirmation" email and must click the link. Until then it gets no alarm or Beanstalk email.
   Budget emails need no confirmation. SNS → Subscriptions shows which are still "Pending
   confirmation". SNS deletes a subscription that stays
   unconfirmed for a few days; the next `terraform apply` then recreates it and sends a new
   confirmation email.
5. Upload the file again so the next person gets the same list:

   ```bash
   aws s3 cp terraform.tfvars "s3://$(awk -F'"' '/bucket/ {print $2}' backend.hcl)/terraform.tfvars"
   ```

To **change** an address, replace it in the list: Terraform removes the old subscriptions and
creates new ones. To **remove** one, delete it from the list and apply.

If someone clicks "unsubscribe" in an alert email, only that subscription goes away. The next
`terraform apply` recreates it and sends a new confirmation email. To stop the alerts for good,
remove the address from `alert_emails`.

## After the first apply with monitoring

1. Every address confirms its subscription (above).
2. Deploy the backend (`scripts/deploy-backend.sh`). The metric export and the JSON logs need
   the new version, and Beanstalk restarts the app with the new environment variables.
3. After about 15 minutes, open the dashboard. Every graph should have data. `App ERROR lines`
   stays empty until the first error, and `DB pool pending` shows zeros.
4. **If the app's log format changes,** re-test the error filter: CloudWatch → Logs → Log Management → Log
   Groups → `web.stdout.log` → Metric filters → `supple-ai-prod-app-errors` → Edit → **Test pattern**
   against recent events. The pattern `%level...ERROR%` matches `"level":"ERROR"`; metric-filter
   regexes don't accept the `"` character, so each `.` stands for one of `":"`.

## After the first apply with the log transformer

1. `terraform plan` shows `aws_cloudwatch_log_transformer.backend` and seven
   `aws_cloudwatch_query_definition` resources to add, plus the expected Beanstalk line (README,
   "Setup", B step 6). Apply.
2. Deploy the backend (`scripts/deploy-backend.sh`) if it's older than the request-id change: the
   `X-Request-Id` header, `requestId` in error bodies and the stack-trace cap need it.
3. Call any API endpoint, copy the response's `X-Request-Id` (browser devtools → Network), and
   run *One request* with it over the last hour. It should list the access-log line with
   `requestId` as a field. If it lists nothing but `filter @message like "<id>"` finds the line,
   check for `@transformationError` on it: the line didn't match the transformer's grok pattern.

## Adding a metric or alarm

The free tier allows 10 alarm metrics and 10 custom metrics. The alarms already use all 10
alarm metrics; custom metrics are at 6. Beyond the free tier, an alarm costs $0.10 a month per
metric it reads, a custom metric $0.30 a month, and a dashboard beyond the third $3 a month.

- **A new alarm** replaces an existing one, or accepts the $0.10 a month.
- **A new app metric:** add its name to `CloudWatchMetricsConfig.EXPORTED` in the backend. Each
  name becomes one metric because tags are dropped. Every exported name is a billed custom
  metric, so never allowlist a meter with a per-endpoint or per-status tag.
- **Graphs** on the existing dashboard are free.
