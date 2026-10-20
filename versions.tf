terraform {
  # 1.11 is the first release with S3-native state locking (use_lockfile)
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69.1"
    }
  }

  # bucket, key and region come from backend.hcl, which scripts/bootstrap-state.sh writes:
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "supple-ai-infrastructure"
    }
  }
}
