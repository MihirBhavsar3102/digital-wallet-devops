output "state_bucket_name" {
  description = "Name of the remote-state bucket; paste into each env's backend.tf."
  value       = aws_s3_bucket.tfstate.id
}

output "github_oidc_provider_arn" {
  description = "ARN of the account-wide GitHub Actions OIDC identity provider; the per-environment deploy roles trust it."
  value       = aws_iam_openid_connect_provider.github.arn
}
