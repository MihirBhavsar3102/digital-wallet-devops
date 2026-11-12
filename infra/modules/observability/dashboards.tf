data "aws_region" "current" {}

# Two dashboards, as Terraform, so that destroying and rebuilding an environment rebuilds them too.
#   <name_prefix>-infrastructure: the instances and the database ("is anything running out of room?")
#   <name_prefix>-application:    traffic, errors, latency and logs ("is it working for the people using it?")
# Every panel is titled as the question it answers. Where there is an alarm, its threshold is drawn on the panel
# as a horizontal line, from the same variable the alarm uses. All panels share one default time range (3 hours)
# and a 60 second period, except the EC2 metrics, which AWS publishes every 5 minutes (period 300 on those).
# The metric names and dimensions are the ones read from CloudWatch on live staging (README, "Metrics").
locals {
  region = data.aws_region.current.region
  asg    = var.autoscaling_group_name
  lb     = var.alb_arn_suffix
  be_tg  = var.backend_target_group_arn_suffix
  fe_tg  = var.frontend_target_group_arn_suffix
  db     = var.db_instance_identifier
  limit  = var.alarm_thresholds

  app_errors_namespace = var.application_errors_metric.namespace
  app_errors_name      = var.application_errors_metric.name
  backend_log_group    = var.log_group_names["backend"]

  red    = "#d62728"
  orange = "#ff7f0e"
  green  = "#2ca02c"
  blue   = "#1f77b4"

  # What every metric panel has in common.
  line_chart = {
    view    = "timeSeries"
    stacked = false
    region  = local.region
    period  = 60
  }
  # EC2's own metrics (basic monitoring) have one data point every 5 minutes.
  ec2_chart = merge(local.line_chart, { period = 300 })

  percent_axis = { left = { min = 0, max = 100 } }
  count_axis   = { left = { min = 0 } }

  # ---------- Dashboard 1: infrastructure and database ----------
  infrastructure_widgets = [
    {
      type       = "text", x = 0, y = 0, width = 24, height = 1
      properties = { markdown = "## EC2 instances (the Auto Scaling group `${local.asg}`). CPU, memory and disk come from the CloudWatch agent, one point a minute." }
    },
    {
      type = "metric", x = 0, y = 1, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "Are the instances busy? CPU used (%)"
        metrics = [
          ["CWAgent", "cpu_usage_active", "AutoScalingGroupName", local.asg, { stat = "Average", label = "average", color = local.blue }],
          ["CWAgent", "cpu_usage_active", "AutoScalingGroupName", local.asg, { stat = "Maximum", label = "busiest instance", color = local.orange }],
        ]
        annotations = { horizontal = [{ label = "alarm at ${local.limit.cpu_percent}%", value = local.limit.cpu_percent, color = local.red }] }
        yAxis       = local.percent_axis
      })
    },
    {
      type = "metric", x = 12, y = 1, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "Is memory running out? Memory used (%)"
        metrics = [
          ["CWAgent", "mem_used_percent", "AutoScalingGroupName", local.asg, { stat = "Average", label = "average", color = local.blue }],
          ["CWAgent", "mem_used_percent", "AutoScalingGroupName", local.asg, { stat = "Maximum", label = "highest instance", color = local.orange }],
        ]
        annotations = { horizontal = [{ label = "alarm at ${local.limit.memory_percent}%", value = local.limit.memory_percent, color = local.red }] }
        yAxis       = local.percent_axis
      })
    },
    {
      type = "metric", x = 0, y = 7, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "Is the disk filling up? Root disk used (%)"
        metrics = [
          ["CWAgent", "disk_used_percent", "AutoScalingGroupName", local.asg, { stat = "Average", label = "average", color = local.blue }],
          ["CWAgent", "disk_used_percent", "AutoScalingGroupName", local.asg, { stat = "Maximum", label = "fullest instance", color = local.orange }],
        ]
        annotations = { horizontal = [{ label = "alarm at ${local.limit.disk_percent}%", value = local.limit.disk_percent, color = local.red }] }
        yAxis       = local.percent_axis
      })
    },
    {
      type = "metric", x = 12, y = 7, width = 12, height = 6
      properties = merge(local.ec2_chart, {
        title = "How much data moves in and out? (bytes per 5 minutes)"
        metrics = [
          ["AWS/EC2", "NetworkIn", "AutoScalingGroupName", local.asg, { stat = "Sum", label = "in", color = local.blue }],
          ["AWS/EC2", "NetworkOut", "AutoScalingGroupName", local.asg, { stat = "Sum", label = "out", color = local.orange }],
        ]
        yAxis = local.count_axis
      })
    },
    {
      type = "metric", x = 0, y = 13, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "How many instances are serving traffic?"
        metrics = [
          ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", local.asg, { stat = "Average", label = "in service", color = local.green }],
          ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", local.asg, { stat = "Average", label = "wanted", color = local.blue }],
        ]
        yAxis = local.count_axis
      })
    },
    {
      type = "metric", x = 12, y = 13, width = 12, height = 6
      properties = merge(local.ec2_chart, {
        title = "Are the instances passing EC2's own health checks? (failed checks)"
        metrics = [
          ["AWS/EC2", "StatusCheckFailed", "AutoScalingGroupName", local.asg, { stat = "Maximum", label = "failed checks", color = local.red }],
        ]
        yAxis = local.count_axis
      })
    },
    {
      type       = "text", x = 0, y = 19, width = 24, height = 1
      properties = { markdown = "## Database (RDS PostgreSQL `${local.db}`)" }
    },
    {
      type = "metric", x = 0, y = 20, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "Is the database busy? CPU used (%)"
        metrics = [
          ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", local.db, { stat = "Average", label = "CPU", color = local.blue }],
        ]
        annotations = { horizontal = [{ label = "alarm at ${local.limit.rds_cpu_percent}%", value = local.limit.rds_cpu_percent, color = local.red }] }
        yAxis       = local.percent_axis
      })
    },
    {
      type = "metric", x = 12, y = 20, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "How many connections are open?"
        metrics = [
          ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", local.db, { stat = "Average", label = "average", color = local.blue }],
          ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", local.db, { stat = "Maximum", label = "highest", color = local.orange }],
        ]
        yAxis = local.count_axis
      })
    },
    {
      type = "metric", x = 0, y = 26, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "Is the database short of memory? Freeable memory (bytes)"
        metrics = [
          ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", local.db, { stat = "Average", label = "average", color = local.blue }],
          ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", local.db, { stat = "Minimum", label = "lowest", color = local.orange }],
        ]
        yAxis = local.count_axis
      })
    },
    {
      type = "metric", x = 12, y = 26, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "How much storage is left? Free storage (bytes)"
        metrics = [
          ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", local.db, { stat = "Minimum", label = "free", color = local.blue }],
        ]
        annotations = { horizontal = [{ label = "alarm below 2 GiB", value = local.limit.rds_free_storage_bytes, color = local.red }] }
        yAxis       = local.count_axis
      })
    },
    {
      type = "metric", x = 0, y = 32, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "How much I/O is the database doing? (operations per second)"
        metrics = [
          ["AWS/RDS", "ReadIOPS", "DBInstanceIdentifier", local.db, { stat = "Average", label = "reads", color = local.blue }],
          ["AWS/RDS", "WriteIOPS", "DBInstanceIdentifier", local.db, { stat = "Average", label = "writes", color = local.orange }],
        ]
        yAxis = local.count_axis
      })
    },
    {
      type = "metric", x = 12, y = 32, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "How long do reads and writes take? (seconds)"
        metrics = [
          ["AWS/RDS", "ReadLatency", "DBInstanceIdentifier", local.db, { stat = "Average", label = "read", color = local.blue }],
          ["AWS/RDS", "WriteLatency", "DBInstanceIdentifier", local.db, { stat = "Average", label = "write", color = local.orange }],
        ]
        yAxis = local.count_axis
      })
    },
    {
      type = "metric", x = 0, y = 38, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "Is I/O queuing up? Disk queue depth"
        metrics = [
          ["AWS/RDS", "DiskQueueDepth", "DBInstanceIdentifier", local.db, { stat = "Average", label = "average", color = local.blue }],
          ["AWS/RDS", "DiskQueueDepth", "DBInstanceIdentifier", local.db, { stat = "Maximum", label = "highest", color = local.orange }],
        ]
        yAxis = local.count_axis
      })
    },
    {
      type = "metric", x = 12, y = 38, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "How busy is the database overall? Average active sessions (Performance Insights)"
        metrics = [
          ["AWS/RDS", "DBLoad", "DBInstanceIdentifier", local.db, { stat = "Average", label = "active sessions", color = local.blue }],
        ]
        yAxis = local.count_axis
      })
    },
  ]

  # ---------- Dashboard 2: application and traffic ----------
  application_widgets = [
    {
      type       = "text", x = 0, y = 0, width = 24, height = 2
      properties = { markdown = "## Traffic and errors, as the load balancer sees them\nThese are measured at the edge: request counts, status codes, and how long the target took to answer. They say nothing about time spent inside the code. The application's own errors are the last panel in this block." }
    },
    {
      type = "metric", x = 0, y = 2, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "How much traffic is there? (requests per minute)"
        metrics = [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.lb, { stat = "Sum", label = "requests", color = local.blue }],
        ]
        yAxis = local.count_axis
      })
    },
    {
      type = "metric", x = 12, y = 2, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "What is being returned? (responses per minute, by class)"
        metrics = [
          ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", local.lb, { stat = "Sum", label = "2xx success", color = local.green }],
          ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", local.lb, { stat = "Sum", label = "4xx caller's mistake", color = local.orange }],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.lb, { stat = "Sum", label = "5xx our failure", color = local.red }],
        ]
        yAxis = local.count_axis
      })
    },
    {
      # A 5xx metric does not exist until the first 5xx, so FILL(..., 0) is what keeps this panel (and the
      # alarm on the same expression) at 0 instead of "no data" while everything is healthy.
      type = "metric", x = 0, y = 8, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "What share of requests fail? 5xx rate (%)"
        metrics = [
          [{ expression = "100 * FILL(m_5xx, 0) / m_requests", label = "5xx rate (%)", id = "e_rate", color = local.red }],
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.lb, { stat = "Sum", id = "m_requests", visible = false }],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.lb, { stat = "Sum", id = "m_5xx", visible = false }],
        ]
        annotations = { horizontal = [{ label = "alarm at ${local.limit.error_rate_percent}%", value = local.limit.error_rate_percent, color = local.red }] }
        yAxis       = { left = { min = 0 } }
      })
    },
    {
      type = "metric", x = 12, y = 8, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "How long does the API take to answer? (seconds, backend target)"
        metrics = [
          ["AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", local.be_tg, "LoadBalancer", local.lb, { stat = "p50", label = "p50 (typical)", color = local.green }],
          ["AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", local.be_tg, "LoadBalancer", local.lb, { stat = "p95", label = "p95", color = local.orange }],
          ["AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", local.be_tg, "LoadBalancer", local.lb, { stat = "p99", label = "p99 (slowest 1%)", color = local.red }],
        ]
        annotations = { horizontal = [{ label = "p95 alarm at ${local.limit.p95_latency_seconds} s", value = local.limit.p95_latency_seconds, color = local.red }] }
        yAxis       = local.count_axis
      })
    },
    {
      type = "metric", x = 0, y = 14, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "Are the targets healthy? (hosts behind the load balancer)"
        metrics = [
          ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", local.be_tg, "LoadBalancer", local.lb, { stat = "Minimum", label = "backend healthy", color = local.green }],
          ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", local.be_tg, "LoadBalancer", local.lb, { stat = "Maximum", label = "backend unhealthy", color = local.red }],
          ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", local.fe_tg, "LoadBalancer", local.lb, { stat = "Minimum", label = "frontend healthy", color = local.blue }],
          ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", local.fe_tg, "LoadBalancer", local.lb, { stat = "Maximum", label = "frontend unhealthy", color = local.orange }],
        ]
        yAxis = local.count_axis
      })
    },
    {
      type = "metric", x = 12, y = 14, width = 12, height = 6
      properties = merge(local.line_chart, {
        title = "Is the application logging errors? (error lines per minute, from the backend log)"
        metrics = [
          [local.app_errors_namespace, local.app_errors_name, { stat = "Sum", label = "errors", color = local.red }],
        ]
        annotations = { horizontal = [{ label = "alarm at ${local.limit.application_errors} in 5 minutes", value = local.limit.application_errors, color = local.red }] }
        yAxis       = local.count_axis
      })
    },
    {
      type       = "text", x = 0, y = 20, width = 24, height = 1
      properties = { markdown = "## What is going wrong? (Logs Insights on the backend log, over the dashboard's time range)" }
    },
    {
      type = "log", x = 0, y = 21, width = 24, height = 7
      properties = {
        title  = "What went wrong most recently? (error lines)"
        region = local.region
        view   = "table"
        query  = "SOURCE '${local.backend_log_group}'\n| ${local.queries.backend_errors}"
      }
    },
    {
      type = "log", x = 0, y = 28, width = 12, height = 7
      properties = {
        title  = "Which endpoints are slowest? (p95, in milliseconds)"
        region = local.region
        view   = "table"
        query  = "SOURCE '${local.backend_log_group}'\n| ${local.queries.slowest_paths}"
      }
    },
    {
      type = "log", x = 12, y = 28, width = 12, height = 7
      properties = {
        title  = "Which endpoints fail? (4xx and 5xx, by path)"
        region = local.region
        view   = "table"
        query  = "SOURCE '${local.backend_log_group}'\n| ${local.queries.failed_paths}"
      }
    },
  ]
}

resource "aws_cloudwatch_dashboard" "infrastructure" {
  dashboard_name = "${var.name_prefix}-infrastructure"
  dashboard_body = jsonencode({
    start          = "-PT3H"
    periodOverride = "inherit"
    widgets        = local.infrastructure_widgets
  })
}

resource "aws_cloudwatch_dashboard" "application" {
  dashboard_name = "${var.name_prefix}-application"
  dashboard_body = jsonencode({
    start          = "-PT3H"
    periodOverride = "inherit"
    widgets        = local.application_widgets
  })
}
