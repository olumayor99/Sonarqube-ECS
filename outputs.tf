output "lb_endpoint" {
  description = "LoadBalancer Endpoint"
  value       = module.alb.dns_name
}

# output "sonarqube_repo" {
#   description = "Sonarqube ECR repository"
#   value       = aws_ecr_repository.sonarqube.arn
# }