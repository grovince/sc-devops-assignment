output "kinesis_stream_arn" {
  description = "Kinesis Data Stream의 ARN."
  value       = aws_kinesis_stream.logs.arn
}

output "kinesis_stream_name" {
  description = "Kinesis Data Stream의 이름."
  value       = aws_kinesis_stream.logs.name
}

output "firehose_name" {
  description = "Firehose 전송 스트림의 이름."
  value       = aws_kinesis_firehose_delivery_stream.logs.name
}

output "log_bucket_name" {
  description = "게임 로그가 적재되는 S3 버킷 이름."
  value       = aws_s3_bucket.logs.bucket
}

output "log_bucket_arn" {
  description = "게임 로그 S3 버킷의 ARN."
  value       = aws_s3_bucket.logs.arn
}
