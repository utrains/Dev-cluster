output "region" {
  value = var.region
}

output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority_data" {
  value     = aws_eks_cluster.main.certificate_authority[0].data
  sensitive = true
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "rds_endpoint" {
  description = "Host:port of the shared RDS instance"
  value       = aws_db_instance.main.endpoint
}

output "rds_address" {
  description = "Host only (no port) of the shared RDS instance"
  value       = aws_db_instance.main.address
}

output "rds_port" {
  value = aws_db_instance.main.port
}

output "rds_master_username" {
  value = aws_db_instance.main.username
}

output "rds_master_password" {
  value     = random_password.rds_master.result
  sensitive = true
}

output "lab_domain" {
  description = "Domain all lab app URLs live under, e.g. <app>.<lab_domain>"
  value       = var.dns_zone_name
}

output "team_readonly_kubeconfig" {
  description = "Shared read-only kubeconfig for teammates (holds a token: share privately)"
  value       = abspath(local_sensitive_file.team_readonly_kubeconfig.filename)
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN for the shared ALB's HTTPS listener, consumed by scripts/setup.sh. Looked up or passed in -- never created here, see acm.tf"
  value       = local.acm_certificate_arn
}

output "alb_controller_role_arn" {
  description = "IAM role ARN for the aws-load-balancer-controller service account (IRSA), consumed by scripts/setup.sh"
  value       = aws_iam_role.alb_controller.arn
}

output "ecr_repository_urls" {
  description = "Map of app image name to ECR repository URL, consumed by scripts/setup.sh"
  value = {
    "ecommerce-frontend"       = aws_ecr_repository.ecommerce_frontend.repository_url
    "ecommerce-backend"        = aws_ecr_repository.ecommerce_backend.repository_url
    "banking-frontend"         = aws_ecr_repository.banking_frontend.repository_url
    "banking-backend"          = aws_ecr_repository.banking_backend.repository_url
    "food-delivery-frontend"   = aws_ecr_repository.food_delivery_frontend.repository_url
    "food-delivery-backend"    = aws_ecr_repository.food_delivery_backend.repository_url
    "student-portal-frontend"  = aws_ecr_repository.student_portal_frontend.repository_url
    "student-portal-backend"   = aws_ecr_repository.student_portal_backend.repository_url
    "support-tickets-frontend" = aws_ecr_repository.support_tickets_frontend.repository_url
    "support-tickets-backend"  = aws_ecr_repository.support_tickets_backend.repository_url
  }
}
