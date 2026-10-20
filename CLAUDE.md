# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Terraform for the single `prod` environment of Supple AI in `eu-north-1`. It covers the Spring Boot backend (`../supple-ai-backend`) on Elastic Beanstalk with RDS PostgreSQL, and the Angular back-office (`../supple-ai-frontend`) on S3 + CloudFront. Cognito handles auth and AWS Budgets handles cost alerts. Sized for a few users at the lowest cost. `README.md` is the operator guide: setup order, first apply, deploying, Google sign-in, "Before going live", custom domain and troubleshooting.

Terraform manages infrastructure only. App code is deployed by `scripts/deploy-backend.sh` and `scripts/deploy-frontend.sh`, which read every value from `terraform output -raw`. Keep outputs and scripts in sync.

## Commands

```bash
export AWS_PROFILE=healthytech                   # `aws login --profile healthytech` first; Terraform reads the same profile
scripts/bootstrap-state.sh                       # once per account: state bucket + backend.hcl
terraform init -backend-config=backend.hcl
terraform fmt -recursive
terraform validate
terraform plan
terraform apply                                  # the user runs this, not Claude
terraform init -backend=false && terraform validate   # offline check, no AWS access needed
scripts/deploy-backend.sh                        # SKIP_TESTS=1 to skip the backend test suite
scripts/deploy-frontend.sh
```

- Use the `aws-mcp` tools (profile `healthytech`) for AWS lookups. Don't run the AWS CLI through Bash; the deploy and bootstrap scripts are for the user to run.
- Never run `terraform apply`/`destroy` or the deploy scripts without the user asking. They create billable resources or change production.
- The provider lock file is committed and pinned for macOS/Linux/Windows. After a provider bump, run `terraform providers lock -platform=darwin_arm64 -platform=darwin_amd64 -platform=linux_amd64 -platform=linux_arm64 -platform=windows_amd64`.

## Layout and conventions

- Flat root module, one file per concern: `network.tf`, `database.tf`, `cognito.tf`, `backend.tf` (Elastic Beanstalk, i.e. the *app* backend), `frontend.tf`, `budget.tf`, `variables.tf` (naming locals at the top), `outputs.tf`, `versions.tf` (Terraform's S3 state backend and the provider).
- Names come from `local.name` (`supple-ai-prod`). Tags come from provider `default_tags`, so don't add per-resource tags except `Name`.
- State: S3 with `use_lockfile = true` (no DynamoDB). Bucket, key and region are in the gitignored `backend.hcl` written by `scripts/bootstrap-state.sh`. Never commit state, `*.tfvars` or `backend.hcl`. `terraform.tfvars.example` is the template.
- Pinned versions: Terraform ≥ 1.11, `hashicorp/aws ~> 6.69.1`, `terraform-aws-modules/vpc/aws 6.7.3`.

## Design decisions to preserve

- **One CloudFront distribution for app and API.** `/api/*` goes to Beanstalk; everything else goes to the private S3 bucket through OAC. This makes every browser call same-origin. The backend has no CORS configuration and the frontend uses relative `/api` URLs. Don't add a second distribution or absolute API URLs.
- **SPA routing via a 404-only custom error response.** CloudFront error responses apply to the whole distribution, including `/api/*`. So only 404 is rewritten to `/index.html`, and the bucket policy grants CloudFront `s3:ListBucket` so S3 returns 404 (not 403) for missing keys. The backend's 403s must pass through. Its only 404 is GET-by-id with an unknown id, which the app doesn't call. Don't add a 403 rule. The user doesn't want Lambda or CloudFront Functions for now.
- **Origin lock.** The instance security group allows port 80 only from the `com.amazonaws.global.cloudfront.origin-facing` prefix list. The list weighs 55 of the 60-rule limit, so there's no room for another prefix-list rule. `DisableDefaultEC2SecurityGroup = true` keeps Beanstalk's world-open group off. There's no SSH; use Session Manager.
- **Single-instance Beanstalk, HTTP origin.** There's no load balancer for cost reasons. Without one, Beanstalk ignores the `/actuator/health` URL; it's set so it takes effect when an ALB is added. `README.md` "Before going live" lists the planned upgrades: ALB with auto scaling, the health check through it, a secret origin header, the Paid plan, 7-day backups.
- **Database password.** `manage_master_user_password = true`. Beanstalk injects the secret's `password` key as `SPRING_DATASOURCE_PASSWORD` (`environmentsecrets` namespace, `<arn>:password`), but only reads it at instance start or deploy. So `aws_secretsmanager_secret_rotation` turns rotation off. The `!` in RDS secret names was unverified against Beanstalk's validation; the README's troubleshooting section has the fallback.
- **Environment `lifecycle.ignore_changes = [version_label, solution_stack_name]`.** The deploy script changes the version and managed platform updates change the stack. The stack comes from a `most_recent` data source matching `Corretto 25` on AL2023.
- **Cognito.** One pool for admins and users with self sign-up. Admins are members of the `admin` group, added by hand in the console; the backend maps groups to `ROLE_<GROUP>` and requires exactly `admin`. Managed Login v2 with Cognito's default branding. Google is the built-in social provider, created only when both Google variables are set; generic OIDC would get only 50 free MAUs. Callback/logout URLs are the CloudFront address and `http://localhost:4200`.
- **The apps hold only the Cognito IDs.** Frontend `src/environments/environment.ts` and the backend `application.yaml` issuer default. They contain `SET-AFTER-FIRST-APPLY` placeholders until the first apply. `deploy-frontend.sh` refuses builds whose IDs don't match `terraform output`.

## AWS account constraints

- The `healthytech` account is a "Sign up for AWS (new)" project account on the **Free plan**. AWS-managed SCPs allow regional resources only in `eu-north-1`; global services go through `us-east-1`, and ACM, CloudFront, Budgets and IAM are allowed there. Spot, Lambda@Edge, Organizations changes and IAM `*Provider*` actions are denied. Roles under `/managed/` are AWS's; don't touch them.
- The Free plan allows only free-tier instance types (t3/t4g micro/small, c7i-flex.large, m7i-flex.large; `db.t3.micro`/`db.t4g.micro` for RDS). It reportedly rejects RDS backup retention above 1 day and in-place EC2 resizes. The account closes when the credits run out or the plan ends (2027-04-15 as of 2026-10-19), unless upgraded in AWS Settings. Check with `freetier GetAccountPlanState` through aws-mcp.
- EC2 vCPU quota is 5: one t4g.micro (2 vCPU), plus a second one temporarily during managed platform updates.
- Budgets must use `include_credit = false`. On the Free plan, usage net of credits is always $0.
