output "state_bucket_name" {
  description = "Name of the remote-state bucket; paste into each env's backend.tf."
  value       = aws_s3_bucket.tfstate.id
}