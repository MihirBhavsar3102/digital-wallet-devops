output "agent_config_parameter_name" {
  description = "Name of the Parameter Store parameter that holds the CloudWatch agent's configuration. The instances fetch it at boot."
  value       = aws_ssm_parameter.agent_config.name
}

output "application_errors_metric" {
  description = "Namespace and name of the custom metric that counts application error log lines (used by the dashboards and alarms)."
  value = {
    namespace = local.application_metric_namespace
    name      = aws_cloudwatch_log_metric_filter.application_errors.metric_transformation[0].name
  }
}

output "log_group_names" {
  description = "Names of the application and system log groups, keyed by kind (backend, frontend, syslog, auth)."
  value       = { for kind, group in aws_cloudwatch_log_group.app : kind => group.name }
}
