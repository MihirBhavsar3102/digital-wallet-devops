# Alarms. Each one notifies the alarm topic (created once in infra/bootstrap, see variables.tf) when it goes into
# ALARM and again when it recovers (OK). The thresholds are var.alarm_thresholds, the same numbers the dashboards
# draw. They are starting points: tune them once there is a baseline (README, "Alarms").
#
# treat_missing_data is chosen for each alarm, because "no data" means different things:
#   breaching     no data is itself a problem. Used where the metric should always exist: memory and disk (the
#                 agent that publishes them can fail to start without failing the boot, so its silence has to
#                 alarm), and the database's metrics (RDS always publishes them while it exists).
#   notBreaching  no data means "nothing happened". Used where an idle system publishes nothing: requests and
#                 latency (no traffic, no data points) and error counts (no errors, no data point).
#   The alarm on CPU uses notBreaching because the memory and disk alarms already cover a silent agent.
# An instance refresh that replaces the only staging instance leaves a gap in the agent's metrics, so the memory
# and disk alarms can fire once after a change to the launch template. That is a real "no data" and is accepted.
locals {
  alarm_topic = var.alarm_topic_arn
  agent_dims  = { AutoScalingGroupName = local.asg }

  target_groups = {
    backend  = local.be_tg
    frontend = local.fe_tg
  }
}

# ---------- instances ----------
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.name_prefix}-ec2-cpu-high"
  alarm_description   = "Average CPU of the app instances has been above ${local.limit.cpu_percent}% for 10 minutes. Look at what is using it (Dashboard 1), and whether a load test or a stuck deploy is running."
  namespace           = "CWAgent"
  metric_name         = "cpu_usage_active"
  dimensions          = local.agent_dims
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = local.limit.cpu_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching" # the memory and disk alarms cover a silent agent
  alarm_actions       = [local.alarm_topic]
  ok_actions          = [local.alarm_topic]
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "${var.name_prefix}-ec2-memory-high"
  alarm_description   = "Memory used on the app instances has been above ${local.limit.memory_percent}% for 10 minutes, or the agent stopped reporting it (missing data counts as breaching: check the CloudWatch agent, README 'CloudWatch agent')."
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  dimensions          = local.agent_dims
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = local.limit.memory_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching" # a silent agent is a problem
  alarm_actions       = [local.alarm_topic]
  ok_actions          = [local.alarm_topic]
}

resource "aws_cloudwatch_metric_alarm" "disk_high" {
  alarm_name          = "${var.name_prefix}-ec2-disk-high"
  alarm_description   = "The root disk of the app instances is more than ${local.limit.disk_percent}% full for 10 minutes, or the agent stopped reporting it (missing data counts as breaching). Old container images are the usual cause: docker image prune."
  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  dimensions          = local.agent_dims
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = local.limit.disk_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching" # a silent agent is a problem
  alarm_actions       = [local.alarm_topic]
  ok_actions          = [local.alarm_topic]
}

# ---------- load balancer ----------
resource "aws_cloudwatch_metric_alarm" "error_rate_high" {
  alarm_name          = "${var.name_prefix}-alb-5xx-rate-high"
  alarm_description   = "More than ${local.limit.error_rate_percent}% of requests returned a 5xx for 5 minutes in a row. Run the 'Backend errors' and '5xx by path' saved queries."
  comparison_operator = "GreaterThanThreshold"
  threshold           = local.limit.error_rate_percent
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching" # no requests means no data, and no failures
  alarm_actions       = [local.alarm_topic]
  ok_actions          = [local.alarm_topic]

  # The same formula as the dashboard panel. FILL(..., 0) matters: a 5xx metric does not exist until the first
  # 5xx, and without it the expression would have no data while everything is healthy.
  metric_query {
    id          = "e_rate"
    expression  = "100 * FILL(m_5xx, 0) / m_requests"
    label       = "5xx rate (%)"
    return_data = true
  }
  metric_query {
    id = "m_requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = local.lb }
      period      = 60
      stat        = "Sum"
    }
  }
  metric_query {
    id = "m_5xx"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = local.lb }
      period      = 60
      stat        = "Sum"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "latency_high" {
  alarm_name          = "${var.name_prefix}-api-latency-p95-high"
  alarm_description   = "The 95th percentile of how long the backend takes to answer was above ${local.limit.p95_latency_seconds} s for 10 minutes (normal is about 20 ms; the threshold was set from a measured baseline, README 'Load test and baseline'). 'Slowest paths (p95)' shows which endpoint."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { TargetGroup = local.be_tg, LoadBalancer = local.lb }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = local.limit.p95_latency_seconds
  comparison_operator = "GreaterThanThreshold"
  # A percentile of a handful of requests is noise: with too few samples the alarm keeps its state.
  evaluate_low_sample_count_percentiles = "ignore"
  treat_missing_data                    = "notBreaching" # no requests, no latency
  alarm_actions                         = [local.alarm_topic]
  ok_actions                            = [local.alarm_topic]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  for_each            = local.target_groups
  alarm_name          = "${var.name_prefix}-alb-${each.key}-unhealthy-hosts"
  alarm_description   = "At least one ${each.key} target has been unhealthy for 3 minutes in a row. A deploy that restarts the containers can show this briefly; a minute or two is normal, more is not."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { TargetGroup = each.value, LoadBalancer = local.lb }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold" # more than 0, that is, one or more
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.alarm_topic]
  ok_actions          = [local.alarm_topic]
}

# ---------- application ----------
resource "aws_cloudwatch_metric_alarm" "application_errors" {
  alarm_name          = "${var.name_prefix}-application-errors"
  alarm_description   = "The backend logged ${local.limit.application_errors} or more errors (exceptions, not request lines) in 5 minutes. Run the 'Backend errors' saved query."
  namespace           = local.app_errors_namespace
  metric_name         = local.app_errors_name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = local.limit.application_errors
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching" # no errors means no data point
  alarm_actions       = [local.alarm_topic]
  ok_actions          = [local.alarm_topic]
}

# ---------- database ----------
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${var.name_prefix}-rds-cpu-high"
  alarm_description   = "Database CPU has been above ${local.limit.rds_cpu_percent}% for 10 minutes, or RDS stopped reporting (missing data counts as breaching: the database should always publish)."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = local.db }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = local.limit.rds_cpu_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching" # a database that publishes nothing is a problem
  alarm_actions       = [local.alarm_topic]
  ok_actions          = [local.alarm_topic]
}

resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "${var.name_prefix}-rds-free-storage-low"
  alarm_description   = "Free database storage has been below ${floor(local.limit.rds_free_storage_bytes / 1073741824)} GiB for 10 minutes, or RDS stopped reporting (missing data counts as breaching)."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = local.db }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = local.limit.rds_free_storage_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # a database that publishes nothing is a problem
  alarm_actions       = [local.alarm_topic]
  ok_actions          = [local.alarm_topic]
}
