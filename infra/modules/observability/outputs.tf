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

output "saved_query_names" {
  description = "Names of the saved Logs Insights queries."
  value       = sort([for q in aws_cloudwatch_query_definition.saved : q.name])
}
