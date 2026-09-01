resource "proxmox_virtual_environment_container" "tf_test1" {
  vm_id     = 200
  node_name = "pve1"

  operating_system {
    type             = "debian"
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
  }

  initialization {
    hostname = "tf-test1"

    ip_config {
      ipv4 {
        address = "10.0.20.101/24"
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

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
    swap      = 256
  }

  disk {
    datastore_id = "local-zfs"
    size         = 8
  }

  network_interface {
    name    = "eth0"
    bridge  = "vmbr1"
    vlan_id = 20
  }

  unprivileged  = true
  started       = true
  start_on_boot = false
}
