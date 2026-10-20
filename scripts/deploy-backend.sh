#!/usr/bin/env bash
# Builds the Spring Boot JAR, uploads it as a new Elastic Beanstalk application version and
# deploys it. Values come from `terraform output`, so run `terraform apply` first.
#
#   export AWS_PROFILE=healthytech
#   scripts/deploy-backend.sh               # builds with the full test suite (needs Docker)
#   SKIP_TESTS=1 scripts/deploy-backend.sh  # builds without tests
#
# BACKEND_DIR overrides the backend repo location (default: ../supple-ai-backend).
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND_DIR="${BACKEND_DIR:-$INFRA_DIR/../supple-ai-backend}"
TIMEOUT_SECONDS=900

for tool in aws terraform git; do
  command -v "$tool" >/dev/null || { echo "error: $tool is not installed" >&2; exit 1; }
done

tf_output() { terraform -chdir="$INFRA_DIR" output -raw "$1"; }

REGION="$(tf_output region)"
APP_NAME="$(tf_output beanstalk_application_name)"
ENV_NAME="$(tf_output beanstalk_environment_name)"
BUCKET="$(tf_output artifacts_bucket)"

cd "$BACKEND_DIR"

MVN_ARGS=(-B clean package)
if [[ "${SKIP_TESTS:-0}" == "1" ]]; then
  MVN_ARGS+=(-DskipTests)
fi
echo "==> Building the JAR (./mvnw ${MVN_ARGS[*]})"
./mvnw "${MVN_ARGS[@]}"

JARS=(target/*.jar)
if [[ ${#JARS[@]} -ne 1 || ! -f "${JARS[0]}" ]]; then
  echo "error: expected exactly one JAR in $BACKEND_DIR/target, found: ${JARS[*]}" >&2
  exit 1
fi
JAR="${JARS[0]}"

LABEL="$(date -u +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)"
if [[ -n "$(git status --porcelain)" ]]; then
  LABEL="${LABEL}-dirty"
fi
KEY="backend/${LABEL}.jar"

echo "==> Uploading $JAR to s3://$BUCKET/$KEY"
aws s3 cp "$JAR" "s3://$BUCKET/$KEY" --region "$REGION"

echo "==> Creating application version $LABEL"
aws elasticbeanstalk create-application-version --region "$REGION" \
  --application-name "$APP_NAME" \
  --version-label "$LABEL" \
  --source-bundle "S3Bucket=$BUCKET,S3Key=$KEY" \
  --description "$(git log -1 --format=%s | cut -c1-200)" >/dev/null

echo "==> Deploying $LABEL to $ENV_NAME"
aws elasticbeanstalk update-environment --region "$REGION" \
  --environment-name "$ENV_NAME" \
  --version-label "$LABEL" >/dev/null

env_field() {
  aws elasticbeanstalk describe-environments --region "$REGION" \
    --environment-names "$ENV_NAME" --query "Environments[0].$1" --output text
}

deadline=$((SECONDS + TIMEOUT_SECONDS))
while [[ "$(env_field Status)" != "Ready" ]]; do
  if ((SECONDS > deadline)); then
    echo "error: $ENV_NAME is still updating after ${TIMEOUT_SECONDS}s; check the Beanstalk console" >&2
    exit 1
  fi
  sleep 15
done

DEPLOYED="$(env_field VersionLabel)"
HEALTH="$(env_field HealthStatus)"
if [[ "$DEPLOYED" != "$LABEL" ]]; then
  echo "error: deployment failed; $ENV_NAME is running $DEPLOYED instead of $LABEL" >&2
  echo "Recent events:" >&2
  aws elasticbeanstalk describe-events --region "$REGION" --environment-name "$ENV_NAME" \
    --max-items 15 --query 'Events[].[EventDate,Severity,Message]' --output text >&2
  exit 1
fi

echo "==> Deployed $LABEL to $ENV_NAME (health: $HEALTH)"
echo "    API:     $(tf_output cloudfront_url)/api"
echo "    Swagger: $(tf_output cloudfront_url)/api/swagger-ui.html"
