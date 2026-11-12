output "dashboard_names" {
  description = "Names of the two CloudWatch dashboards, keyed by kind (infrastructure, application)."
  value = {
    infrastructure = aws_cloudwatch_dashboard.infrastructure.dashboard_name
    application    = aws_cloudwatch_dashboard.application.dashboard_name
  }
}

output "dashboard_urls" {
  description = "Console links to the two dashboards, keyed by kind."
  value = {
    infrastructure = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards:name=${aws_cloudwatch_dashboard.infrastructure.dashboard_name}"
    application    = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards:name=${aws_cloudwatch_dashboard.application.dashboard_name}"
  }
}

output "alarm_names" {
  description = "Names of every alarm this module creates."
  value = sort(concat(
    [for a in aws_cloudwatch_metric_alarm.unhealthy_hosts : a.alarm_name],
    [
      aws_cloudwatch_metric_alarm.cpu_high.alarm_name,
      aws_cloudwatch_metric_alarm.memory_high.alarm_name,
      aws_cloudwatch_metric_alarm.disk_high.alarm_name,
      aws_cloudwatch_metric_alarm.error_rate_high.alarm_name,
      aws_cloudwatch_metric_alarm.latency_high.alarm_name,
      aws_cloudwatch_metric_alarm.application_errors.alarm_name,
      aws_cloudwatch_metric_alarm.rds_cpu_high.alarm_name,
      aws_cloudwatch_metric_alarm.rds_storage_low.alarm_name,
    ],
  ))
}

output "saved_query_names" {
  description = "Names of the saved Logs Insights queries."
  value       = sort([for q in aws_cloudwatch_query_definition.saved : q.name])
}
