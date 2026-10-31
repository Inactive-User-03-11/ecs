resource "aws_rds_cluster" "db" {
  cluster_identifier                  = var.name
  engine                              = "aurora-postgresql"
  engine_version                      = var.aurora_engine_version
  database_name                       = "calls"
  master_username                     = "dbadmin"
  manage_master_user_password         = true # admin password created and held by RDS in Secrets Manager
  iam_database_authentication_enabled = true # the app logs in with IAM tokens
  enable_http_endpoint                = true # Data API, used below to run init.sql
  storage_encrypted                   = true
  backup_retention_period             = 7
  deletion_protection                 = true
  final_snapshot_identifier           = "${var.name}-final"
  db_subnet_group_name                = aws_db_subnet_group.main.name
  vpc_security_group_ids              = [aws_security_group.db.id]

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 8
  }
}

resource "aws_rds_cluster_instance" "db" {
  count              = 2 # writer + reader in different AZs
  identifier         = "${var.name}-${count.index}"
  cluster_identifier = aws_rds_cluster.db.id
  engine             = aws_rds_cluster.db.engine
  engine_version     = aws_rds_cluster.db.engine_version
  instance_class     = "db.serverless"
}

# Runs init.sql through the RDS Data API (no network path to the DB needed).
# Re-runs only when init.sql changes.
resource "null_resource" "db_init" {
  depends_on = [aws_rds_cluster_instance.db]
  triggers   = { sql = filesha1("${path.module}/init.sql") }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        aws rds-data execute-statement --region ${var.region} \
          --resource-arn ${aws_rds_cluster.db.arn} \
          --secret-arn ${aws_rds_cluster.db.master_user_secret[0].secret_arn} \
          --database calls --sql "$line" > /dev/null
      done < ${path.module}/init.sql
    EOT
  }
}