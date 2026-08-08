output "alb_arn" {
  description = "Application Load Balancer의 ARN."
  value       = aws_lb.this.arn
}

output "alb_dns_name" {
  description = "ALB의 퍼블릭 DNS 이름."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "ALB의 호스팅 영역 ID. Route 53 alias 레코드에 사용된다."
  value       = aws_lb.this.zone_id
}

output "target_group_arn" {
  description = "API 타깃 그룹의 ARN."
  value       = aws_lb_target_group.api.arn
}

output "listener_arn" {
  description = "HTTP 리스너의 ARN."
  value       = aws_lb_listener.http.arn
}

output "alb_arn_suffix" {
  description = "ALB의 ARN suffix. app/<name>/<id> 형식."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  description = "타깃 그룹의 ARN suffix. targetgroup/<name>/<id> 형식."
  value       = aws_lb_target_group.api.arn_suffix
}
