#!/bin/bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager Pro
# =============================

# ---- Config ----
VERSION="1.2"
VM_DIR="${VM_DIR:-$HOME/vms}"
LOG_FILE="$VM_DIR/manager.log"

# ---- Utils ----
log_action() {
  local type="$1"; shift
  local msg="$*"
  mkdir -p "$VM_DIR"
  echo "[$(date '+%F %T')] [$type] $msg" >> "$LOG_FILE"
}

print_status() {
  local type="$1"; shift
  local msg="$*"
  case "$type" in
    INFO)    echo -e "\033[1;34m[INFO]\033[0m $msg" ;;
    WARN)    echo -e "\033[1;33m[WARN]\033[0m $msg" ;;
    ERROR)   echo -e "\033[1;31m[ERROR]\033[0m $msg" ;;
    SUCCESS) echo -e "\033[1;32m[SUCCESS]\033[0m $msg" ;;
    INPUT)   echo -e "\033[1;36m[INPUT]\033[0m $msg" ;;
    *)       echo "[$type] $msg" ;;
  esac
  log_action "$type" "$msg"
}

pause() { read -n1 -sr -p "Press any key to continue..."; echo; }

display_header() {
  clear
  cat << "EOF"
========================================================================
                         POWERED BY BIBEK
========================================================================
EOF
  print_status "SUCCESS" "Welcome to Enhanced Multi-VM Manager"
  print_status "INFO" "Version: 1.2 | Path: $(realpath "$0")"
  echo
}

# ---- Validation ----
validate_input() {
  local type="$1" value="$2"
  case "$type" in
    number)   [[ "$value" =~ ^[0-9]+$ ]] ;;
    size)     [[ "$value" =~ ^[0-9]+[GgMm]$ ]] ;;
    port)     [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 23 && value <= 65535 )) ;;
    name)     [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]] ;;
    username) [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]] ;;
    *) return 1 ;;
  esac
}

# ---- Cleanup ----
cleanup() { rm -f user-data meta-data network-config 2>/dev/null || true; }
trap cleanup EXIT

