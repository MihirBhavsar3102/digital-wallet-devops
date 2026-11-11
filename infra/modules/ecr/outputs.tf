output "repository_urls" {
  description = "Repository URL per name (frontend, backend), used by the pipeline to push."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}
output "repository_arns" {
  description = "Repository ARN per name, used to scope IAM permissions."
  value       = { for k, r in aws_ecr_repository.this : k => r.arn }
}