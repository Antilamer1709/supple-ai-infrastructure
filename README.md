# Terraform infrastructure for Supple AI

AWS infrastructure for the **Supple BO** back-office: the Spring Boot backend (`../supple-ai-backend`)
and the Angular frontend (`../supple-ai-frontend`). One environment, `prod`, in `eu-north-1`,
sized for a few users and the lowest cost.

Terraform manages the infrastructure only. The two apps are deployed with the scripts in
`scripts/`, which read everything they need from `terraform output`.

```
Browser ── HTTPS ──> CloudFront (https://dxxxx.cloudfront.net)
                        │  /*      → S3 bucket (private, Origin Access Control): the Angular build
                        │  /api/*  → Elastic Beanstalk, HTTP :80 (only CloudFront may connect)
                        ▼
              Beanstalk single instance, t4g.micro, public subnet, Elastic IP
              (Corretto 25, nginx → Spring Boot on :5000)
                        │ 5432 (only from the instance)
                        ▼
              RDS PostgreSQL 16, db.t4g.micro, private subnet

Cognito user pool + Managed Login (sign-in/sign-up pages, optional Google) issues the JWTs
the app sends to /api.
```

Because the app and the API share one address, the browser never makes a cross-origin call:
the frontend uses relative `/api` URLs and the backend has no CORS setup.

## What gets created

