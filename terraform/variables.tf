variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "sre-503-lab"
}

variable "instance_type" {
  description = "t3.micro is free-tier eligible; cheap regardless if not."
  type        = string
  default     = "t3.micro"
}
