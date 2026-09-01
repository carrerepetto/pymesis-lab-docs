resource "proxmox_virtual_environment_container" "glpi1" {
  vm_id     = 112
  node_name = "pve1"
  start_on_boot = false

  operating_system {
    type             = "debian"
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
  }

  initialization {
    hostname = "glpi1"

    ip_config {
      ipv4 {
        address = "10.0.20.80/24"
        gateway = "10.0.20.1"
      }
    }

    dns {
      domain  = "pymesis.lab"
      servers = ["10.0.20.10"]
    }
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
    swap      = 512
  }

  disk {
    datastore_id = "local-zfs"
    size         = 20
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr1"
    vlan_id     = 20
    mac_address = "BC:24:11:82:E7:AB"
  }

  unprivileged  = true
  started       = true

  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }

  features {
    nesting = true
  }

  lifecycle {
    ignore_changes = [operating_system]
  }
}
