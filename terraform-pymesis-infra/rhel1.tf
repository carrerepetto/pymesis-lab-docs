resource "proxmox_virtual_environment_vm" "rhel1" {
  name      = "rhel1"
  node_name = "pve1"
  vm_id     = 122

  bios    = "ovmf"
  machine = "q35"

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  efi_disk {
    datastore_id = "local-zfs"
    file_format  = "raw"
  }

  disk {
    datastore_id = "local-zfs"
    interface    = "scsi0"
    size         = 40
    file_format  = "raw"
    iothread     = true
  }

  cdrom {
    file_id = "local:iso/rhel-9.8-x86_64-dvd.iso"
  }

  network_device {
    bridge  = "vmbr1"
    vlan_id = 20
    model   = "virtio"
  }

  agent {
    enabled = true
  }

  on_boot = false
  scsi_hardware = "virtio-scsi-single"

  tags = ["linux", "redhat", "terraform"]
}