# ---- Dependencies ----
check_dependencies() {
  local deps=(qemu-system-x86_64 wget cloud-localds qemu-img openssl)
  local missing=()
  for d in "${deps[@]}"; do command -v "$d" >/dev/null 2>&1 || missing+=("$d"); done
  if ((${#missing[@]})); then
    print_status "ERROR" "Missing: ${missing[*]}"
    print_status "INFO" "Ubuntu/Debian: sudo apt install qemu-system-x86 qemu-utils cloud-image-utils wget openssl"
    exit 1
  fi
}

# ---- VM config helpers ----
get_vm_list() { find "$VM_DIR" -maxdepth 1 -name "*.conf" -printf "%f\n" 2>/dev/null | sed 's/\.conf$//' | sort; }

load_vm_config() {
  local name="$1" cfg="$VM_DIR/$name.conf"
  if [[ -f "$cfg" ]]; then
    unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED
    # shellcheck disable=SC1090
    source "$cfg"
    return 0
  fi
  print_status "ERROR" "Config not found: $name"
  return 1
}

save_vm_config() {
  local cfg="$VM_DIR/$VM_NAME.conf"
  cat >"$cfg" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="$OS_TYPE"
CODENAME="$CODENAME"
IMG_URL="$IMG_URL"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
SSH_PORT="$SSH_PORT"
GUI_MODE="$GUI_MODE"
PORT_FORWARDS="$PORT_FORWARDS"
IMG_FILE="$IMG_FILE"
SEED_FILE="$SEED_FILE"
CREATED="$CREATED"
EOF
  print_status "SUCCESS" "Saved: $cfg"
}

# ---- Cloud-init seed generation ----
write_cloud_init() {
  # user-data
  cat > user-data <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    password: $(openssl passwd -6 "$PASSWORD" | tr -d '\n')
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
EOF

  # meta-data
  cat > meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

  # Optional: network-config (disabled by default)
  # Uncomment to supply static network
  # cat > network-config <<'EOF'
  # version: 2
  # ethernets:
  #   ens3:
  #     dhcp4: true
  # EOF

  # Build seed
  if [[ -f network-config ]]; then
    cloud-localds -N network-config "$SEED_FILE" user-data meta-data
  else
    cloud-localds "$SEED_FILE" user-data meta-data
  fi
}

# ---- Image handling ----
setup_vm_image() {
  print_status "INFO" "Preparing image..."
  mkdir -p "$VM_DIR"

  if [[ ! -f "$IMG_FILE" ]]; then
    print_status "INFO" "Downloading $IMG_URL"
    if ! wget --progress=bar:force "$IMG_URL" -O "$IMG_FILE.tmp"; then
      print_status "ERROR" "Download failed"
      exit 1
    fi
    mv "$IMG_FILE.tmp" "$IMG_FILE"
  else
    print_status "INFO" "Image exists, skip download"
  fi

  # Resize attempt
  if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null; then
    print_status "WARN" "Resize failed; ensure image supports qcow2 growth"
  fi

  write_cloud_init
  print_status "SUCCESS" "Seed built and image ready"
}

# ---- Start/Stop/Info ----
is_vm_running() { pgrep -f "qemu-system-x86_64.*${IMG_FILE//\//.}" >/dev/null 2>&1; }

wait_for_ssh() {
  local port="$1" tries=30 delay=2
  print_status "INFO" "Waiting for SSH on localhost:$port..."
  for ((i=1; i<=tries; i++)); do
    if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$port" 2>/dev/null; then
      print_status "SUCCESS" "SSH is reachable"
      return 0
    fi
    sleep "$delay"
    (( delay = delay < 10 ? delay+1 : delay ))
  done
  print_status "WARN" "SSH not reachable; continue anyway"
  return 1
}

build_netdev_and_device() {
  # Build one netdev with multiple hostfwd entries to avoid extra NICs
  local netdev="user,id=net0"
  if [[ -n "${PORT_FORWARDS:-}" ]]; then
    IFS=',' read -ra fw <<< "$PORT_FORWARDS"
    for f in "${fw[@]}"; do
      f="${f// /}"
      [[ -z "$f" ]] && continue
      # Validate host:guest numeric
      IFS=':' read -r hp gp <<< "$f"
      if validate_input port "$hp" && validate_input port "$gp"; then
        netdev+=",hostfwd=tcp::${hp}-:$(printf "%d" "$gp")"
      else
        print_status "WARN" "Skip invalid forward: $f"
      fi
    done
  fi
  # Always add SSH forward
  netdev+=",hostfwd=tcp::${SSH_PORT}-:22"
  echo "$netdev"
}

start_vm() {
  local name="$1"
  if load_vm_config "$name"; then
    if is_vm_running; then
      print_status "WARN" "Already running: $name"
      return 0
    fi
    [[ -f "$IMG_FILE" ]] || { print_status "ERROR" "Image missing: $IMG_FILE"; return 1; }
    [[ -f "$SEED_FILE" ]] || { print_status "WARN" "Seed missing; rebuilding"; write_cloud_init; }

    local netdev
    netdev="$(build_netdev_and_device)"

    local qemu_cmd=(
      qemu-system-x86_64
      -enable-kvm
      -cpu host
      -smp "$CPUS"
      -m "$MEMORY"
      -drive "file=$IMG_FILE,format=qcow2,if=virtio"
      -drive "file=$SEED_FILE,format=raw,if=virtio"
      -netdev "$netdev"
      -device virtio-net-pci,netdev=net0
      -device virtio-balloon-pci
      -object rng-random,filename=/dev/urandom,id=rng0
      -device virtio-rng-pci,rng=rng0
      -boot order=c
    )
    if [[ "${GUI_MODE}" == true ]]; then
      qemu_cmd+=(-vga virtio -display gtk,gl=on)
    else
      qemu_cmd+=(-nographic -serial mon:stdio)
    fi

    print_status "INFO" "Starting VM: $name"
    print_status "INFO" "SSH: ssh -p $SSH_PORT $USERNAME@localhost (pass: $PASSWORD)"
    "${qemu_cmd[@]}" &
    local qpid=$!
    disown "$qpid"
    print_status "INFO" "QEMU PID: $qpid"

    wait_for_ssh "$SSH_PORT"
  fi
}

stop_vm() {
  local name="$1"
  if load_vm_config "$name"; then
    if is_vm_running; then
      print_status "INFO" "Stopping: $name"
      pkill -f "qemu-system-x86_64.*${IMG_FILE//\//.}" || true
      sleep 2
      is_vm_running && { print_status "WARN" "Force kill"; pkill -9 -f "qemu-system-x86_64.*${IMG_FILE//\//.}" || true; }
      print_status "SUCCESS" "Stopped $name"
    else
      print_status "INFO" "Not running: $name"
    fi
  fi
}

show_vm_info() {
  local name="$1"
  if load_vm_config "$name"; then
    echo
    print_status "INFO" "VM: $name"
    echo "OS: $OS_TYPE  Hostname: $HOSTNAME  Created: $CREATED"
    echo "User: $USERNAME / $PASSWORD"
    echo "CPU: $CPUS  Mem: ${MEMORY}MB  Disk: $DISK_SIZE"
    echo "SSH Port: $SSH_PORT  GUI: $GUI_MODE"
    echo "Forwards: ${PORT_FORWARDS:-None}"
    echo "Image: $IMG_FILE"
    echo "Seed:  $SEED_FILE"
    echo
    pause
  fi
}

delete_vm() {
  local name="$1"
  print_status "WARN" "Delete '$name'? This is permanent."
  read -p "Type DELETE to confirm: " c
  if [[ "$c" == "DELETE" ]]; then
    if load_vm_config "$name"; then
      rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$name.conf"
      print_status "SUCCESS" "Deleted $name"
    fi
  else
    print_status "INFO" "Cancelled."
  fi
}

resize_vm_disk() {
  local name="$1"
  if load_vm_config "$name"; then
    print_status "INFO" "Current size: $DISK_SIZE"
    while true; do
      read -p "New disk size (e.g. 50G): " new
      if validate_input size "$new"; then
        print_status "INFO" "Resizing image..."
        if qemu-img resize "$IMG_FILE" "$new"; then
          DISK_SIZE="$new"
          save_vm_config
          print_status "SUCCESS" "Resized to $new"
        else
          print_status "ERROR" "Resize failed"
        fi
        break
      else
        print_status "ERROR" "Invalid size"
      fi
    done
  fi
}

edit_vm_config() {
  local name="$1"
  if load_vm_config "$name"; then
    print_status "INFO" "Editing: $name"
    select opt in Hostname Username Password "SSH Port" "GUI Mode" "Port Forwards" Memory CPUs "Back"; do
      case "$REPLY" in
        1) read -p "Hostname ($HOSTNAME): " v; v="${v:-$HOSTNAME}"; validate_input name "$v" && HOSTNAME="$v" ;;
        2) read -p "Username ($USERNAME): " v; v="${v:-$USERNAME}"; validate_input username "$v" && USERNAME="$v" ;;
        3) read -s -p "Password (****): " v; echo; [[ -n "$v" ]] && PASSWORD="$v" ;;
        4) while read -p "SSH Port ($SSH_PORT): " v; do v="${v:-$SSH_PORT}"; validate_input port "$v" && { SSH_PORT="$v"; break; }; done ;;
        5) read -p "GUI mode? y/n ($GUI_MODE): " v; [[ "$v" =~ ^[Yy]$ ]] && GUI_MODE=true || [[ "$v" =~ ^[Nn]$ ]] && GUI_MODE=false || true ;;
        6) read -p "Forwards host:guest,host:guest ... ($PORT_FORWARDS): " v; PORT_FORWARDS="${v:-$PORT_FORWARDS}" ;;
        7) while read -p "Memory MB ($MEMORY): " v; do v="${v:-$MEMORY}"; validate_input number "$v" && { MEMORY="$v"; break; }; done ;;
        8) while read -p "CPUs ($CPUS): " v; do v="${v:-$CPUS}"; validate_input number "$v" && { CPUS="$v"; break; }; done ;;
        9) break ;;
        *) print_status "ERROR" "Invalid" ;;
      esac
      # Rebuild seed if identity changed
      if [[ "$REPLY" =~ ^$ ]]; then
        print_status "INFO" "Updating cloud-init seed..."
        write_cloud_init
      fi
      save_vm_config
    done
  fi
}

