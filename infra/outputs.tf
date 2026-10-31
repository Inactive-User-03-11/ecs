output "alb_dns" {
  value = aws_lb.app.dns_name
}

output "webhook_url" {
  description = "Give this URL to the voice platform"
  value       = "http://${aws_lb.app.dns_name}/webhook/call-completed"
}

output "image_deployed" {
  value = "${var.image_repo}:${var.image_tag}"
}

output "db_endpoint" {
  value = aws_rds_cluster.db.endpoint
}