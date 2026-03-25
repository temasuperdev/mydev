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

# Список имён виртуальных машин
variable "vm_names" {
  description = "Список имён виртуальных машин"
  type        = list(string)
  default     = ["lb-0", "server-0", "server-1", "server-2"]
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

# SSH-ключ
locals {
  ssh_public_key = file(pathexpand("~/.ssh/id_ed25519.pub"))
  ssh_private_key_path = pathexpand("~/.ssh/id_ed25519")
}

# Формируем map с именами ВМ и их ролями
locals {
  vm_defs = { for name in var.vm_names : name => {
    name = name
    role = startswith(name, "lb-") ? "loadbalancer" : "k3s_server"
  } }
}

# Тома для каждой ВМ (копии базового образа)
resource "libvirt_volume" "vm_volume" {
  for_each = local.vm_defs

  name           = "${each.value.name}_volume"
  base_volume_id = libvirt_volume.ubuntu_volume.id
  pool           = "default"
  size           = 25 * 1024 * 1024 * 1024  # 25 ГБ
}

# Cloud-init диски с настройками хоста
resource "libvirt_cloudinit_disk" "vm_cloudinit" {
  for_each = local.vm_defs

  name      = "${each.value.name}_cloudinit.iso"
  pool      = "default"
  user_data = templatefile("${path.module}/cloud_init.cfg", {
    hostname       = each.value.name
    ssh_public_key = local.ssh_public_key
  })
}

# Виртуальные машины
resource "libvirt_domain" "vm" {
  for_each = local.vm_defs

  name   = each.value.name
  memory = "2048"
  vcpu   = 2

  network_interface {
    network_name = "ovs-net"
  }

  disk {
    volume_id = libvirt_volume.vm_volume[each.key].id
  }

  cpu = {
    mode = "host-passthrough"
  }

  cloudinit = libvirt_cloudinit_disk.vm_cloudinit[each.key].id

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

# Получение IP-адресов всех ВМ и формирование Ansible-инвентаря
resource "null_resource" "get_vm_ips" {
  depends_on = [libvirt_domain.vm]

  provisioner "local-exec" {
    command = <<-EOT
      # Ждём, пока все ВМ поднимутся и QEMU Guest Agent начнёт отвечать
      sleep 60

      # Очищаем предыдущий инвентарь
      > ansible_inventory.ini

      # Списки для групп
      LB_HOSTS=""
      K3S_HOSTS=""

      for VM_NAME in ${join(" ", keys(local.vm_defs))}; do
        echo "Получение IP для $VM_NAME..."
        IP=$(sudo virsh qemu-agent-command "$VM_NAME" '{"execute":"guest-network-get-interfaces"}' 2>/dev/null | jq -r '.return[] | ."ip-addresses"[] | select(."ip-address-type" == "ipv4" and ."ip-address" != "127.0.0.1") | ."ip-address"' | head -n1)

        if [ -z "$IP" ]; then
          echo "Не удалось получить IP для $VM_NAME" >&2
          exit 1
        fi

        # Записываем строку с переменными хоста
        echo "$VM_NAME ansible_host=$IP ansible_user=test ansible_ssh_private_key_file=${local.ssh_private_key_path}" >> ansible_inventory.ini

        # Добавляем хост в соответствующую группу (POSIX‑совместимо)
        case "$VM_NAME" in
          lb-*)
            LB_HOSTS="$LB_HOSTS $VM_NAME"
            ;;
          *)
            K3S_HOSTS="$K3S_HOSTS $VM_NAME"
            ;;
        esac
      done

      # Добавляем разделитель перед группами
      echo "" >> ansible_inventory.ini

      # Группа loadbalancer
      if [ -n "$LB_HOSTS" ]; then
        echo "[loadbalancer]" >> ansible_inventory.ini
        for host in $LB_HOSTS; do
          echo "$host" >> ansible_inventory.ini
        done
        echo "" >> ansible_inventory.ini
      fi

      # Группа k3s_servers
      if [ -n "$K3S_HOSTS" ]; then
        echo "[k3s_servers]" >> ansible_inventory.ini
        for host in $K3S_HOSTS; do
          echo "$host" >> ansible_inventory.ini
        done
        echo "" >> ansible_inventory.ini
      fi

      echo "Инвентарь сформирован в ansible_inventory.ini"
    EOT
  }
}