resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_db_instance" "main" {
  identifier = "${local.name}-db"

  engine = "postgres"
  # Major version only: RDS picks the latest 16.x and applies minor upgrades itself.
  # Matches postgres:16-alpine in the backend's docker-compose.yml and Testcontainers.
  engine_version = "16"
  instance_class = var.db_instance_class

  # No storage autoscaling: it's unverified on the Free plan and 20 GiB is plenty for now
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "supple"
  username = "supple"
  # RDS generates the password and keeps it in Secrets Manager (secret "rds!db-…");
  # Beanstalk passes it to the app as SPRING_DATASOURCE_PASSWORD (backend.tf)
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = var.db_backup_retention_days
  backup_window              = "01:00-01:30"
  maintenance_window         = "sun:02:00-sun:02:30"
  auto_minor_version_upgrade = true

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-db-final"
  copy_tags_to_snapshot     = true

  performance_insights_enabled = false
  monitoring_interval          = 0
}

# RDS changes the master password every 7 days by default. Beanstalk reads the secret
# only when the instance starts or the app is deployed, so after a rotation the app
# would keep the old password. Turn automatic rotation off; README.md shows how to
# change the password by hand.
resource "aws_secretsmanager_secret_rotation" "db_master" {
  secret_id        = aws_db_instance.main.master_user_secret[0].secret_arn
  rotation_enabled = false
}
