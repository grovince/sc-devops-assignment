output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "api_service_name" {
  value = aws_ecs_service.api.name
}

output "consumer_service_name" {
  value = aws_ecs_service.consumer.name
}

output "api_task_role_arn" {
  value = aws_iam_role.api_task.arn
}

output "consumer_task_role_arn" {
  value = aws_iam_role.consumer_task.arn
}

output "consumer_max_capacity" {
  description = "파티션 수와 동일. 초과 시 유휴 태스크가 발생한다"
  value       = aws_appautoscaling_target.consumer.max_capacity
}
