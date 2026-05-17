# Azure Container Instances (ACI) — Terraform
#
# Resources created:
#   1. azurerm_resource_group       — holds everything below
#   2. azurerm_container_group      — runs the app container (+ optional sidecar DB)
#   3. azurerm_postgresql_flexible_server / azurerm_mysql_flexible_server
#                                   — only when install_db == "rds"
#
# Unlike EKS/AKS we do NOT need a VPC/VNet for the basic public ACI path —
# `ip_address_type = "Public"` auto-assigns a public IP and FQDN via the
# `dns_name_label` field. For private VNet ingress, swap to "Private" and add
# a subnet delegation block (out of scope for the wizard default).

terraform {
  backend "azurerm" {}
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

provider "azurerm" {
  features {}
}

# ── Variables ────────────────────────────────────────────────────────────────
variable "project_name" {
  type = string
}

variable "azure_region" {
  type    = string
  default = "eastus"
}

variable "docker_image" {
  description = "Full image reference (e.g. ghcr.io/owner/repo:sha) — passed in from GHA."
  type        = string
}

variable "app_port" {
  type    = number
  default = 3000
}

variable "cpu" {
  type    = number
  default = 0.5
}

variable "memory_gb" {
  type    = number
  default = 1.0
}

# GHCR / private-registry pull credentials. Empty server = public image, no
# credentials sent. We default to GHCR since the GHA workflow pushes there.
variable "registry_server" {
  type    = string
  default = "ghcr.io"
}
variable "registry_username" {
  type    = string
  default = ""
}
variable "registry_password" {
  type      = string
  sensitive = true
  default   = ""
}

variable "db_name" {
  type    = string
  default = ""
}
variable "db_username" {
  type    = string
  default = "appuser"
}
variable "db_password" {
  type      = string
  sensitive = true
  default   = ""
}

# ── Resource group ───────────────────────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = "${var.project_name}-rg"
  location = var.azure_region
  tags = {
    Project   = var.project_name
    ManagedBy = "udap"
  }
}

# ── Optional: managed flexible-server DB ─────────────────────────────────────

# ── Container group ──────────────────────────────────────────────────────────
# DNS label must be globally unique within the region. Suffix with a short
# hash of the resource group so renames don't collide on stale labels.
locals {
  dns_label_base = lower(replace(var.project_name, "_", "-"))
  dns_label      = substr("${local.dns_label_base}-${substr(md5(azurerm_resource_group.rg.id), 0, 6)}", 0, 60)
}

resource "azurerm_container_group" "app" {
  name                = "${var.project_name}-cg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  ip_address_type     = "Public"
  dns_name_label      = local.dns_label
  restart_policy      = "Always"

  # Private-registry pull (e.g. GHCR). When username is empty the block is
  # still emitted with empty values, which Azure tolerates for public images.
  image_registry_credential {
    server   = var.registry_server
    username = var.registry_username
    password = var.registry_password
  }

  container {
    name   = "app"
    image  = var.docker_image
    cpu    = var.cpu
    memory = var.memory_gb

    ports {
      port     = var.app_port
      protocol = "TCP"
    }

    environment_variables = {
      PORT       = tostring(var.app_port)
      NODE_ENV   = "production"
      APP_ENV    = "production"
    }

    # Password + DATABASE_URL contain the password — keep them out of plain
    # `environment_variables` (which is plaintext in TF state and `az
    # container show` output) and use the masked secure_environment_variables
    # block instead.
    secure_environment_variables = {
      DB_PASSWORD = var.db_password
    }
  }


  tags = {
    Project   = var.project_name
    ManagedBy = "udap"
  }
}

# ── Outputs ──────────────────────────────────────────────────────────────────
output "public_ip" {
  value = azurerm_container_group.app.ip_address
}

output "fqdn" {
  value = azurerm_container_group.app.fqdn
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "app_port" {
  value = var.app_port
}

