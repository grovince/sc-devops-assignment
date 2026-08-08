output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "api_sg_id" {
  value = aws_security_group.api.id
}

output "consumer_sg_id" {
  value = aws_security_group.consumer.id
}

output "msk_sg_id" {
  value = aws_security_group.msk.id
}

output "vpce_sg_id" {
  value = aws_security_group.vpce.id
}
