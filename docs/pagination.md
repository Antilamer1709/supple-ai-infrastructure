# Pagination release

The backend’s Users endpoint reads one Cognito cursor page with `ListUsers`, then the members of the `admin` group with `ListUsersInGroup`. The latter normally takes one call because there are only a handful of admins; provider continuations are followed. An empty user page skips the group read. Audit actor lookups use the same two reads, while the nightly activity cleanup lists only user subs.

`backend.tf` grants both actions through `ReadUserPool`, scoped to the existing pool ARN. The issuer still supplies the pool id and region; no new environment variable is needed. A provider or IAM failure remains a 503 on Users. Neither the user list nor its API responses are cached by CloudFront.

## Operator sequence

1. Validate Terraform with `terraform fmt -check -recursive` and `terraform init -backend=false && terraform validate` before release.
2. Prepare matching application builds and follow the backend’s [coordinated rollout](../../supple-ai-backend/docs/pagination.md#coordinated-rollout), including the back-office reload requirement and mobile migration.
3. Run `terraform apply` immediately before `scripts/deploy-backend.sh`. Removing the old per-user membership permission temporarily makes Users unavailable on the previous pagination backend; during that interval audit writes retain only the actor sub. Deploy the prepared backend promptly.
4. Verify Users, cursor navigation and an audited admin write. A missing `admin` group or either missing read permission is a configuration failure, not a reason to treat every account as a regular user.

Local implementation checks do not apply Terraform or deploy applications. See the README’s [troubleshooting](../README.md#troubleshooting) if the directory is unavailable.
