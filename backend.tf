# Elastic Beanstalk environment for the Spring Boot backend (supple-ai-backend).
# Terraform manages the infrastructure only; scripts/deploy-backend.sh uploads and deploys the JAR.

# --- IAM ---------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backend_instance" {
  name               = "${local.name}-backend-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "backend_instance" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier",
    # Session Manager shell access instead of SSH
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.backend_instance.name
  policy_arn = each.value
}

data "aws_iam_policy_document" "backend_instance" {
  statement {
    sid       = "ReadDatabasePassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.main.master_user_secret[0].secret_arn]
  }

  statement {
    sid       = "DownloadAppVersions"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
}

resource "aws_iam_role_policy" "backend_instance" {
  name   = "app-access"
  role   = aws_iam_role.backend_instance.id
  policy = data.aws_iam_policy_document.backend_instance.json
}

resource "aws_iam_instance_profile" "backend" {
  name = "${local.name}-backend"
  role = aws_iam_role.backend_instance.name
}

data "aws_iam_policy_document" "beanstalk_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["elasticbeanstalk.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = ["elasticbeanstalk"]
    }
  }
}

# Used by Beanstalk itself for enhanced health, managed platform updates and version cleanup
resource "aws_iam_role" "beanstalk_service" {
  name               = "${local.name}-beanstalk-service"
  assume_role_policy = data.aws_iam_policy_document.beanstalk_assume_role.json
}

resource "aws_iam_role_policy_attachment" "beanstalk_service" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth",
    "arn:aws:iam::aws:policy/AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy",
  ])

  role       = aws_iam_role.beanstalk_service.name
  policy_arn = each.value
}

# --- Application versions ----------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  bucket = "${local.name}-artifacts-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_elastic_beanstalk_application" "backend" {
  name        = "${local.name}-backend"
  description = "Spring Boot API for the Supple AI back-office"

  # Keep the last 10 versions and delete older JARs from the artifacts bucket
  appversion_lifecycle {
    service_role          = aws_iam_role.beanstalk_service.arn
    max_count             = 10
    delete_source_from_s3 = true
  }
}

# --- Environment -------------------------------------------------------------

data "aws_elastic_beanstalk_solution_stack" "corretto25" {
  most_recent = true
  name_regex  = "^64bit Amazon Linux 2023 v4\\.[0-9.]+ running Corretto 25$"
}

locals {
  beanstalk_settings = [
    # One instance with an Elastic IP and no load balancer. Add a load balancer before
    # going live (README.md, "Before going live").
    { namespace = "aws:elasticbeanstalk:environment", name = "EnvironmentType", value = "SingleInstance" },
    { namespace = "aws:elasticbeanstalk:environment", name = "ServiceRole", value = aws_iam_role.beanstalk_service.arn },
    { namespace = "aws:ec2:instances", name = "InstanceTypes", value = var.backend_instance_type },
    { namespace = "aws:ec2:vpc", name = "VPCId", value = module.vpc.vpc_id },
    { namespace = "aws:ec2:vpc", name = "Subnets", value = join(",", module.vpc.public_subnets) },

    # Only our security group (port 80 from CloudFront). Beanstalk's default group
    # would open port 80 to the whole internet.
    { namespace = "aws:autoscaling:launchconfiguration", name = "SecurityGroups", value = aws_security_group.backend.id },
    { namespace = "aws:autoscaling:launchconfiguration", name = "DisableDefaultEC2SecurityGroup", value = "true" },
    { namespace = "aws:autoscaling:launchconfiguration", name = "IamInstanceProfile", value = aws_iam_instance_profile.backend.name },
    { namespace = "aws:autoscaling:launchconfiguration", name = "DisableIMDSv1", value = "true" },
    { namespace = "aws:autoscaling:launchconfiguration", name = "RootVolumeType", value = "gp3" },

    # Without a load balancer Beanstalk never calls this URL; it takes effect once one is added
    { namespace = "aws:elasticbeanstalk:application", name = "Application Healthcheck URL", value = "/actuator/health" },
    { namespace = "aws:elasticbeanstalk:healthreporting:system", name = "SystemType", value = "enhanced" },
    { namespace = "aws:elasticbeanstalk:sns:topics", name = "Notification Endpoint", value = var.alert_email },
    { namespace = "aws:elasticbeanstalk:sns:topics", name = "Notification Protocol", value = "email" },

    # Minor and patch platform updates on Sunday nights (UTC)
    { namespace = "aws:elasticbeanstalk:managedactions", name = "ManagedActionsEnabled", value = "true" },
    { namespace = "aws:elasticbeanstalk:managedactions", name = "PreferredStartTime", value = "Sun:03:00" },
    { namespace = "aws:elasticbeanstalk:managedactions", name = "ServiceRoleForManagedUpdates", value = aws_iam_role.beanstalk_service.arn },
    { namespace = "aws:elasticbeanstalk:managedactions:platformupdate", name = "UpdateLevel", value = "minor" },

    # Replace the app in place: about a minute of downtime per deploy
    { namespace = "aws:elasticbeanstalk:command", name = "DeploymentPolicy", value = "AllAtOnce" },

    { namespace = "aws:elasticbeanstalk:cloudwatch:logs", name = "StreamLogs", value = "true" },
    { namespace = "aws:elasticbeanstalk:cloudwatch:logs", name = "RetentionInDays", value = "14" },
    { namespace = "aws:elasticbeanstalk:cloudwatch:logs", name = "DeleteOnTerminate", value = "true" },

    # Environment variables read by application.yaml
    { namespace = "aws:elasticbeanstalk:application:environment", name = "SERVER_PORT", value = "5000" },
    { namespace = "aws:elasticbeanstalk:application:environment", name = "SPRING_DATASOURCE_URL", value = "jdbc:postgresql://${aws_db_instance.main.endpoint}/${aws_db_instance.main.db_name}" },
    { namespace = "aws:elasticbeanstalk:application:environment", name = "SPRING_DATASOURCE_USERNAME", value = aws_db_instance.main.username },
    { namespace = "aws:elasticbeanstalk:application:environment", name = "COGNITO_ISSUER_URI", value = "https://${aws_cognito_user_pool.main.endpoint}" },
    # Leave room next to Beanstalk's own agents on a 1 GiB instance
    { namespace = "aws:elasticbeanstalk:application:environment", name = "JAVA_TOOL_OPTIONS", value = "-XX:MaxRAMPercentage=40" },

    # The "password" key of the RDS-managed secret, fetched when the instance starts or
    # the app is deployed
    { namespace = "aws:elasticbeanstalk:application:environmentsecrets", name = "SPRING_DATASOURCE_PASSWORD", value = "${aws_db_instance.main.master_user_secret[0].secret_arn}:password" },
  ]
}

resource "aws_elastic_beanstalk_environment" "backend" {
  name                = "${local.name}-backend"
  application         = aws_elastic_beanstalk_application.backend.name
  tier                = "WebServer"
  cname_prefix        = local.name
  solution_stack_name = data.aws_elastic_beanstalk_solution_stack.corretto25.name

  dynamic "setting" {
    for_each = local.beanstalk_settings

    content {
      namespace = setting.value.namespace
      name      = setting.value.name
      value     = setting.value.value
    }
  }

  lifecycle {
    # The deploy script changes the version; managed platform updates change the stack
    ignore_changes = [version_label, solution_stack_name]
  }

  depends_on = [
    aws_iam_role_policy_attachment.backend_instance,
    aws_iam_role_policy_attachment.beanstalk_service,
    aws_iam_role_policy.backend_instance,
  ]
}
