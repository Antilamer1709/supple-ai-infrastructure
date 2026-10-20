#!/usr/bin/env bash
# Creates the S3 bucket for the Terraform state and writes backend.hcl for `terraform init`.
# Run once per AWS account, before the first `terraform init`. Safe to re-run.
#
#   export AWS_PROFILE=healthytech
#   scripts/bootstrap-state.sh
#   terraform init -backend-config=backend.hcl
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-eu-north-1}"

command -v aws >/dev/null || { echo "error: the AWS CLI is not installed" >&2; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="supple-ai-tfstate-${ACCOUNT_ID}"

if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
  echo "State bucket s3://$BUCKET already exists"
else
  echo "Creating state bucket s3://$BUCKET in $REGION"
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
fi

# Versioning keeps every earlier state file, so a broken apply can be rolled back
aws s3api put-bucket-versioning --bucket "$BUCKET" --region "$REGION" \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block --bucket "$BUCKET" --region "$REGION" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption --bucket "$BUCKET" --region "$REGION" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

aws s3api put-bucket-policy --bucket "$BUCKET" --region "$REGION" --policy "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::${BUCKET}", "arn:aws:s3:::${BUCKET}/*"],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
EOF
)"

# Old state versions are kept for 90 days
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --region "$REGION" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "expire-old-state-versions",
      "Status": "Enabled",
      "Filter": {},
      "NoncurrentVersionExpiration": { "NoncurrentDays": 90 },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }]
  }'

aws s3api put-bucket-tagging --bucket "$BUCKET" --region "$REGION" --tagging \
  'TagSet=[{Key=Project,Value=supple-ai},{Key=Environment,Value=prod},{Key=ManagedBy,Value=bootstrap-state.sh},{Key=Repository,Value=supple-ai-infrastructure}]'

cat >"$INFRA_DIR/backend.hcl" <<EOF
# Written by scripts/bootstrap-state.sh; not committed (it contains the account ID)
bucket = "${BUCKET}"
key    = "prod/terraform.tfstate"
region = "${REGION}"
EOF

echo "Wrote $INFRA_DIR/backend.hcl"
echo "Next: terraform init -backend-config=backend.hcl"
