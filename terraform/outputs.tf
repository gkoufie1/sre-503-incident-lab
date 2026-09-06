output "alb_dns_name" {
  description = "Point Cloudflare's CNAME at this"
  value       = aws_lb.this.dns_name
}

output "ec2_public_ip" {
  value = aws_instance.backend.public_ip
}

output "ssh_command" {
  value = "ssh -i ../${var.project_name}-key.pem ec2-user@${aws_instance.backend.public_ip}"
}

output "target_group_arn" {
  value = aws_lb_target_group.backend.arn
}
