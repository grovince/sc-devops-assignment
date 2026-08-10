output "alb_dns_name" {
  description = "ALB의 퍼블릭 DNS 이름."
  value       = aws_lb.this.dns_name
}

output "target_group_arn" {
  description = "API 타깃 그룹의 ARN."
  value       = aws_lb_target_group.api.arn
}

output "alb_arn_suffix" {
  description = "ALB의 ARN suffix. app/<name>/<id> 형식."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  description = "타깃 그룹의 ARN suffix. targetgroup/<name>/<id> 형식."
  value       = aws_lb_target_group.api.arn_suffix
}

output "target_group_label" {
  description = "오토스케일링 resource_label에 사용할 식별자"
  value       = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.api.arn_suffix}"
}