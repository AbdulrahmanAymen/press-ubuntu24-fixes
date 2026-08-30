terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# AMI lookup — always resolves to the latest official Ubuntu 24.04 (Noble) LTS
# ---------------------------------------------------------------------------
data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# Existing key pair — this does NOT create a new key, it references the one
# you already uploaded to AWS (the .pem file you already have and use daily).
# ---------------------------------------------------------------------------
data "aws_key_pair" "existing" {
  key_name = var.key_pair_name
}

# ---------------------------------------------------------------------------
# Default VPC / subnet — reuses whatever your account already has, so this
# doesn't try to build custom networking on top of your existing setup.
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

# ---------------------------------------------------------------------------
# Security Group — one shared group, with self-referencing rules so the 4
# servers can always reach each other, plus the public ports each role needs.
# See the guide's "Security Group Checklist" appendix for the reasoning.
# ---------------------------------------------------------------------------
resource "aws_security_group" "press_cluster" {
  name        = "${var.project_name}-press-cluster"
  description = "Press cluster: press, n1 (proxy), m1 (db), f1 (build)"
  vpc_id      = data.aws_vpc.default.id

  # SSH — only from your own IP
  ingress {
    description = "SSH from admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_ssh_cidr]
  }

  # HTTP/HTTPS — public, needed on press (dashboard) and n1 (proxy/tenant sites)
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Internal cluster traffic — any server in this same SG can reach any other
  # on any port (MySQL 3306, agent ports, etc.), without opening them publicly.
  ingress {
    description = "Internal cluster traffic (self-reference)"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-press-cluster"
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# The 4 servers
# ---------------------------------------------------------------------------
locals {
  servers = {
    press = { volume_gb = var.root_volume_size_gb }
    n1    = { volume_gb = var.root_volume_size_gb }
    m1    = { volume_gb = var.root_volume_size_gb }
    f1    = { volume_gb = var.f1_volume_size_gb }
  }
}

resource "aws_instance" "server" {
  for_each = local.servers

  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = var.instance_type
  key_name               = data.aws_key_pair.existing.key_name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.press_cluster.id]

  root_block_device {
    volume_size = each.value.volume_gb
    volume_type = "gp3"
  }

  tags = {
    Name    = "${var.project_name}-${each.key}"
    Role    = each.key
    Project = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Elastic IPs — one per server, associated immediately. This is the fix for
# the "public IP changes on stop/start" problem flagged in the guide.
# ---------------------------------------------------------------------------
resource "aws_eip" "server" {
  for_each = local.servers

  instance = aws_instance.server[each.key].id
  domain   = "vpc"

  tags = {
    Name    = "${var.project_name}-${each.key}-eip"
    Project = var.project_name
  }
}
