terraform {
  required_providers {
    libvirt = {
      source  = "multani/libvirt"
      version = "0.6.3-1+4"
    }
    null = {
      source = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# Переменные для имён виртуальных машин
variable "vm_name" {
  description = "Имя первой виртуальной машины"
  type        = string
  default     = "firstvm"
}

variable "vm_name2" {
  description = "Имя второй виртуальной машины"
  type        = string
  default     = "secondvm"
}

provider "libvirt" {
  uri = "qemu:///system"
}

# Базовый образ из локальной папки (общий для обеих ВМ)
resource "libvirt_volume" "ubuntu_volume" {
  name   = "ubuntu-2404-base.qcow2"
  pool   = "default"
  source = "/home/tema/my-pools/ubuntu-24.04-server-cloudimg-amd64.img"
  format = "qcow2"
}

# Рабочий том для первой ВМ
resource "libvirt_volume" "vm_volume" {
  name           = "first_vm_volume"
  base_volume_id = libvirt_volume.ubuntu_volume.id
  pool           = "default"
  size           = 25 * 1024 * 1024 * 1024  # 25 ГБ
}

# Рабочий том для второй ВМ
resource "libvirt_volume" "vm_volume2" {
  name           = "second_vm_volume"
  base_volume_id = libvirt_volume.ubuntu_volume.id
  pool           = "default"
  size           = 45 * 1024 * 1024 * 1024  # 45 ГБ
}

# Локальные значения: SSH-ключи
locals {
  ssh_public_key       = file(pathexpand("~/.ssh/id_ed25519.pub"))
  ssh_private_key_path = pathexpand("~/.ssh/id_ed25519")
}

# Cloud-init диск для первой ВМ
resource "libvirt_cloudinit_disk" "vm_cloudinit" {
  name      = "${var.vm_name}_cloudinit.iso"
  pool      = "default"
  user_data = templatefile("${path.module}/cloud_init.cfg", {
    hostname       = var.vm_name
    ssh_public_key = local.ssh_public_key
  })
}

# Cloud-init диск для второй ВМ
resource "libvirt_cloudinit_disk" "vm_cloudinit2" {
  name      = "${var.vm_name2}_cloudinit.iso"
  pool      = "default"
  user_data = templatefile("${path.module}/cloud_init.cfg", {
    hostname       = var.vm_name2
    ssh_public_key = local.ssh_public_key
  })
}

# Первая виртуальная машина (выключена, 4 vCPU, 4 ГБ RAM)
resource "libvirt_domain" "vm" {
  name    = var.vm_name
  memory  = "4096"   # 4 ГБ
  vcpu    = 4        # 4 ядра
  running = false    # ВМ будет выключена после применения

  network_interface {
    network_name = "ovs-net"
  }

  disk {
    volume_id = libvirt_volume.vm_volume.id
  }

  cpu = {
    mode = "host-passthrough"
  }

  cloudinit = libvirt_cloudinit_disk.vm_cloudinit.id

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }
}

# Вторая виртуальная машина (включена, 8 vCPU, 10 ГБ RAM)
resource "libvirt_domain" "vm2" {
  name   = var.vm_name2
  memory = "10240"
  vcpu   = 8

  network_interface {
    network_name = "ovs-net"
  }

  disk {
    volume_id = libvirt_volume.vm_volume2.id
  }

  cpu = {
    mode = "host-passthrough"
  }

  cloudinit = libvirt_cloudinit_disk.vm_cloudinit2.id

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }
}

# Получение IP первой ВМ и создание инвентаря Ansible (перезапись файла)
# Для выключенной ВМ скрипт не найдёт IP, но это не вызовет ошибки apply
resource "null_resource" "get_vm_ip" {
  depends_on = [libvirt_domain.vm]

  provisioner "local-exec" {
    command = <<-EOT
      sleep 60
      VM_NAME="${libvirt_domain.vm.name}"
      IP=$(sudo virsh qemu-agent-command "$VM_NAME" '{"execute":"guest-network-get-interfaces"}' | jq -r '.return[] | ."ip-addresses"[] | select(."ip-address-type" == "ipv4" and ."ip-address" != "127.0.0.1") | ."ip-address"' | head -n1)
      echo "$VM_NAME ansible_host=$IP ansible_user=test ansible_ssh_private_key_file=${local.ssh_private_key_path}" > ansible_inventory.ini
      echo "$VM_NAME IP = $IP"
    EOT
  }
}

# Получение IP второй ВМ и дописывание строки в инвентарь Ansible
resource "null_resource" "get_vm_ip2" {
  depends_on = [libvirt_domain.vm2]

  provisioner "local-exec" {
    command = <<-EOT
      sleep 60
      VM_NAME="${libvirt_domain.vm2.name}"
      IP=$(sudo virsh qemu-agent-command "$VM_NAME" '{"execute":"guest-network-get-interfaces"}' | jq -r '.return[] | ."ip-addresses"[] | select(."ip-address-type" == "ipv4" and ."ip-address" != "127.0.0.1") | ."ip-address"' | head -n1)
      echo "$VM_NAME ansible_host=$IP ansible_user=test ansible_ssh_private_key_file=${local.ssh_private_key_path}" >> ansible_inventory.ini
      echo "$VM_NAME IP = $IP"
    EOT
  }
}