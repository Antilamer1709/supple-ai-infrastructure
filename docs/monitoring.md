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

## Where to look

| What | Where |
|---|---|
| Dashboard | `terraform output -raw monitoring_dashboard_url`, or CloudWatch → Dashboards → `supple-ai-prod-overview`. Shows the alarm states and graphs of everything below |
| Alarms | CloudWatch → Alarms → All alarms (all nine are in eu-north-1) |
| App metrics | CloudWatch → Metrics → All metrics → Custom namespaces → `SuppleAI/Backend` |
| Beanstalk metrics | All metrics → `ElasticBeanstalk` → Environment metrics |
| Instance metrics | All metrics → `EC2` → By Auto Scaling Group (the instance is replaced on platform updates; the group isn't) |
| Database metrics | All metrics → `RDS` → Per-Database Metrics → `supple-ai-prod-db` |
| CloudFront metrics | The dashboard's last graph, or switch to us-east-1 → All metrics → `CloudFront` → Per-Distribution Metrics |
| Logs | CloudWatch → Logs → Log groups, or Logs Insights for queries (below) |
| Health and events | Elastic Beanstalk → `supple-ai-prod-backend` → Health, Events |
| Every JVM meter | `/actuator/metrics` isn't reachable through CloudFront. Open a Session Manager shell on the instance (README, "Operations") and run `curl -s localhost:5000/actuator/metrics` |

### Metrics

| Metric | Namespace | Source | Meaning |
|---|---|---|---|
| `EnvironmentHealth` | `AWS/ElasticBeanstalk` | Beanstalk, free | 0 OK, 15 Warning, 20 Degraded, 25 Severe |
| `ApplicationRequests5xx` | `AWS/ElasticBeanstalk` | Beanstalk enhanced health, from nginx's log | API responses with a 5xx status |
| `ApplicationLatencyP95` | `AWS/ElasticBeanstalk` | Beanstalk enhanced health, from nginx's log | 95th-percentile API response time, in seconds |
| `supple.jvm.heap.used.value` | `SuppleAI/Backend` | Backend (Micrometer), every minute | Heap in use, in bytes |
| `supple.jvm.heap.max.value` | `SuppleAI/Backend` | Backend (Micrometer) | Maximum heap: 40% of the instance's memory |
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
| `api-5xx` | 5 or more API requests got a 5xx within 5 minutes | Logs Insights "Recent errors" and "5xx responses by endpoint". A 502 with no app error means the app was down or restarting: check `nginx/error.log` |
| `api-slow` | The API's p95 response time stayed above 2 seconds for 15 minutes | Logs Insights "Slowest endpoints", then the database CPU graph and `db-pool-starved`. One slow endpoint means a query or code problem; everything slow means the instance or the database is overloaded |
| `heap-pressure` | Heap above 90% of its maximum for 15 minutes | The dashboard's heap graph. Steady growth points to a leak; a plateau near the max means the instance is too small. Restart from the Beanstalk console as a stopgap |
| `db-pool-starved` | Requests waited for a database connection for 5 minutes | Slow queries: "Slowest endpoints", the database CPU graph, `DatabaseConnections` |
| `app-errors` | The app logged at least one ERROR line within 5 minutes | Logs Insights "Recent errors", then "One request" with its `requestId` |
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

Logs are kept for 30 days.

### The app's log lines

On Beanstalk the backend logs JSON (`LOGGING_STRUCTURED_FORMAT_CONSOLE=ecs`). Beanstalk's
rsyslog adds a syslog prefix, so a line looks like this:

```
Nov  1 10:00:00 ip-10-0-1-5 web[2345]: {"@timestamp":"2026-11-01T10:00:00.123Z","log":{"level":"INFO","logger":"…RequestLoggingFilter"},"message":"GET /api/internal/v1/dictionaries/tags 200 12ms","requestId":"68625b90-…","method":"GET","path":"/api/internal/v1/dictionaries/tags","route":"/api/internal/v1/dictionaries/tags","userSub":"0b7c…","status":"200","durationMs":"12",…}
```

- Every line written while handling a request carries `requestId`, `method`, `path` and, for a
  signed-in user, `userSub` (the Cognito `sub`, the id on the Users screen).
- When a request finishes, `RequestLoggingFilter` writes one line with `status`, `durationMs` and
  `route` (the endpoint pattern, e.g. `…/tags/{id}`). That's the app's access log.
- An exception's stack trace is inside its line, in `error.stack_trace`. Click the row in Logs
  Insights to see the whole line.

Because of the prefix, Logs Insights doesn't discover the JSON fields by itself. Every query
below pulls the fields it needs out with `parse` and a regex. Locally the app logs plain text.

### Logs Insights queries

CloudWatch → Logs Insights, select the `web.stdout.log` group, choose a time range, and paste a
query. Save the ones you use with **Save**.

**Recent errors**

```
fields @timestamp
| filter @message like /"level":"ERROR"/
| parse @message /"message":"(?<msg>[^"]*)"/
| parse @message /"path":"(?<path>[^"]*)"/
| parse @message /"requestId":"(?<requestId>[^"]*)"/
| display @timestamp, path, msg, requestId
| sort @timestamp desc
| limit 50
```

**One request**: every line one request wrote, in order. Replace the id.

```
fields @timestamp, @message
| filter @message like "68625b90-79a5-4815-a760-f04de86946e7"
| sort @timestamp asc
```

**Slowest endpoints**

```
filter @message like /RequestLoggingFilter/
| parse @message /"method":"(?<method>[A-Z]+)"/
| parse @message /"route":"(?<route>[^"]*)"/
| parse @message /"path":"(?<path>[^"]*)"/
| parse @message /"durationMs":"(?<ms>\d+)"/
| fields coalesce(route, path) as endpoint
| stats count() as requests, avg(ms) as avg_ms, pct(ms, 95) as p95_ms, max(ms) as max_ms by method, endpoint
| sort p95_ms desc
| limit 20
```

`route` is missing when no controller matched (a 401 or 403 before routing), so the query falls
back to the raw `path`.

**5xx responses by endpoint** (use `/^4/` for 4xx)

```
filter @message like /RequestLoggingFilter/
| parse @message /"method":"(?<method>[A-Z]+)"/
| parse @message /"route":"(?<route>[^"]*)"/
| parse @message /"path":"(?<path>[^"]*)"/
| parse @message /"status":"(?<status>\d+)"/
| filter status like /^5/
| fields coalesce(route, path) as endpoint
| stats count() as responses by method, endpoint, status
| sort responses desc
```

**One user's requests**: replace the `sub`.

```
filter @message like /RequestLoggingFilter/ and @message like /"userSub":"0b7c1a2e-…"/
| parse @message /"method":"(?<method>[A-Z]+)"/
| parse @message /"path":"(?<path>[^"]*)"/
| parse @message /"status":"(?<status>\d+)"/
| parse @message /"durationMs":"(?<ms>\d+)"/
| display @timestamp, method, path, status, ms
| sort @timestamp desc
```

**Traffic per hour by status**

```
filter @message like /RequestLoggingFilter/
| parse @message /"status":"(?<status>\d)\d\d"/
| stats count() by bin(1h), status
```

**Requests that never reached the app** (select the `nginx/access.log` group). Includes 502s
while the app restarts and 401s for invalid tokens, which the app doesn't log.

```
fields @timestamp, @message
| parse @message /"(?<method>[A-Z]+) (?<path>\S+) HTTP\/[\d.]+" (?<status>\d{3})/
| filter status like /^5/ or status = "401"
| sort @timestamp desc
| limit 50
```

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
4. **If the app's log format changes,** re-test the error filter: CloudWatch → Log groups →
   `web.stdout.log` → Metric filters → `supple-ai-prod-app-errors` → Edit → **Test pattern**
   against recent events. The pattern `%level...ERROR%` matches `"level":"ERROR"`; metric-filter
   regexes don't accept the `"` character, so each `.` stands for one of `":"`.

## Adding a metric or alarm

The free tier allows 10 alarm metrics and 10 custom metrics. The alarms already use all 10
alarm metrics; custom metrics are at 6. Beyond the free tier, an alarm costs $0.10 a month per
metric it reads, a custom metric $0.30 a month, and a dashboard beyond the third $3 a month.

- **A new alarm** replaces an existing one, or accepts the $0.10 a month.
- **A new app metric:** add its name to `CloudWatchMetricsConfig.EXPORTED` in the backend. Each
  name becomes one metric because tags are dropped. Every exported name is a billed custom
  metric, so never allowlist a meter with a per-endpoint or per-status tag.
- **Graphs** on the existing dashboard are free.
