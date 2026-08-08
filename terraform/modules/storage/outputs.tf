output "bucket_id" {
  value = aws_s3_bucket.logs.id
}

output "bucket_arn" {
  value = aws_s3_bucket.logs.arn
}

output "raw_prefix" {
  value = var.raw_prefix
}
