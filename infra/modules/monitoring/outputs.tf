output "agent_config_parameter_name" {
  description = "Name of the Parameter Store parameter that holds the CloudWatch agent's configuration. The instances fetch it at boot."
  value       = aws_ssm_parameter.agent_config.name
}

output "log_group_names" {
  description = "Names of the application and system log groups, keyed by kind (backend, frontend, syslog, auth)."
  value       = { for kind, group in aws_cloudwatch_log_group.app : kind => group.name }
}
