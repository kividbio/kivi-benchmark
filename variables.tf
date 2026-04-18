variable "aws_region" {
  description = "Region where c7gn is available (e.g. us-east-1, us-west-2)."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix for resource names."
  type        = string
  default     = "kividb-benchmark"
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH (create in EC2 console or via aws ec2 import-key-pair)."
  type        = string
}

variable "ssh_cidr" {
  description = "CIDR allowed to SSH (port 22) to both instances. Restrict to your IP for production use."
  type        = string
  default     = "0.0.0.0/0"
}

variable "server_instance_type" {
  description = "Dragonfly README: Dragonfly server on c7gn.12xlarge (48 vCPU)."
  type        = string
  default     = "c7gn.12xlarge"
}

variable "client_instance_type" {
  description = "Dragonfly README: memtier_benchmark client on c7gn.16xlarge, same AZ as server."
  type        = string
  default     = "c7gn.16xlarge"
}

variable "server_root_volume_gb" {
  type    = number
  default = 100
}

variable "client_root_volume_gb" {
  type    = number
  default = 50
}

variable "use_placement_group" {
  description = "Use a cluster placement group for lowest intra-AZ latency (recommended for Dragonfly-style tests)."
  type        = bool
  default     = true
}

variable "subnet_id" {
  description = "Optional: explicit subnet ID (must support the instance types and have a route to the internet for apt/git). If null, subnet is chosen from availability_zone (see below)."
  type        = string
  default     = null
}

variable "availability_zone" {
  description = "Used when subnet_id is null: pick the default-VPC subnet in this AZ. Large c7gn sizes are often out of stock in specific AZs (e.g. us-east-1c); AWS may direct you to 1a, 1b, 1d, or 1f. If null, defaults to the \"a\" AZ in the selected region (e.g. us-east-1a)."
  type        = string
  default     = null
}
