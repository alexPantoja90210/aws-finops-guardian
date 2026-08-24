###############################################################################
# Variables for the Guardian stack.
# No sensitive value lives here. Real values go in terraform.tfvars, which is
# in .gitignore and is never committed.
###############################################################################

variable "aws_region" {
  description = "Region where the Guardian lives. Free tier is available in all standard regions."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name and tag prefix for every resource in the stack."
  type        = string
  default     = "finops-guardian"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.project_name))
    error_message = "project_name must be lowercase letters, digits or hyphens, 3 to 32 characters long."
  }
}

variable "instance_type" {
  description = "EC2 instance type. Restricted to free tier on purpose: this project must not generate spend."
  type        = string
  default     = "t3.micro"

  validation {
    condition     = contains(["t2.micro", "t3.micro"], var.instance_type)
    error_message = "Only free-tier types are allowed (t2.micro or t3.micro). Changing this breaks the project's zero-spend premise."
  }
}

variable "ssh_ingress_cidr" {
  description = <<-EOT
    CIDR allowed to reach SSH. It must be the operator's public IP as a /32.
    It is left empty by default on purpose: that forces an explicit decision
    and prevents an oversight from opening port 22 to the world.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.ssh_ingress_cidr == "" || can(cidrhost(var.ssh_ingress_cidr, 0))
    error_message = "ssh_ingress_cidr must be a valid CIDR, for example 203.0.113.17/32."
  }

  validation {
    condition     = var.ssh_ingress_cidr != "0.0.0.0/0"
    error_message = "0.0.0.0/0 opens SSH to the whole internet. Use your own IP as a /32."
  }
}

variable "enable_ssh" {
  description = <<-EOT
    When false, the Security Group does not open port 22 at all.
    Defaults to false on purpose: the box is administered through SSM Session
    Manager, which needs no inbound port and no private key to guard. Set it to
    true only if you also provide ssh_ingress_cidr and ssh_key_name.
  EOT
  type        = bool
  default     = false
}

variable "http_ingress_cidr" {
  description = "CIDR allowed to read report.json over nginx. By default, the same restriction as SSH."
  type        = string
  default     = ""
}

variable "budget_notification_email" {
  description = "Email that receives the zero-spend budget alert. Without it the guard warns nobody."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_notification_email))
    error_message = "budget_notification_email must be a valid email address."
  }
}

variable "budget_limit_usd" {
  description = "Monthly budget ceiling in USD. 1.00 acts as zero-spend: any real charge trips the alert."
  type        = string
  default     = "1.0"
}

variable "budget_alert_threshold_percent" {
  description = "Percentage of the ceiling that triggers the notification. 1% of 1 USD warns at practically the first cent."
  type        = number
  default     = 1

  validation {
    condition     = var.budget_alert_threshold_percent > 0 && var.budget_alert_threshold_percent <= 100
    error_message = "The threshold must be between 1 and 100."
  }
}

variable "root_volume_size_gb" {
  description = "Root volume size. The free tier covers up to 30 GB of gp3 EBS per month."
  type        = number
  default     = 8

  validation {
    condition     = var.root_volume_size_gb >= 8 && var.root_volume_size_gb <= 30
    error_message = "Stay between 8 and 30 GB to remain inside the EBS free tier."
  }
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair. Empty = no key pair (access through SSM Session Manager)."
  type        = string
  default     = ""
}
