output "autoscaling_group_name" {
  description = "Name of the Auto Scaling group running the app instances."
  value       = aws_autoscaling_group.app.name
}

output "launch_template_id" {
  description = "ID of the launch template the app instances are created from."
  value       = aws_launch_template.app.id
}

output "ami_id" {
  description = "ID of the Ubuntu AMI the launch template currently uses."
  value       = data.aws_ami.ubuntu.id
}
