resource "proxmox_virtual_environment_container" "vault1" {
  node_name    = "pve1"
  vm_id        = 120
  start_on_boot = false
  tags         = ["terraform", "security"]

  unprivileged = true

  operating_system {
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type              = "debian"
  }

  disk {
    datastore_id = "local-zfs"
    size         = 8
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 1024
  }

  network_interface {
    name     = "eth0"
    bridge   = "vmbr1"
    vlan_id  = 20
  }

  initialization {
    hostname = "vault1"

    ip_config {
      ipv4 {
        address = "10.0.20.96/24"
        gateway = "10.0.20.1"
      }
    }

    dns {
      domain  = "pymesis.lab"
      servers = ["10.0.20.10"]
    }

    user_account {
      keys = [file("~/.ssh/id_ed25519.pub")]
    }
  }

  console {
    enabled    = true
    tty_count  = 2
    type       = "tty"
  }

  started = true

  lifecycle {
    ignore_changes = [operating_system]
  }
}
