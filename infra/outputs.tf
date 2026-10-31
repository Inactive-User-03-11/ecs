output "alb_dns" {
  description = "Create a CNAME from your webhook hostname to this value"
  value       = aws_lb.app.dns_name
}

output "image_deployed" {
  value = "${var.image_repo}:${var.image_tag}"
}

output "db_endpoint" {
  value = aws_rds_cluster.db.endpoint
}