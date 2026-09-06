data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Reuse the default VPC — this exercise is about ALB/Target Group/EC2
# troubleshooting, not VPC design, and it avoids a NAT Gateway entirely
# (everything sits in public subnets with public IPs).
# ---------------------------------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Your current public IP, so SSH is scoped to you, not the world.
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  my_ip = "${trimspace(data.http.my_ip.response_body)}/32"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb"
  description = "Allow HTTP from anywhere - this is the public entrypoint"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from anywhere (Cloudflare and direct)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "backend" {
  name        = "${var.project_name}-backend"
  description = "Only the ALB can reach the app port; only you can SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "App port, only from the ALB security group"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH, only from your current IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# The backend EC2 instance
# ---------------------------------------------------------------------------

resource "aws_instance" "backend" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.backend.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.backend.key_name

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    app_py = file("${path.module}/../app/app.py")
  })

  tags = {
    Name = "${var.project_name}-backend"
  }
}

resource "tls_private_key" "backend" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "backend" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.backend.public_key_openssh
}

# Written locally so you can load it into MobaXterm. Private key material —
# gitignored, never committed.
resource "local_file" "private_key" {
  filename        = "${path.module}/../${var.project_name}-key.pem"
  content         = tls_private_key.backend.private_key_pem
  file_permission = "0600"
}

# ---------------------------------------------------------------------------
# ALB + Target Group + Listener
# ---------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = var.project_name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "backend" {
  name     = "${var.project_name}-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
    timeout             = 5
    matcher             = "200"
  }
}

resource "aws_lb_target_group_attachment" "backend" {
  target_group_arn = aws_lb_target_group.backend.arn
  target_id         = aws_instance.backend.id
  port              = 8080
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}
