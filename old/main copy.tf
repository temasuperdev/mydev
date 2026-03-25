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

# Переменная для имени виртуальной машины
variable "vm_name" {
  description = "Имя виртуальной машины"
  type        = string
  default     = "firstvm"
}

provider "libvirt" {
  uri = "qemu:///system"
}

# Базовый образ из локальной папки
resource "libvirt_volume" "ubuntu_volume" {
  name   = "ubuntu-2404-base.qcow2"
  pool   = "default"
  source = "/home/tema/my-pools/ubuntu-24.04-server-cloudimg-amd64.img"
  format = "qcow2"
}

# Рабочий том для ВМ (копия базового)
resource "libvirt_volume" "vm_volume" {
  name           = "first_vm_volume"
  base_volume_id = libvirt_volume.ubuntu_volume.id
  pool           = "default"
  size           = 25 * 1024 * 1024 * 1024  # 25 ГБ
}

# SSH-ключ
locals {
  ssh_public_key = file(pathexpand("~/.ssh/id_ed25519.pub"))
}

# Cloud-init диск с использованием шаблона
resource "libvirt_cloudinit_disk" "vm_cloudinit" {
  name      = "${var.vm_name}_cloudinit.iso"
  pool      = "default"
  user_data = templatefile("${path.module}/cloud_init.cfg", {
    hostname       = var.vm_name
    ssh_public_key = local.ssh_public_key
  })
}

# Виртуальная машина
resource "libvirt_domain" "vm" {
  name   = var.vm_name
  memory = "2048"
  vcpu   = 2

  network_interface {
    network_name = "ovs-net"
    # wait_for_lease = true
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

# Путь к приватному SSH-ключу (используется в инвентаре)
locals {
  ssh_private_key_path = pathexpand("~/.ssh/id_ed25519")
}

# Ждём загрузки ВМ и получаем IP через QEMU Guest Agent
resource "null_resource" "get_vm_ip" {
  depends_on = [libvirt_domain.vm]

  provisioner "local-exec" {
    command = <<-EOT
      sleep 60
      VM_NAME="${libvirt_domain.vm.name}"
      # Получаем IP через qemu-agent, исключая loopback
      IP=$(sudo virsh qemu-agent-command "$VM_NAME" '{"execute":"guest-network-get-interfaces"}' | jq -r '.return[] | ."ip-addresses"[] | select(."ip-address-type" == "ipv4" and ."ip-address" != "127.0.0.1") | ."ip-address"')
      FIRST_IP=$(echo "$IP" | head -n1)
      # Записываем инвентарь Ansible в формате INI с переменными хоста
      echo "$VM_NAME ansible_host=$FIRST_IP ansible_user=test ansible_ssh_private_key_file=${local.ssh_private_key_path}" > ansible_inventory.ini
      echo "$VM_NAME IP = $FIRST_IP"
    EOT
  }
}