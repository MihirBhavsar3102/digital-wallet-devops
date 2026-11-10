output "alb_dns_name" {
  description = "DNS name of the application load balancer. Open http://<this> to reach the app."
  value       = aws_lb.this.dns_name
}

output "alb_arn_suffix" {
  description = "ARN suffix of the load balancer, used as a CloudWatch dimension by the monitoring step."
  value       = aws_lb.this.arn_suffix
}

# The two target group ARNs below wait for the listener and rule, because an Auto Scaling group
# can only register with a target group that is already attached to a load balancer.
output "frontend_target_group_arn" {
  description = "ARN of the frontend target group (port 80)."
  value       = aws_lb_target_group.frontend.arn
  depends_on  = [aws_lb_listener.http, aws_lb_listener_rule.api]
}

output "backend_target_group_arn" {
  description = "ARN of the backend target group (port 8081)."
  value       = aws_lb_target_group.backend.arn
  depends_on  = [aws_lb_listener.http, aws_lb_listener_rule.api]
}

output "frontend_target_group_arn_suffix" {
  description = "ARN suffix of the frontend target group, used as a CloudWatch dimension by the monitoring step."
  value       = aws_lb_target_group.frontend.arn_suffix
}

output "backend_target_group_arn_suffix" {
  description = "ARN suffix of the backend target group, used as a CloudWatch dimension by the monitoring step."
  value       = aws_lb_target_group.backend.arn_suffix
}

output "access_logs_bucket_name" {
  description = "Name of the S3 bucket that receives the load balancer access logs."
  value       = aws_s3_bucket.logs.id
}
