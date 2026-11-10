output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}
output "availability_zones" {
  description = "The two AZs in use, in subnet order."
  value       = local.azs
}
output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, NAT), one per AZ."
  value       = aws_subnet.public[*].id
}
output "private_app_subnet_ids" {
  description = "Private app subnet IDs (EC2), one per AZ."
  value       = aws_subnet.private_app[*].id
}
output "private_db_subnet_ids" {
  description = "Private db subnet IDs (RDS), one per AZ."
  value       = aws_subnet.private_db[*].id
}