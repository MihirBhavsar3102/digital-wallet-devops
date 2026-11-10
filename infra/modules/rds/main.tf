locals {
  identifier = "${var.name_prefix}-db" # the IAM deploy role's snapshot permission expects exactly this name
  family     = "postgres${split(".", var.engine_version)[0]}"
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-subnets"
  subnet_ids = var.subnet_ids
}

# name_prefix with create_before_destroy: a parameter group that is in use cannot be replaced
# in place (for example when the family changes in a major version upgrade), per the provider docs.
resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name_prefix}-pg-"
  family      = local.family
  description = "PostgreSQL parameters for ${var.name_prefix}: TLS required, slow query logging"

  parameter {
    name  = "log_min_duration_statement"
    value = tostring(var.slow_query_threshold_ms)
  }

  parameter {
    name  = "rds.force_ssl"
    value = "1" # already the default on 17 and 18; explicit so it stays visible
    # AWS stores this default-valued parameter as pending-reboot and will not change its apply
    # method without changing its value (see the provider docs). With the provider's default of
    # "immediate", every plan showed a diff that could never be applied away.
    apply_method = "pending-reboot"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------- enhanced monitoring role ----------
data "aws_iam_policy_document" "monitoring_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  name               = "${var.name_prefix}-rds-monitoring-role"
  assume_role_policy = data.aws_iam_policy_document.monitoring_trust.json
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ---------- log groups ----------
# Created before the instance so they get a retention period. Left to RDS, they would never expire.
resource "aws_cloudwatch_log_group" "postgres" {
  for_each          = toset(["postgresql", "upgrade"])
  name              = "/aws/rds/instance/${local.identifier}/${each.key}"
  retention_in_days = var.log_retention_days
}

# ---------- the database ----------
resource "aws_db_instance" "this" {
  identifier     = local.identifier
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.master_username
  # RDS creates and rotates the password in Secrets Manager, so it never appears in code or in state.
  manage_master_user_password = true

  allocated_storage = var.allocated_storage
  storage_type      = "gp3" # iops and storage_throughput are left unset: gp3 rejects them at this size
  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = var.multi_az
  parameter_group_name   = aws_db_parameter_group.this.name

  backup_retention_period    = var.backup_retention_period
  backup_window              = var.backup_window
  maintenance_window         = var.maintenance_window
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-final"

  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.monitoring.arn
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  depends_on = [aws_cloudwatch_log_group.postgres, aws_iam_role_policy_attachment.monitoring]
}
