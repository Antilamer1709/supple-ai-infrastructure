# CloudWatch monitoring: the alert topics, the app's error count, the alarms and the dashboard.
# docs/monitoring.md is the operator guide (where to look, log queries, changing recipients).
#
# Everything here fits CloudWatch's always-free tier, which also applies on the Paid plan:
# - Alarm metrics: 10 of 10 used. Each alarm counts once per metric it reads, so the heap
#   alarm (used ÷ max) counts twice.
# - No CloudFront alarm: CloudFront's metrics exist only in us-east-1, an alarm can notify only
#   an SNS topic in its own region, and the account's SCP denies SNS in us-east-1.
# - Custom metrics: 6 of 10 used. Beanstalk's ApplicationRequests5xx and ApplicationLatencyP95
#   (backend.tf ConfigDocument), the app's three Micrometer gauges, and ErrorLogLines below.
# - Dashboards: 1 of 3 used.
# Add an alarm or a metric only after removing another.

locals {
  # Must match management.cloudwatch.metrics.export.namespace in the backend's application.yaml
  backend_metrics_namespace = "SuppleAI/Backend"

  # Micrometer publishes a gauge as "<meter name>.value" (backend config/metrics/CloudWatchMetricsConfig)
  heap_used_metric       = "supple.jvm.heap.used.value"
  heap_max_metric        = "supple.jvm.heap.max.value"
  hikari_pending_metric  = "hikaricp.connections.pending.value"
  error_log_lines_metric = "ErrorLogLines"

  # Created by Beanstalk because StreamLogs is on (backend.tf)
  backend_log_group = "/aws/elasticbeanstalk/${aws_elastic_beanstalk_environment.backend.name}/var/log/web.stdout.log"

  beanstalk_env_dimension = { EnvironmentName = aws_elastic_beanstalk_environment.backend.name }
  # The instance changes on every platform update; the Auto Scaling group stays
  backend_asg_dimension = { AutoScalingGroupName = aws_elastic_beanstalk_environment.backend.autoscaling_groups[0] }
  database_dimension    = { DBInstanceIdentifier = aws_db_instance.main.identifier }

  dashboard_name = "${local.name}-overview"
}

# --- Alert topic -------------------------------------------------------------
# Every address in alert_emails subscribes and confirms once by email.

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# --- App errors --------------------------------------------------------------

# Counts the app's ERROR log lines. On Beanstalk every line is "<syslog prefix> {json}" with the
# level nested as "log":{"level":"ERROR",...}, so a regex matches it rather than a JSON pattern.
# Filter regexes reject the " character, so each . stands for one of the three characters ":".
resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "${local.name}-app-errors"
  log_group_name = local.backend_log_group
  pattern        = "%level...ERROR%"

  metric_transformation {
    name      = local.error_log_lines_metric
    namespace = local.backend_metrics_namespace
    value     = "1"
    unit      = "Count"
  }
}

# --- Alarms ------------------------------------------------------------------
# Each one emails when it fires and again when it clears. The thresholds are explained in
# docs/monitoring.md, with what to check first.

