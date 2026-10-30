output "region" {
  description = "AWS region of the regional resources."
  value       = var.region
}

output "cloudfront_url" {
  description = "Public HTTPS address of the app; the API is under /api and Swagger UI at /api/swagger-ui.html."
  value       = local.app_url
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID, used for cache invalidations."
  value       = aws_cloudfront_distribution.main.id
}

output "frontend_bucket" {
  description = "S3 bucket holding the Angular build."
  value       = aws_s3_bucket.frontend.bucket
}

output "artifacts_bucket" {
  description = "S3 bucket holding the backend JARs (Beanstalk application versions)."
  value       = aws_s3_bucket.artifacts.bucket
}

output "beanstalk_application_name" {
  description = "Elastic Beanstalk application name."
  value       = aws_elastic_beanstalk_application.backend.name
}

output "beanstalk_environment_name" {
  description = "Elastic Beanstalk environment name."
  value       = aws_elastic_beanstalk_environment.backend.name
}

output "cognito_user_pool_id" {
  description = "Cognito user pool ID."
  value       = aws_cognito_user_pool.main.id
}

output "cognito_issuer_uri" {
  description = "JWT issuer: the frontend's oidcIssuerUri and the backend's COGNITO_ISSUER_URI."
  value       = "https://${aws_cognito_user_pool.main.endpoint}"
}

output "cognito_client_id" {
  description = "Cognito app client ID for the back-office (frontend oidcClientId)."
  value       = aws_cognito_user_pool_client.backoffice.id
}

output "cognito_mobile_client_id" {
  description = "Cognito app client ID for the mobile app (supple-ai-backend/docs/mobile-client.md)."
  value       = aws_cognito_user_pool_client.mobile.id
}

output "mobile_redirect_urls" {
  description = "The mobile app client's sign-in callback and sign-out URLs."
  value = {
    callback = one(aws_cognito_user_pool_client.mobile.callback_urls)
    signout  = one(aws_cognito_user_pool_client.mobile.logout_urls)
  }
}

output "cognito_domain" {
  description = "Cognito login domain (Managed Login pages and the /logout endpoint)."
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
}

output "database_secret_arn" {
  description = "Secrets Manager secret holding the RDS master user and password."
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}
