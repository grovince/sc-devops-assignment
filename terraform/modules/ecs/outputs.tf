output "cluster_name" {
  description = "ECS 클러스터 이름."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS 클러스터 ARN."
  value       = aws_ecs_cluster.this.arn
}

output "service_name" {
  description = "ECS 서비스 이름."
  value       = aws_ecs_service.api.name
}

output "task_definition_arn" {
  description = "현재 태스크 정의 리비전의 ARN."
  value       = aws_ecs_task_definition.api.arn
}

output "task_role_arn" {
  description = "애플리케이션 컨테이너가 사용하는 태스크 역할의 ARN."
  value       = aws_iam_role.task.arn
}

output "log_group_name" {
  description = "컨테이너 로그가 적재되는 CloudWatch Logs 그룹 이름."
  value       = aws_cloudwatch_log_group.api.name
}
