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

###############################################################################
# IA-45 pilot. Everything below creates nothing while pilot_enabled is false.
###############################################################################

variable "pilot_enabled" {
  description = <<-EOT
    Switches on the IA-45 pilot: the scoped injector role and the Pilot tag on
    the target instance. Defaults to false so that the pilot is an explicit act
    with a visible plan, never a side effect of running apply.
  EOT
  type        = bool
  default     = false
}

variable "pilot_injector_principal_arn" {
  description = <<-EOT
    ARN of the IAM principal allowed to assume the injector role — the
    operator's own user or role. Empty by default and supplied through
    terraform.tfvars, which is gitignored, so no account identifier reaches the
    repository.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.pilot_injector_principal_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:(user|role)/.+$", var.pilot_injector_principal_arn))
    error_message = "pilot_injector_principal_arn must be an IAM user or role ARN, for example arn:aws:iam::123456789012:user/alex."
  }
}

variable "pilot_tag_value" {
  description = "Value of the Pilot tag that both marks the target and scopes the injector role's permission."
  type        = string
  default     = "IA-45"
}

variable "pinned_ami_id" {
  description = <<-EOT
    Pins the instance to one AMI id. Empty (the default) keeps the original
    behaviour: data.aws_ami.al2023 resolves the most recent Amazon Linux 2023
    image at plan time.

    That default is right for a long-lived box and wrong for an experiment.
    Amazon publishes AL2023 images continuously, so "most recent" changes under
    you: on 1 Sep 2026 a plan that was meant to flip one credit setting came
    back as "1 to add, 1 to destroy" because the AMI had moved on since 24 Aug.
    Rebuilding the target in the middle of the IA-45 pilot would reset its
    CloudWatch history and change the instance id the ground-truth log points
    at — the labels would survive, but they would name an instance that no
    longer exists.

    So: unpinned for normal operation, where a deliberate rebuild onto a
    patched image is a feature; pinned for the duration of the pilot, where a
    stable target is the whole point. The pin lives in terraform.tfvars, and
    the precondition on aws_instance.guardian refuses to run the pilot without
    one.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.pinned_ami_id == "" || can(regex("^ami-[0-9a-f]{8,17}$", var.pinned_ami_id))
    error_message = "pinned_ami_id must be an AMI id such as ami-0123456789abcdef0, or empty to track the latest."
  }
}
