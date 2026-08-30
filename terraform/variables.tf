variable "aws_region" {
  description = "AWS region to deploy into. ECR Public login/tokens are always us-east-1 regardless of this."
  type        = string
  default     = "us-east-1"
}

variable "key_pair_name" {
  description = "Name of the EXISTING AWS key pair (already uploaded to AWS) used to SSH into all 4 servers."
  type        = string
  default     = "key_test_erp"
}

variable "instance_type" {
  description = "EC2 instance type for all 4 servers."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size (GB) for press, n1, and m1."
  type        = number
  default     = 30
}

variable "f1_volume_size_gb" {
  description = "Root EBS volume size (GB) for f1 (build server needs more room for Docker layers)."
  type        = number
  default     = 50
}

variable "admin_ssh_cidr" {
  description = "Your IP address (as a CIDR, e.g. 1.2.3.4/32) allowed to SSH into the press server. Use 0.0.0.0/0 only for quick testing — not recommended long-term."
  type        = string
}

variable "project_name" {
  description = "Prefix used to tag/name all resources, e.g. 'presstest'."
  type        = string
  default     = "presstest"
}