# ---- Create VM ----
create_new_vm() {
  print_status "INFO" "Create a new VM"
  local cpu_default mem_default
  cpu_default="$(nproc)"
  mem_default="$(( $(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo) / 2 ))"

  print_status "INFO" "Available OS images:"
  local keys=("${!OS_OPTIONS[@]}")
  for i in "${!keys[@]}"; do echo "  $((i+1))) ${keys[$i]}"; done

  local os_choice
  while true; do
    read -p "$(print_status "INPUT" "Choose OS (1-${#keys[@]}): ")" os_choice
    if [[ "$os_choice" =~ ^[0-9]+$ ]] && (( os_choice>=1 && os_choice<=${#keys[@]} )); then
      local os="${keys[$((os_choice-1))]}"
      IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$os]}"
      break
    fi
    print_status "ERROR" "Invalid selection"
  done

  while true; do read -p "VM Name ($DEFAULT_HOSTNAME): " VM_NAME; VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"; validate_input name "$VM_NAME" && { [[ -f "$VM_DIR/$VM_NAME.conf" ]] && print_status "ERROR" "Exists" || break; }; done
  while true; do read -p "Hostname ($VM_NAME): " HOSTNAME; HOSTNAME="${HOSTNAME:-$VM_NAME}"; validate_input name "$HOSTNAME" && break; done
  while true; do read -p "Username ($DEFAULT_USERNAME): " USERNAME; USERNAME="${USERNAME:-$DEFAULT_USERNAME}"; validate_input username "$USERNAME" && break; done
  while true; do read -s -p "Password ($DEFAULT_PASSWORD): " PASSWORD; PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"; echo; [[ -n "$PASSWORD" ]] && break; done
  while true; do read -p "Disk size (20G): " DISK_SIZE; DISK_SIZE="${DISK_SIZE:-20G}"; validate_input size "$DISK_SIZE" && break; done
  while true; do read -p "Memory MB ($mem_default): " MEMORY; MEMORY="${MEMORY:-$mem_default}"; validate_input number "$MEMORY" && break; done
  while true; do read -p "CPUs ($cpu_default): " CPUS; CPUS="${CPUS:-$cpu_default}"; validate_input number "$CPUS" && break; done
  while true; do read -p "SSH Port (2222): " SSH_PORT; SSH_PORT="${SSH_PORT:-2222}"; validate_input port "$SSH_PORT" && { ss -tln 2>/dev/null | grep -q ":$SSH_PORT " && print_status "ERROR" "Port in use" || break; }; done
  read -p "Extra forwards host:guest,host:guest (blank=none): " PORT_FORWARDS

  IMG_FILE="$VM_DIR/$VM_NAME.img"
  SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
  CREATED="$(date)"

  setup_vm_image
  save_vm_config
}

# ---- Menu ----
pick_vm_action() {
  local action="$1"; shift
  local arr=("$@")
  read -p "$(print_status "INPUT" "VM # (1-${#arr[@]}): ")" idx
  if [[ "$idx" =~ ^[0-9]+$ ]] && ((idx>=1 && idx<=${#arr[@]})); then
    "$action" "${arr[$((idx-1))]}"
  else
    print_status "ERROR" "Invalid selection"
  fi
}

main_menu() {
  while true; do
    display_header
    mapfile -t vms < <(get_vm_list)
    local count="${#vms[@]}"
    if (( count > 0 )); then
      print_status "INFO" "VMs ($count):"
      for i in "${!vms[@]}"; do
        load_vm_config "${vms[$i]}" >/dev/null 2>&1 || true
        local status="Stopped"; is_vm_running && status="Running"
        printf "  %2d) %s (%s)\n" $((i+1)) "${vms[$i]}" "$status"
      done
    fi
    echo "---------"
    echo "  [22] Create new VM"
    if (( count > 0 )); then
      echo "  [23] Start VM"
      echo "  [24] Stop VM"
      echo "  [25] Show VM info"
      echo "  [26] Edit VM config"
      echo "  [27] Delete VM"
      echo "  [28] Resize VM disk"
    fi
    echo "   Exit"
    echo "---------"
    read -p "$(print_status "INPUT" "Enter your choice: ")" choice
    case "$choice" in
      1) create_new_vm ;;
      2) (( count>0 )) && pick_vm_action start_vm "${vms[@]}" ;;
      3) (( count>0 )) && pick_vm_action stop_vm "${vms[@]}" ;;
      4) (( count>0 )) && pick_vm_action show_vm_info "${vms[@]}" ;;
      5) (( count>0 )) && pick_vm_action edit_vm_config "${vms[@]}" ;;
      6) (( count>0 )) && pick_vm_action delete_vm "${vms[@]}" ;;
      7) (( count>0 )) && pick_vm_action resize_vm_disk "${vms[@]}" ;;
      0) print_status "INFO" "Goodbye!"; exit 0 ;;
      *) print_status "ERROR" "Invalid option" ;;
    esac
    pause
  done
}

# ---- OS images ----
declare -A OS_OPTIONS=(
  ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
  ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
  ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
  ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
  ["Fedora 40"]="fedora|40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2|fedora40|fedora|fedora"
  ["CentOS Stream 9"]="centos|stream9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2|centos9|centos|centos"
  ["AlmaLinux 9"]="almalinux|9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|almalinux9|alma|alma"
  ["Rocky Linux 9"]="rockylinux|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rocky9|rocky|rocky"
)

# ---- Boot ----
mkdir -p "$VM_DIR"
check_dependencies
main_menu
