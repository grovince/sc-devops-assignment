output "dns_name" {
  description = "로그 수집 엔드포인트. POST /api/v1/logs"
  value       = aws_lb.this.dns_name
}

output "zone_id" {
  value = aws_lb.this.zone_id
}

output "target_group_arn" {
  value = aws_lb_target_group.api.arn
}

output "arn_suffix" {
  description = "ALBRequestCountPerTarget 오토스케일링의 resource_label 구성에 사용"
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.api.arn_suffix
}

output "https_listener_arn" {
  description = "ECS 서비스의 depends_on 대상"
  value       = aws_lb_listener.https.arn
}
