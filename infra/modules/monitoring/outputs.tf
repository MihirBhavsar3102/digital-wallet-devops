output "log_group_names" {
  description = "Names of the application and system log groups, keyed by kind (backend, frontend, syslog, auth)."
  value       = { for kind, group in aws_cloudwatch_log_group.app : kind => group.name }
}
