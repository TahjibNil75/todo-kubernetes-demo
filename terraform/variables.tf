variable "env" {
  description = "Environment name (e.g. dev, prod)"
  type        = string
}

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "region" {
  type = string
}

variable "aws_profile" {
  type = string
}