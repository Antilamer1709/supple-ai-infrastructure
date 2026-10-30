locals {
  google_enabled = var.google_client_id != "" && var.google_client_secret != ""
}

# One pool for admins and regular users. Anyone can sign up; admins are the members
# of the "admin" group, added by hand in the AWS console.
resource "aws_cognito_user_pool" "main" {
  name           = local.name
  user_pool_tier = "ESSENTIALS"
  # Stops `terraform destroy` (or a mistaken replacement) from deleting every user
  deletion_protection = "ACTIVE"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  username_configuration {
    case_sensitive = false
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Cognito's built-in sender: about 50 emails a day, enough for a few users.
  # Switch to SES when sign-ups outgrow it.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
  }

  mfa_configuration = "OFF"
}

# The backend maps every group to ROLE_<GROUP> and requires ROLE_ADMIN for /api/internal/**,
# so the name must be exactly "admin"
resource "aws_cognito_user_group" "admin" {
  name         = "admin"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Back-office administrators"
}

# Google's built-in social provider (not a generic OIDC one: those get only 50 free monthly users)
resource "aws_cognito_identity_provider" "google" {
  count = local.google_enabled ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id        = var.google_client_id
    client_secret    = var.google_client_secret
    authorize_scopes = "openid email profile"
    # Cognito fills these in itself; listing them keeps the plan free of diffs
    attributes_url                = "https://people.googleapis.com/v1/people/me?personFields="
    attributes_url_add_attributes = "true"
    authorize_url                 = "https://accounts.google.com/o/oauth2/v2/auth"
    oidc_issuer                   = "https://accounts.google.com"
    token_request_method          = "POST"
    token_url                     = "https://www.googleapis.com/oauth2/v4/token"
  }

  # `picture` is the avatar URL the app shows. Every social provider maps its avatar to it;
  # one without an avatar leaves it unmapped and its users get the default avatar.
  attribute_mapping = {
    username       = "sub"
    email          = "email"
    email_verified = "email_verified"
    given_name     = "given_name"
    family_name    = "family_name"
    picture        = "picture"
  }
}

# Public client for the Angular back-office: authorization code flow with PKCE, no secret
resource "aws_cognito_user_pool_client" "backoffice" {
  name         = "${local.name}-bo"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  # 'profile' releases given_name/family_name and picture, shown in the app's user settings
  # dialog (the picture also in the sidebar)
  allowed_oauth_scopes         = ["phone", "openid", "email", "profile"]
  supported_identity_providers = concat(["COGNITO"], aws_cognito_identity_provider.google[*].provider_name)

  callback_urls = ["${local.app_url}/callback", "${local.local_dev_url}/callback"]
  logout_urls   = [local.app_url, local.local_dev_url]

  explicit_auth_flows           = ["ALLOW_USER_AUTH", "ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

# Public client for the mobile app, created ahead of the app so its developer never needs AWS
# access. It allows both Managed Login in the system browser (code + PKCE, Google included) and
# native sign-in screens through the Cognito SDK or Amplify (USER_AUTH / SRP). The backend gets
# its id as COGNITO_MOBILE_CLIENT_ID and counts its tokens as app activity, every other token as
# the back office.
resource "aws_cognito_user_pool_client" "mobile" {
  name         = "${local.name}-mobile"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["phone", "openid", "email", "profile"]
  supported_identity_providers         = concat(["COGNITO"], aws_cognito_identity_provider.google[*].provider_name)

  callback_urls = ["${local.mobile_url_scheme}://callback"]
  logout_urls   = ["${local.mobile_url_scheme}://signout"]

  explicit_auth_flows           = ["ALLOW_USER_AUTH", "ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  # Mobile users expect to stay signed in: a 90-day refresh token instead of the back office's 30
  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 90

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

# Managed Login (version 2), the current Cognito sign-in and sign-up pages
resource "aws_cognito_user_pool_domain" "main" {
  domain                = var.cognito_domain_prefix
  user_pool_id          = aws_cognito_user_pool.main.id
  managed_login_version = 2
}

# Managed Login shows nothing for a client without a style; this one is Cognito's default look
resource "aws_cognito_managed_login_branding" "backoffice" {
  user_pool_id                = aws_cognito_user_pool.main.id
  client_id                   = aws_cognito_user_pool_client.backoffice.id
  use_cognito_provided_values = true
}

resource "aws_cognito_managed_login_branding" "mobile" {
  user_pool_id                = aws_cognito_user_pool.main.id
  client_id                   = aws_cognito_user_pool_client.mobile.id
  use_cognito_provided_values = true
}