| File | Resources |
|---|---|
| `network.tf` | VPC (2 AZs, public + private subnets, no NAT gateway); security groups: instance accepts port 80 only from CloudFront's managed prefix list, database accepts 5432 only from the instance |
| `database.tf` | RDS PostgreSQL 16 (`db.t4g.micro`, 20 GiB gp3, encrypted, private, deletion protection, final snapshot); master password managed by RDS in Secrets Manager, with automatic rotation turned off |
| `cognito.tf` | User pool (email sign-in, self sign-up, deletion protection), `admin` group, optional Google provider, the back-office app client (code flow + PKCE), the mobile app client (code flow + PKCE and native sign-in, `formulated://` redirects), Managed Login domain and default branding for both clients |
| `backend.tf` | Beanstalk application + single-instance environment (Corretto 25, enhanced health, managed platform updates, CloudWatch logs, notifications through the alerts topic), IAM roles (the instance role may read the database secret, the app versions and, for the admin Users screen, the user pool's users, and may publish its own metrics), artifacts bucket for app versions |
| `frontend.tf` | Private S3 bucket, CloudFront distribution with OAC, `/api/*` routed to Beanstalk, 404 → `index.html` for Angular routes |
| `budget.tf` | Monthly AWS Budget (default $30, measured before credits) with email alerts |
| `monitoring.tf` | SNS alert topic with every `alert_emails` address subscribed, the app's error-count metric, 9 CloudWatch alarms, the `supple-ai-prod-overview` dashboard ([docs/monitoring.md](docs/monitoring.md)) |
| `versions.tf` | Terraform/provider versions, S3 state backend with native locking, default tags |
| `variables.tf`, `outputs.tf` | Inputs (and naming locals) and the values the scripts read |

Every resource is named `supple-ai-prod-…` and tagged `Project=supple-ai`, `Environment=prod`,
`ManagedBy=terraform`, `Repository=supple-ai-infrastructure`. To see costs per project, activate
the `Project` tag once in Billing → Cost allocation tags.

## Cost

About **$25 a month**, paid from credits on the Free plan:

| Item | Monthly |
|---|---|
| RDS db.t4g.micro + 20 GiB gp3 | ≈ $14.10 |
| EC2 t4g.micro + 8 GiB root disk | ≈ $7.00 |
| Public IPv4 (the Elastic IP) | ≈ $3.65 |
| Secrets Manager (database password) | $0.40 |
| CloudFront, Cognito (< 10,000 users), S3, SNS, Budgets | ≈ $0 (always-free allowances) |
| CloudWatch: logs, 6 custom metrics, 9 alarms (10 alarm metrics), 1 dashboard | $0 (always-free tier, also on the Paid plan; [docs/monitoring.md](docs/monitoring.md)) |

## Prerequisites

- Terraform ≥ 1.11 (`brew install hashicorp/tap/terraform`) and the AWS CLI v2.
- For the deploy scripts: Java 25 and Docker (the backend build runs the Testcontainers suite),
  Node.js + npm (frontend build), git.
- AWS credentials through the `healthytech` profile. It signs in with your console session:

  ```bash
  aws login --profile healthytech      # opens the browser; credentials last up to 12 hours
  export AWS_PROFILE=healthytech       # Terraform and the scripts use this profile
  ```

  If a command later fails with expired credentials, run `aws login --profile healthytech` again.

## Setup

Pick the path that matches your situation:

- **[A. New AWS account](#a-new-aws-account):** nothing is deployed yet. You create the state
  bucket, the configuration and every resource.
- **[B. Existing deployment](#b-existing-deployment):** the app already runs and you just cloned
  this repo. You fetch the configuration and get a working `terraform plan`. You create nothing.

### Files you won't find in git

Three files that Terraform and the scripts need are gitignored, because they hold the account ID,
secrets, or both:

| File | What it holds | Where it comes from |
|---|---|---|
| `backend.hcl` | The state bucket's name and region, for `terraform init` | Written by `scripts/bootstrap-state.sh` (A step 3, B step 3). Re-running it is safe |
| `terraform.tfvars` | Your settings: `alert_emails`, the Google client ID and secret, any overrides | **New account:** copy `terraform.tfvars.example` and fill it in (A step 4). **Existing deployment:** download it from the state bucket (B step 4). It's stored there next to the state: private, encrypted and versioned |
| `.terraform/`, `.terraform.lock.hcl` | Downloaded providers and modules | `terraform init` creates `.terraform/`. The lock file *is* committed |

The state itself stays in the S3 bucket and never comes to your machine.

**Keep the stored `terraform.tfvars` current.** After every change to your local copy, upload it
again (A step 8). Otherwise the next person applies with old values and undoes your change:
Google sign-in disappears without the Google values, and alerts go to the old addresses. The
bucket keeps every earlier version for 90 days.

### A. New AWS account

1. **Install the tools and sign in** (see [Prerequisites](#prerequisites)):

   ```bash
   aws login --profile healthytech
   export AWS_PROFILE=healthytech
   ```

2. **Check the account.** It's on the AWS Free plan: nothing is charged, usage comes out of the
   credits, and the account closes after 6 months or when the credits run out, whichever comes
   first. See the end date and remaining credits:

   ```bash
   aws freetier get-account-plan-state --region us-east-1
   ```

   Optional: Console Home → "Explore AWS" lists five starter activities worth up to $100 of extra
   credits. Do them before the first apply and delete whatever they create afterwards.

3. **Create the state bucket.** This writes `backend.hcl`:

   ```bash
   scripts/bootstrap-state.sh
   ```

4. **Create `terraform.tfvars`:**

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

   Set `alert_emails` to the addresses that should get alerts. Leave the Google values commented
   out for now ([Google sign-in](#google-sign-in) adds them later).

5. **Initialize Terraform:**

   ```bash
   terraform init -backend-config=backend.hcl
   ```

6. **Create the infrastructure.** This takes 15–20 minutes; CloudFront and RDS are the slowest:

   ```bash
   terraform plan
   terraform apply
   ```

   If it fails, see [Troubleshooting the first apply](#troubleshooting-the-first-apply).

7. **Confirm the alert emails.** Every address in `alert_emails` receives an "AWS Notification -
   Subscription Confirmation" email. Click the link, or that address gets no alarm or Beanstalk
   emails.

8. **Store `terraform.tfvars` for the next person:**

   ```bash
   aws s3 cp terraform.tfvars "s3://$(awk -F'"' '/bucket/ {print $2}' backend.hcl)/terraform.tfvars"
   ```

   Repeat this after every later change to the file.

9. **Put the new Cognito IDs into the apps.** Both still contain `6plp3eqqvjlf3u7mav5q7b5mh6%`
   placeholders:

   ```bash
   terraform output -raw cognito_issuer_uri   # → frontend oidcIssuerUri, backend issuer-uri default
   terraform output -raw cognito_client_id    # → frontend clientId
   terraform output -raw cognito_domain       # → frontend cognitoDomain (only if you changed the prefix)
   ```

   - `../supple-ai-frontend/src/environments/environment.ts`: `oidcIssuerUri` and the `clientId`
     constant.
   - `../supple-ai-backend/src/main/resources/application.yaml`: the default in
     `issuer-uri: ${COGNITO_ISSUER_URI:…}` (used for local runs; in production Beanstalk sets
     `COGNITO_ISSUER_URI` itself).
   - `../supple-ai-backend/docs/mobile-client.md`: `terraform output -raw cognito_mobile_client_id`
     (see [Mobile app](#mobile-app)).

   Commit these. They change only if the user pool is ever recreated.

10. **Deploy the backend, then the frontend:**

    ```bash
    scripts/deploy-backend.sh     # replaces Beanstalk's sample app with the Spring Boot JAR
    scripts/deploy-frontend.sh
    ```

11. **Make yourself an admin.** Open `terraform output -raw cloudfront_url`, choose **Sign up**,
    and confirm the emailed code. You'll see "Access Denied" because you're not an admin yet. In
    the AWS console go to Amazon Cognito → User pools → `supple-ai-prod` → Groups → `admin` →
    **Add user to group**. Then log out of the app and back in.

12. **Check the monitoring.** Wait about 15 minutes after the backend deploy, then follow
    [docs/monitoring.md, "After the first apply with monitoring"](docs/monitoring.md#after-the-first-apply-with-monitoring).

13. **Optional: Google sign-in.** Follow [Google sign-in](#google-sign-in), then upload
    `terraform.tfvars` again (step 8).

### B. Existing deployment

You need access to the `healthytech` AWS account; ask its owner for a console sign-in. The
deploy scripts expect the other two repos next to this one:

```
<any folder>/
├── supple-ai-backend/
├── supple-ai-frontend/
└── supple-ai-infrastructure/   ← this repo
```

1. **Install the tools and sign in** (see [Prerequisites](#prerequisites)):

   ```bash
   aws login --profile healthytech
   export AWS_PROFILE=healthytech
   ```

2. **Clone the three repos** side by side, as above.

3. **Get `backend.hcl`.** The script finds the existing state bucket, rewrites `backend.hcl`,
   and prints the next commands:

   ```bash
   scripts/bootstrap-state.sh
   ```

4. **Download `terraform.tfvars`** from the state bucket:

   ```bash
   aws s3 cp "s3://$(awk -F'"' '/bucket/ {print $2}' backend.hcl)/terraform.tfvars" terraform.tfvars
   ```

   If the bucket has no `terraform.tfvars`, the person who set up the account skipped A step 8.
   Get the file from them; don't build one from the example, because the values must match
   what's deployed.

5. **Initialize Terraform:**

   ```bash
   terraform init -backend-config=backend.hcl
   ```

6. **Check that your setup matches production:**

   ```bash
   terraform plan
   ```

   It must show **no changes**, except one harmless line Terraform plans on every run: the
   Beanstalk environment `~ update in-place` adding the `ServiceRoleForManagedUpdates` setting.
   Beanstalk never reports that setting back, so Terraform always thinks it's missing. If the
   plan shows anything else, **don't apply.** Either your `terraform.tfvars` is older than what was last applied,
   or this branch differs from what's deployed. Find out who applied last and why before you
   continue.

7. **Optional: add yourself to the alerts.** See
   [docs/monitoring.md, "Changing who gets alerts"](docs/monitoring.md#changing-who-gets-alerts).

8. **Deploy** when you have app changes; see [Deploying](#deploying).

9. **For admin access in the app,** sign up and ask an existing admin to add you to the `admin`
   group (A step 11).

## Deploying

```bash
export AWS_PROFILE=healthytech

scripts/deploy-backend.sh               # build (with tests), upload, deploy, wait
SKIP_TESTS=1 scripts/deploy-backend.sh  # same, without the test suite
scripts/deploy-frontend.sh              # build, upload, invalidate CloudFront
```

- **Backend.** Runs `./mvnw -B clean package` and uploads the JAR to the artifacts bucket. It
  then creates a Beanstalk application version labelled `<UTC timestamp>-<git sha>` (`-dirty`
  for uncommitted changes) and deploys it. It waits until the environment is ready and fails if
  Beanstalk rolled back. Deploys replace the app in place, so the API is down for about a minute.
  Beanstalk keeps the last 10 versions; roll back by deploying an older one in the console.
- **Frontend.** Runs `npm ci && npm run build` and refuses to deploy a build whose Cognito IDs
  don't match `terraform output`. It uploads the hashed JS/CSS first (cached for a year), then
  `index.html` with `Cache-Control: no-cache`, then removes files the new build no longer has. It
  finishes by invalidating CloudFront.
- `BACKEND_DIR` / `FRONTEND_DIR` override the app locations (default: the neighbouring repos).
- **Infrastructure changes:** `terraform plan` and `terraform apply`. Terraform ignores the
  deployed app version and the platform version, which change outside Terraform.

## Swagger

Swagger UI is public, at `<cloudfront_url>/api/swagger-ui.html`. Its server URL is relative, so
"Try it out" calls the same CloudFront address. To call protected endpoints, click **Authorize**
and paste an access token. To get one, sign in to the app, open the browser's developer tools
→ Application → Session storage → the app's address, and copy `authnResult.access_token`.
Admin endpoints need a user in the `admin` group.

## Google sign-in

1. In the [Google Cloud console](https://console.cloud.google.com/), create a project.
2. Under **Google Auth Platform**:
   1. Configure the consent screen: External, app name, support email.
   2. Add the scopes `openid`, `email`, `profile`.
   3. Publish the app. In "Testing" mode only listed test users can sign in.
3. Under **Clients**, create an OAuth client of type **Web application**:
   - Authorized JavaScript origin: `https://supple-ai-prod.auth.eu-north-1.amazoncognito.com`
   - Authorized redirect URI: `https://supple-ai-prod.auth.eu-north-1.amazoncognito.com/oauth2/idpresponse`

   (Both use `terraform output -raw cognito_domain`.)
4. Put the client ID and secret into `terraform.tfvars` (`google_client_id`,
   `google_client_secret`) and run `terraform apply`. The login page then shows "Continue with
   Google".

Google users see their Google photo as the avatar. Cognito copies it into the user's standard
`picture` attribute on every Google sign-in, not on token refresh, so a user who signed in before
the mapping existed, or who changes the photo, sees the new one after their next Google sign-in
(log out and back in). Users who signed up with a password have no `picture` and see the default
avatar. A future social provider must map its avatar to `picture` too; if it has none, leave it
unmapped. The app needs no change either way.

The secret is also stored in the Terraform state, which sits in the encrypted, private state
bucket. A person who signs up with a password and later uses Google with the same email ends up
as two separate Cognito users, so add the account you actually use to `admin`.

## Mobile app

The mobile app's Cognito client exists ahead of the app, so its developer never needs AWS access.
It's a public client allowing both Managed Login in the system browser (code + PKCE, Google
included) and native sign-in screens (`USER_AUTH` / SRP), with redirects
`formulated://callback` and `formulated://signout` (the `mobile_url_scheme` local in
`variables.tf`), 60-minute access/ID tokens and a 90-day refresh token. The developer's guide is
`../supple-ai-backend/docs/mobile-client.md`; after the apply that creates the client, put
`terraform output -raw cognito_mobile_client_id` in place of its `6plp3eqqvjlf3u7mav5q7b5mh6%`.

Beanstalk receives the same id as `COGNITO_MOBILE_CLIENT_ID`: the backend counts that client's
tokens (and anonymous requests carrying `X-Installation-Id`) as app activity and every other token
as back office, for the users screen's "last seen" and the dashboard statistics. It's the mobile
client's id that's passed because the back-office client depends on CloudFront, which depends on
the Beanstalk environment. Changing the env var restarts the app (about a minute).

## Monitoring

CloudWatch watches the backend, the database and CloudFront for $0, inside the always-free tier.
Every address in `alert_emails` gets an email when one of 9 alarms fires and again when it
clears:

- the environment is unhealthy
- API 5xx responses
- heap pressure
- a starved database connection pool
- app ERROR lines
- low database storage
- low CPU credits on the database or the instance
- slow API responses

Beanstalk events and the budget alerts go to the same addresses. The
`supple-ai-prod-overview` dashboard (`terraform output -raw monitoring_dashboard_url`) shows all
of it in one place. On Beanstalk the app logs JSON lines carrying the request id and the user's
Cognito `sub`, plus one line per API request with its status and duration.

[docs/monitoring.md](docs/monitoring.md) has where to find each metric, alarm and log, what to
check when an alarm fires, ready-to-paste Logs Insights queries, and how to change or add
recipients.

## Operations

- **Monitoring and logs.** [docs/monitoring.md](docs/monitoring.md) covers the dashboard,
  the alarms, the log groups (kept for 30 days) with ready-to-paste Logs Insights queries, and
  how to change who gets alerts.
- **Shell on the instance.** There's no SSH. Use EC2 console → the instance → **Connect** →
  Session Manager.
- **Health.** Beanstalk emails every address in `alert_emails` when health changes or a
  deployment fails, and the `environment-unhealthy` alarm fires after 5 minutes of Degraded or
  Severe. Without a load balancer it doesn't call `/actuator/health`; it judges health from the
  instance and nginx logs.
- **Platform updates.** Minor and patch updates run automatically on Sunday nights (UTC). During
  one, Beanstalk briefly runs a second instance.
- **Database access.** The database isn't reachable from the internet. Open a tunnel through the
  instance with Session Manager:

  ```bash
  INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:elasticbeanstalk:environment-name,Values=supple-ai-prod-backend" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)
  DB_HOST=$(aws rds describe-db-instances --db-instance-identifier supple-ai-prod-db --query 'DBInstances[0].Endpoint.Address' --output text)
  aws ssm start-session --target "$INSTANCE_ID" --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "host=$DB_HOST,portNumber=5432,localPortNumber=15432"
  # in another terminal: user "supple", database "supple", password from
  aws secretsmanager get-secret-value --secret-id "$(terraform output -raw database_secret_arn)" --query SecretString --output text
  ```

  The tunnel needs the Session Manager plugin for the AWS CLI. A dump for safekeeping:
  `pg_dump -h localhost -p 15432 -U supple -d supple -Fc -f supple.dump`.
- **Changing the database password.** Automatic rotation is off, because the app only reads the
  password when it starts. To change it:

  ```bash
  aws rds modify-db-instance --db-instance-identifier supple-ai-prod-db --rotate-master-user-password --apply-immediately
  # wait a minute, then let the app pick up the new password
  aws elasticbeanstalk restart-app-server --environment-name supple-ai-prod-backend
  ```

  If `terraform plan` afterwards shows rotation as enabled again, run `terraform apply` to turn
  it off.

## Before going live

The current setup is sized for a few users while building and testing. Before real users depend
on it:

1. **Add a load balancer with auto scaling** to handle traffic spikes: a load-balanced Beanstalk
   environment (ALB, e.g. 1–3 instances). That's about +$18 a month, plus one public IPv4 per
   AZ.
2. **Use the `/actuator/health` check through the load balancer**, so a hung app is detected and
   replaced. The URL is already configured; it takes effect once the load balancer exists.
3. **Lock the origin to your CloudFront** with a secret header. CloudFront adds a custom header
   on the backend origin and the load balancer only forwards requests that carry it. Today any
   CloudFront distribution, not just yours, can reach the instance.
4. **Upgrade the account to the Paid plan** in AWS Settings (<https://settings.aws.com>).
   Remaining credits carry over. Otherwise the account closes when the Free plan ends, and the
   app goes down with it.
5. **Raise RDS backups to 7 days** (`db_backup_retention_days = 7`; the Free plan allows only
   1). Consider turning on storage autoscaling too.
6. **Take a database dump** (see Operations) before the Free plan ends, as long as you're on it.
7. **Add an outside uptime check.** Today only Beanstalk's own health agent notices that the API
   is down. The load balancer's `/actuator/health` check (item 2) covers this for free. A Route 53
   health check isn't an option on this account: its metrics, and therefore its alarm, live in
   us-east-1, where the SCP denies SNS.

A custom domain (below) also allows HTTPS between CloudFront and the load balancer.

## Adding a custom domain later

No app changes are needed: the frontend builds its login/logout URLs from the page's own address
and calls the API as `/api`. In Terraform:

1. Request an ACM certificate in **us-east-1**, which CloudFront requires. Add a second
   `provider "aws"` with `alias = "us_east_1"`, then `aws_acm_certificate` plus DNS validation
   records.
2. On `aws_cloudfront_distribution.main`, set `aliases = ["app.example.com"]` and point
   `viewer_certificate` at the certificate (`ssl_support_method = "sni-only"`,
   `minimum_protocol_version = "TLSv1.2_2021"`).
3. Point `local.app_url` at the domain, or add it to `callback_urls`/`logout_urls` in
   `cognito.tf` next to the CloudFront address.
4. Create a DNS record (Route 53 alias, or a CNAME at your DNS provider) to the distribution.

## Troubleshooting the first apply

- **RDS: `FreeTierRestrictionError … backup retention period`.** The Free plan refused even 1
  day. Set `db_backup_retention_days = 0` and rely on manual snapshots or dumps.
- **Beanstalk refuses the secret ARN in `SPRING_DATASOURCE_PASSWORD`.** Look for an invalid
  option value in the `aws:elasticbeanstalk:application:environmentsecrets` namespace. RDS names
  its secret `rds!db-…`, and it wasn't possible to confirm beforehand that Beanstalk accepts the
  `!`. The fallback is a Terraform-generated password:
  - Set `manage_master_user_password = false` on the database.
  - Generate the password with an ephemeral `random_password` and set it through the write-only
    `password_wo`.
  - Store it in an `aws_secretsmanager_secret` with a normal name (`secret_string_wo`), point the
    Beanstalk setting at that secret, and drop the rotation resource.

  The password still never appears in the state.
- **CloudFront: "Your account must be verified before you can add new CloudFront resources".**
  Open a free AWS Support case (Account and billing) and ask for verification.
- **EC2: vCPU limit exceeded** during a platform update. The account allows 5 vCPUs, and two
  t4g.micro use 4. Request more in Service Quotas ("Running On-Demand Standard instances").
- **`ExpiredToken` or no credentials.** Run `aws login --profile healthytech` again.
- **`aws_cloudwatch_log_metric_filter.app_errors`: "The specified log group does not exist".**
  Beanstalk creates the app's log group shortly after the environment. Wait a few minutes and
  run `terraform apply` again.
- **`No value for required variable "alert_emails"`, or a warning about an undeclared
  `alert_email`.** The `terraform.tfvars` predates the switch to a list. Replace
  `alert_email = "you@example.com"` with `alert_emails = ["you@example.com"]` and upload the file
  to the state bucket again (Setup, A step 8).
- **Every `terraform plan` shows a change to a Beanstalk setting.** Beanstalk reports some
  settings in its own form, and Terraform compares them as text. `ConfigDocument` is therefore a
  literal string in Beanstalk's key order, and `Subnets` is sorted. If one of them shows up
  again, copy the value Beanstalk reports (the `-` side of the plan) into `backend.tf`.
  `ServiceRoleForManagedUpdates` is the known exception (Setup, B step 6).
- **`updating Elastic Beanstalk Environment: Service:AmazonSNS, Message:Topic does not exist`.**
  This happened once, when the notifications moved from Beanstalk's own topic to
  `supple-ai-prod-alerts`. Beanstalk applied the new settings anyway. Run `terraform apply`
  again; it only creates what the failed run skipped.
- **The app's Users screen shows "The user directory is unavailable".** The backend got an error
  from Cognito; the cause is in the app log. Usually the instance role lacks
  `cognito-idp:ListUsers`/`ListUsersInGroup` (the `ReadUserPool` statement in `backend.tf`), so
  run `terraform apply`. No restart is needed; the next request uses the new permission.

## Destroying

The database and the user pool have deletion protection, so `terraform destroy` stops at them.
1. Turn it off first: `deletion_protection = false` on `aws_db_instance.main` and `"INACTIVE"`
   on `aws_cognito_user_pool.main`, then apply.
2. Empty the frontend and artifacts buckets.
3. Run `terraform destroy`. RDS leaves a final snapshot named `supple-ai-prod-db-final`.
4. The state bucket from `bootstrap-state.sh` is not managed by Terraform. Delete it by hand
   if needed.
