output "alb_sg_id" {
  description = "ALB 보안 그룹 ID."
  value       = aws_security_group.alb.id
}

output "ecs_tasks_sg_id" {
  description = "ECS Fargate 태스크 보안 그룹 ID."
  value       = aws_security_group.ecs_tasks.id
}

output "web_acl_arn" {
  description = "WAFv2 Web ACL의 ARN. alb 모듈이 association에 사용한다."
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  description = "WAFv2 Web ACL의 ID."
  value       = aws_wafv2_web_acl.this.id
}
