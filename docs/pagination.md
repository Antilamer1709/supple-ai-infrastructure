# Pagination infrastructure

Paged API reads use the existing API route and Cognito user pool. Infrastructure provides the user-directory permissions and forwards query parameters without caching API responses.

## User-directory permissions

The backend instance role has a `ReadUserPool` policy statement scoped to the application's Cognito pool ARN:

| Permission                     | Purpose                                                                  |
| ------------------------------ | ------------------------------------------------------------------------ |
| `cognito-idp:ListUsers`        | Read account pages and support directory lookups.                        |
| `cognito-idp:ListUsersInGroup` | Read members of the `admin` group.                                       |
| `cognito-idp:DescribeUserPool` | Read the pool's estimated user count for the dashboard; paging skips it. |

Reading the admin group once supports a user-page cost that does not grow with each displayed account. The `admin` group is managed in the same Terraform configuration. The configured issuer identifies the pool and region.

## API request routing

CloudFront forwards `/api/*` requests and their viewer query parameters to the backend with caching disabled. Page numbers, cursors, searches and filters therefore reach the application unchanged, and responses remain specific to the current request and user.

The existing route and pool permissions support pagination without additional infrastructure services. The [troubleshooting guide](../README.md#troubleshooting) covers user-directory access failures.
