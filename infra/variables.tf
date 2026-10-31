variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "name" {
  type    = string
  default = "call-webhook"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "aurora_engine_version" {
  type    = string
  default = "17.7"
}

# Docker Hub repo, e.g. "myuser/call-webhook"
variable "image_repo" {
  type = string
  default = "at1asflame/call-webhook"
}

# Written by CI into image.auto.tfvars (the GitOps knob)
variable "image_tag" {
  type = string
  default = "1.0.0"
}


# Plain URL, passed by CI as TF_VAR_crm_url (GitHub secret)
variable "crm_url" {
  type = string
  default = "demo"
}