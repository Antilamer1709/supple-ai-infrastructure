#!/usr/bin/env bash
# Builds the Angular app, uploads it to the frontend bucket and invalidates CloudFront.
# Values come from `terraform output`, so run `terraform apply` first.
#
#   export AWS_PROFILE=healthytech
#   scripts/deploy-frontend.sh
#
# FRONTEND_DIR overrides the frontend repo location (default: ../supple-ai-frontend).
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FRONTEND_DIR="${FRONTEND_DIR:-$INFRA_DIR/../supple-ai-frontend}"

for tool in aws terraform npm; do
  command -v "$tool" >/dev/null || { echo "error: $tool is not installed" >&2; exit 1; }
done

tf_output() { terraform -chdir="$INFRA_DIR" output -raw "$1"; }

REGION="$(tf_output region)"
BUCKET="$(tf_output frontend_bucket)"
DISTRIBUTION_ID="$(tf_output cloudfront_distribution_id)"
CLIENT_ID="$(tf_output cognito_client_id)"
POOL_ID="$(tf_output cognito_user_pool_id)"
APP_URL="$(tf_output cloudfront_url)"

cd "$FRONTEND_DIR"

echo "==> Building the app"
npm ci
npm run build
DIST="dist/supple-ai/browser"

# A build with another pool's IDs would deploy fine and then fail at login
for id in "$CLIENT_ID" "$POOL_ID"; do
  if ! grep -rqF "$id" "$DIST"; then
    echo "error: the build doesn't contain $id from terraform output." >&2
    echo "Set oidcIssuerUri and oidcClientId in $FRONTEND_DIR/src/environments/environment.ts" >&2
    echo "(terraform output cognito_issuer_uri / cognito_client_id) and run again." >&2
    exit 1
  fi
done

# 1. New files first, so the old index.html never points at missing files.
#    JS, CSS and media/ have content hashes in their names, so browsers may cache them forever.
echo "==> Uploading to s3://$BUCKET"
aws s3 sync "$DIST" "s3://$BUCKET" --region "$REGION" \
  --exclude "*" --include "*.js" --include "*.css" --include "media/*" \
  --cache-control "public,max-age=31536000,immutable"
aws s3 sync "$DIST" "s3://$BUCKET" --region "$REGION" \
  --exclude "*.js" --exclude "*.css" --exclude "media/*" --exclude "index.html"

# 2. index.html last; browsers re-check it on every visit
aws s3 cp "$DIST/index.html" "s3://$BUCKET/index.html" --region "$REGION" \
  --cache-control "no-cache" --content-type "text/html; charset=utf-8"

# 3. Remove files the new build no longer has
aws s3 sync "$DIST" "s3://$BUCKET" --region "$REGION" --delete --exclude "index.html"

echo "==> Invalidating the CloudFront cache"
INVALIDATION_ID="$(aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*" --query Invalidation.Id --output text)"
aws cloudfront wait invalidation-completed --distribution-id "$DISTRIBUTION_ID" --id "$INVALIDATION_ID"

echo "==> Deployed to $APP_URL"
