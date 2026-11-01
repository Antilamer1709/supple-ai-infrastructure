locals {
  # Every resource name starts with this, e.g. supple-ai-prod-db
  name       = "${var.project}-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id

  # Public address of the app and the API (one CloudFront distribution serves both)
  app_url = "https://${aws_cloudfront_distribution.main.domain_name}"
  # Angular dev server; allowed as a Cognito login/logout return URL for local development
  local_dev_url = "http://localhost:4200"

  # Custom URL scheme of the mobile app's Cognito redirects (formulated://callback, formulated://signout).
  # Universal Links / App Links would need a custom domain.
  mobile_url_scheme = "formulated"
}

data "aws_caller_identity" "current" {}

variable "project" {
  description = "Project name, used as the first part of every resource name and as the Project tag."
  type        = string
  default     = "supple-ai"
}

variable "environment" {
  description = "Environment name, used in resource names and as the Environment tag."
  type        = string
  default     = "prod"
}

variable "region" {
  description = "AWS region for all regional resources."
  type        = string
  default     = "eu-north-1"
}

variable "alert_emails" {
  description = "Email addresses for every alert: CloudWatch alarms, Elastic Beanstalk events and the budget. Each one confirms its SNS subscription once."
  type        = list(string)

  validation {
    condition     = alltrue([for email in var.alert_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", email))])
    error_message = "Every entry of alert_emails must be an email address."
  }

  # AWS Budgets accepts at most 10 email subscribers per notification
  validation {
    condition     = length(var.alert_emails) >= 1 && length(var.alert_emails) <= 10 && length(distinct(var.alert_emails)) == length(var.alert_emails)
    error_message = "alert_emails must hold 1 to 10 distinct addresses."
  }
}

variable "backend_instance_type" {
  description = "EC2 instance type for the Beanstalk environment. Must be arm64 (Graviton) to match the t4g default."
  type        = string
  default     = "t4g.micro"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_backup_retention_days" {
  description = "Days of automated RDS backups. The AWS Free plan rejects 7; raise it after upgrading to the Paid plan."
  type        = number
  default     = 1

  validation {
    condition     = var.db_backup_retention_days >= 0 && var.db_backup_retention_days <= 35
    error_message = "db_backup_retention_days must be between 0 and 35."
  }
}

variable "cognito_domain_prefix" {
  description = "Prefix of the Cognito login domain (https://<prefix>.auth.<region>.amazoncognito.com). Must be unique in the region."
  type        = string
  default     = "supple-ai-prod"
}

variable "google_client_id" {
  description = "OAuth client ID from Google Cloud. Leave empty to run without \"Continue with Google\"."
  type        = string
  default     = ""
}

variable "google_client_secret" {
  description = "OAuth client secret from Google Cloud. Leave empty to run without \"Continue with Google\"."
  type        = string
  default     = ""
  sensitive   = true
}

variable "budget_limit_usd" {
  description = "Monthly budget in USD, measured before credits. Alerts go to alert_emails when actual or forecast spend exceeds it."
  type        = number
  default     = 30
}
