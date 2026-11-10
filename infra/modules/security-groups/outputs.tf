output "alb_security_group_id" {
  description = "ID of the load balancer security group (public HTTP in, app tier out)."
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "ID of the app tier security group (traffic from the load balancer only, no SSH)."
  value       = aws_security_group.app.id
}

output "db_security_group_id" {
  description = "ID of the database security group (PostgreSQL from the app tier only)."
  value       = aws_security_group.db.id
}
