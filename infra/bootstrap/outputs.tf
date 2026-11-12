output "state_bucket_name" {
  description = "Name of the remote-state bucket; paste into each env's backend.tf."
  value       = aws_s3_bucket.tfstate.id
}

output "github_oidc_provider_arn" {
  description = "ARN of the account-wide GitHub Actions OIDC identity provider; the per-environment deploy roles trust it."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "pipeline_alerts_topic_arn" {
  description = "ARN of the SNS topic that e-mails pipeline failures; the repository variable NOTIFY_TOPIC_ARN."
  value       = aws_sns_topic.pipeline_alerts.arn
}

output "alarm_topic_arn" {
  description = "ARN of the SNS topic that e-mails the CloudWatch alarms. The environments look it up by name, so this is for information."
  value       = aws_sns_topic.alarms.arn
}

output "github_notify_role_arn" {
  description = "ARN of the role the notify jobs assume to publish to that topic; the repository variable NOTIFY_ROLE_ARN."
  value       = aws_iam_role.github_notify.arn
}
