output "cluster_arn" {
  value = aws_msk_cluster.this.arn
}

output "cluster_name" {
  value = aws_msk_cluster.this.cluster_name
}

output "bootstrap_brokers_sasl_iam" {
  value     = aws_msk_cluster.this.bootstrap_brokers_sasl_iam
  sensitive = true
}

output "topic_arn_pattern" {
  description = "IAM 정책에서 토픽 리소스를 지정할 때 사용"
  value       = "${replace(aws_msk_cluster.this.arn, ":cluster/", ":topic/")}/*"
}

output "group_arn_pattern" {
  description = "IAM 정책에서 컨슈머 그룹 리소스를 지정할 때 사용"
  value       = "${replace(aws_msk_cluster.this.arn, ":cluster/", ":group/")}/*"
}

output "partitions" {
  description = "컨슈머 태스크 확장 상한과 동일한 값"
  value       = var.partitions
}
