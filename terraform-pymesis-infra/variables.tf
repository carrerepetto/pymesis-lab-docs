variable "pve_endpoint" {
  description = "URL de la API de Proxmox"
  type        = string
}

variable "pve_api_token" {
  description = "Token de terraform@pve"
  type        = string
  sensitive   = true
}