resource "aws_cloudwatch_metric_alarm" "environment_health" {
  alarm_name        = "${local.name}-environment-unhealthy"
  alarm_description = "Beanstalk reports the backend as Degraded or Severe for 5 minutes."

  namespace           = "AWS/ElasticBeanstalk"
  metric_name         = "EnvironmentHealth"
  dimensions          = local.beanstalk_env_dimension
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 20 # 0 OK, 15 Warning, 20 Degraded, 25 Severe
  # No data means Beanstalk itself stopped reporting
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name        = "${local.name}-api-5xx"
  alarm_description = "nginx on the instance answered 5 or more API requests with a 5xx within 5 minutes."

  namespace           = "AWS/ElasticBeanstalk"
  metric_name         = "ApplicationRequests5xx"
  dimensions          = local.beanstalk_env_dimension
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "heap" {
  alarm_name        = "${local.name}-heap-pressure"
  alarm_description = "The backend's heap stayed above 90% of its maximum for 15 minutes."

  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 90
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "heap_pct"
    expression  = "100 * used / max"
    label       = "Heap used (%)"
    return_data = true
  }

  metric_query {
    id = "used"

    metric {
      namespace   = local.backend_metrics_namespace
      metric_name = local.heap_used_metric
      stat        = "Average"
      period      = 300
    }
  }

  metric_query {
    id = "max"

    metric {
      namespace   = local.backend_metrics_namespace
      metric_name = local.heap_max_metric
      stat        = "Average"
      period      = 300
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "db_pool_starved" {
  alarm_name        = "${local.name}-db-pool-starved"
  alarm_description = "Requests waited for a database connection for 5 minutes in a row."

  namespace           = local.backend_metrics_namespace
  metric_name         = local.hikari_pending_metric
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "app_errors" {
  alarm_name        = "${local.name}-app-errors"
  alarm_description = "The backend logged at least one ERROR line within 5 minutes."

  namespace           = local.backend_metrics_namespace
  metric_name         = local.error_log_lines_metric
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  depends_on = [aws_cloudwatch_log_metric_filter.app_errors]
}

resource "aws_cloudwatch_metric_alarm" "db_storage" {
  alarm_name        = "${local.name}-db-storage-low"
  alarm_description = "The database has less than 2 GiB of its 20 GiB disk left."

  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = local.database_dimension
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 2 * 1024 * 1024 * 1024
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# T4g instances run in unlimited mode: below zero credits AWS bills the surplus CPU instead of
# throttling, so a low balance is the warning before a charge (both credit alarms)
resource "aws_cloudwatch_metric_alarm" "db_cpu_credits" {
  alarm_name        = "${local.name}-db-cpu-credits-low"
  alarm_description = "The database's CPU credit balance fell below 30; at 0 surplus CPU is billed."

  namespace           = "AWS/RDS"
  metric_name         = "CPUCreditBalance"
  dimensions          = local.database_dimension
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 30
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "backend_cpu_credits" {
  alarm_name        = "${local.name}-backend-cpu-credits-low"
  alarm_description = "The backend instance's CPU credit balance fell below 30; at 0 surplus CPU is billed."

  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  dimensions          = local.backend_asg_dimension
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 30
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "api_latency" {
  alarm_name        = "${local.name}-api-slow"
  alarm_description = "The API's p95 response time stayed above 2 seconds for 15 minutes."

  namespace           = "AWS/ElasticBeanstalk"
  metric_name         = "ApplicationLatencyP95"
  dimensions          = local.beanstalk_env_dimension
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 2 # seconds
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# --- Dashboard ---------------------------------------------------------------

locals {
  # One graph widget; metrics use CloudWatch's array form [namespace, name, dim, value, {options}]
  dashboard_graph = {
    view    = "timeSeries"
    stacked = false
    region  = var.region
  }
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = local.dashboard_name

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "alarm", x = 0, y = 0, width = 24, height = 3
        properties = {
          title = "Alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.environment_health.arn,
            aws_cloudwatch_metric_alarm.api_5xx.arn,
            aws_cloudwatch_metric_alarm.api_latency.arn,
            aws_cloudwatch_metric_alarm.heap.arn,
            aws_cloudwatch_metric_alarm.db_pool_starved.arn,
            aws_cloudwatch_metric_alarm.app_errors.arn,
            aws_cloudwatch_metric_alarm.db_storage.arn,
            aws_cloudwatch_metric_alarm.db_cpu_credits.arn,
            aws_cloudwatch_metric_alarm.backend_cpu_credits.arn,
          ]
        }
      },
      {
        type = "metric", x = 0, y = 3, width = 12, height = 6
        properties = merge(local.dashboard_graph, {
          title  = "Environment health (20 = Degraded, 25 = Severe)"
          period = 60
          stat   = "Maximum"
          metrics = [
            ["AWS/ElasticBeanstalk", "EnvironmentHealth", "EnvironmentName", aws_elastic_beanstalk_environment.backend.name],
          ]
          yAxis       = { left = { min = 0, max = 25 } }
          annotations = { horizontal = [{ value = 20, label = "Degraded" }] }
        })
      },
      {
        type = "metric", x = 12, y = 3, width = 12, height = 6
        properties = merge(local.dashboard_graph, {
          title  = "API 5xx responses (per 5 min) and p95 latency (s)"
          period = 300
          metrics = [
            ["AWS/ElasticBeanstalk", "ApplicationRequests5xx", "EnvironmentName", aws_elastic_beanstalk_environment.backend.name, { stat = "Sum", label = "5xx" }],
            ["AWS/ElasticBeanstalk", "ApplicationLatencyP95", "EnvironmentName", aws_elastic_beanstalk_environment.backend.name, { stat = "Average", label = "p95 latency (s)", yAxis = "right" }],
          ]
        })
      },
      {
        type = "metric", x = 0, y = 9, width = 12, height = 6
        properties = merge(local.dashboard_graph, {
          title  = "JVM heap (bytes)"
          period = 60
          stat   = "Average"
          metrics = [
            [local.backend_metrics_namespace, local.heap_used_metric, { label = "used" }],
            [local.backend_metrics_namespace, local.heap_max_metric, { label = "max" }],
          ]
          yAxis = { left = { min = 0 } }
        })
      },
      {
        type = "metric", x = 12, y = 9, width = 12, height = 6
        properties = merge(local.dashboard_graph, {
          title  = "App ERROR lines (per 5 min) and requests waiting for a DB connection"
          period = 300
          metrics = [
            [local.backend_metrics_namespace, local.error_log_lines_metric, { stat = "Sum", label = "ERROR lines" }],
            [local.backend_metrics_namespace, local.hikari_pending_metric, { stat = "Maximum", label = "DB pool pending", yAxis = "right" }],
          ]
        })
      },
      {
        type = "metric", x = 0, y = 15, width = 12, height = 6
        properties = merge(local.dashboard_graph, {
          title  = "Backend instance CPU (%) and CPU credits"
          period = 300
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_elastic_beanstalk_environment.backend.autoscaling_groups[0], { stat = "Average", label = "CPU %" }],
            ["AWS/EC2", "CPUCreditBalance", "AutoScalingGroupName", aws_elastic_beanstalk_environment.backend.autoscaling_groups[0], { stat = "Minimum", label = "credits", yAxis = "right" }],
          ]
        })
      },
      {
        type = "metric", x = 12, y = 15, width = 12, height = 6
        properties = merge(local.dashboard_graph, {
          title  = "Database CPU (%), CPU credits and connections"
          period = 300
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.main.identifier, { stat = "Average", label = "CPU %" }],
            ["AWS/RDS", "CPUCreditBalance", "DBInstanceIdentifier", aws_db_instance.main.identifier, { stat = "Minimum", label = "credits", yAxis = "right" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.main.identifier, { stat = "Maximum", label = "connections" }],
          ]
        })
      },
      {
        type = "metric", x = 0, y = 21, width = 12, height = 6
        properties = merge(local.dashboard_graph, {
          title  = "Database free storage (bytes)"
          period = 300
          stat   = "Minimum"
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", aws_db_instance.main.identifier],
          ]
          yAxis       = { left = { min = 0 } }
          annotations = { horizontal = [{ value = 2 * 1024 * 1024 * 1024, label = "alarm (2 GiB)" }] }
        })
      },
      {
        type = "metric", x = 12, y = 21, width = 12, height = 6
        properties = merge(local.dashboard_graph, {
          # Reading CloudWatch in us-east-1 is allowed; only SNS is denied there
          title  = "CloudFront requests and 5xx rate (%), app and API (us-east-1)"
          region = "us-east-1"
          period = 300
          metrics = [
            ["AWS/CloudFront", "Requests", "DistributionId", aws_cloudfront_distribution.main.id, "Region", "Global", { stat = "Sum", label = "requests" }],
            ["AWS/CloudFront", "5xxErrorRate", "DistributionId", aws_cloudfront_distribution.main.id, "Region", "Global", { stat = "Average", label = "5xx %", yAxis = "right" }],
          ]
        })
      },
    ]
  })
}
