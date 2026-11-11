data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# The provider's default tags (project, environment, managed-by, owner). Instances launched by an
# Auto Scaling group do not inherit default_tags, so they are re-applied explicitly below.
data "aws_default_tags" "this" {}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical, as given in Ubuntu's AWS documentation
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  instance_tags = merge(data.aws_default_tags.this.tags, {
    Name = "${var.name_prefix}-app"
    Role = "app" # what SSM Run Command targets
  })
}

# The tag of the last release that passed its smoke test. The pipeline writes it (cd.yml, after the smoke
# test) and a new instance reads it at boot (user_data), so a replacement instance converges to the last
# good version instead of staying on the placeholder. Terraform creates it so that it exists before the
# first deploy and is destroyed with the environment: a rebuilt environment has empty ECR repositories,
# so a surviving tag would point at an image that no longer exists. The value belongs to the pipeline.
# The name is also built in the iam module (the permissions on it): keep the two in step.
resource "aws_ssm_parameter" "deployed_tag" {
  #checkov:skip=CKV2_AWS_34:An image tag is not a secret, so SecureString would only add a key permission to every reader.
  name  = "/${var.name_prefix}/deployed-tag"
  type  = "String"
  value = "none" # "none" means nothing has been deployed yet
  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_launch_template" "app" {
  name                   = "${var.name_prefix}-app-lt"
  image_id               = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [var.security_group_id]
  update_default_version = true
  # No key_name on purpose: there is no SSH. Access goes through SSM.

  iam_instance_profile {
    name = var.instance_profile_name
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
    # 1 keeps the metadata service (and the role's credentials) out of reach of containers. deploy.sh runs
    # on the host and passes secrets in as environment variables, so no container needs AWS credentials.
    # Raise it to 2 only if a container ever has to call AWS with the instance role.
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/sda1" # Ubuntu's root device, checked on the AMI
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region            = data.aws_region.current.region
    account_id        = data.aws_caller_identity.current.account_id
    name_prefix       = var.name_prefix
    frontend_port     = var.frontend_port
    backend_port      = var.backend_port
    db_host           = var.db_host
    db_port           = var.db_port
    db_name           = var.db_name
    db_secret_arn     = var.db_secret_arn
    deploy_script_b64 = base64encode(file("${path.module}/../../../scripts/deploy.sh"))
  }))

  tag_specifications {
    resource_type = "volume"
    tags          = local.instance_tags
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "${var.name_prefix}-app-asg"
  min_size                  = var.min_size
  desired_capacity          = var.desired_capacity
  max_size                  = var.max_size
  vpc_zone_identifier       = var.subnet_ids
  health_check_type         = "ELB"
  health_check_grace_period = var.health_check_grace_period
  target_group_arns         = var.target_group_arns

  # Do not also create an aws_autoscaling_attachment: the provider docs say it conflicts
  # with target_group_arns.
  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version # not "$Latest", so edits trigger the refresh
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  dynamic "tag" {
    for_each = local.instance_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}
