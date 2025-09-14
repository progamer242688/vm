#!/bin/bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager v1.1
# =============================

# === [Config] ===
export VERSION="1.1"
export VM_DIR="${VM_DIR:-$HOME/vms}"
export LOG_FILE="$VM_DIR/manager.log"

# === [UTILITIES] ===
log_action() {
    local type=$1
    local message=$2
    echo "[$(date '+%F %T')] [$type] $message" >> "$LOG_FILE"
}

print_status() {
    local type="$1"
    local message="$2"
    case $type in
        "INFO")    echo -e "\033[1;34m[INFO]\033[0m $message" ;;
        "WARN")    echo -e "\033[1;33m[WARN]\033[0m $message" ;;
        "ERROR")   echo -e "\033[1;31m[ERROR]\033[0m $message" ;;
        "SUCCESS") echo -e "\033[1;32m[SUCCESS]\033[0m $message" ;;
        "INPUT")   echo -e "\033[1;36m[INPUT]\033[0m $message" ;;
        *)         echo    "[$type] $message" ;;
    esac
    log_action "$type" "$message"
}

pause() {
    read -n1 -sr -p "Press any key to continue..."
    echo
}

# === [BANNER] ===
display_header() {
    clear
    cat << "EOF"
========================================================================
                         POWERED BY BIBEK
========================================================================
EOF
    print_status "SUCCESS" "Welcome to Enhanced Multi-VM Manager made by Bibek"
    print_status "INFO" "Script Version: $VERSION | Path: $(realpath "$0")"
    echo
}

# === [DEPENDENCY CHECK] ===
check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img")
    local missing_deps=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing_deps[*]}"
        print_status "INFO" \
            "Ubuntu/Debian: sudo apt install qemu-system-x86 qemu-utils qemu-system-cloud cloud-image-utils wget"
        print_status "INFO" \
            "Fedora/CentOS/RHEL: sudo dnf install qemu-img qemu-system-x86 qemu-system-cloud cloud-utils wget"
        print_status "INFO" \
            "Alpine: sudo apk add qemu-img qemu-system-x86_64 cloud-init wget"
        exit 1
    fi
}

# === [INPUT VALIDATION] ===
validate_input() {
    local type="$1"
    local value="$2"
    case $type in
        "number")     [[ "$value" =~ ^[0-9]+$ ]];;
        "size")       [[ "$value" =~ ^[0-9]+[GgMm]$ ]];;
        "port")       [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 23 && value <= 65535 ));;
        "name")       [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]];;
        "username")   [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]];;
        *) return 1;;
    esac
    return $?
}

# === [CLEANUP] ===
cleanup() {
    rm -f user-data meta-data 2>/dev/null || true
}
trap cleanup EXIT

# === [CORE FUNCTIONS] ===
get_vm_list() {
    find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

load_vm_config() {
    local vm_name="$1"
    local config_file="$VM_DIR/$vm_name.conf"
    if [[ -f "$config_file" ]]; then
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED
        source "$config_file"
        return 0
    else
        print_status "ERROR" "VM config '$vm_name' not found."
        return 1
    fi
}

save_vm_config() {
    local config_file="$VM_DIR/$VM_NAME.conf"
    cat > "$config_file" <<EOF
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
    print_status "SUCCESS" "Saved: $config_file"
}

setup_vm_image() {
    print_status "INFO" "Downloading and preparing image..."
    mkdir -p "$VM_DIR"
    if [[ -f "$IMG_FILE" ]]; then
        print_status "INFO" "Image exists. Skipping download."
    else
        if ! wget --progress=bar:force "$IMG_URL" -O "$IMG_FILE.tmp"; then
            print_status "ERROR" "Could not download image."
            exit 1
        fi
        mv "$IMG_FILE.tmp" "$IMG_FILE"
    fi
    qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null || print_status "WARN" "Resize may have failed; check image!"
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
    cat > meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF
    cloud-localds "$SEED_FILE" user-data meta-data
    print_status "SUCCESS" "VM '$VM_NAME' ready!"
}

# === [MAIN MENU & CORE WORKFLOWS] ===
main_menu() {
    while true; do
        display_header
        local vms=($(get_vm_list))
        local vm_count=${#vms[@]}
        if [ $vm_count -gt 0 ]; then
            print_status "INFO" "VMs Detected ($vm_count):"
            for i in "${!vms[@]}"; do
                local status="Stopped"
                if pgrep -f "qemu-system-x86_64.*${vms[$i]}" &>/dev/null; then status="Running"; fi
                printf "  %2d) %s (%s)\n" $((i+1)) "${vms[$i]}" "$status"
            done
        fi
        echo "---------"
        echo "  [1] Create new VM"
        if [ $vm_count -gt 0 ]; then
            echo "  [2] Start VM"
            echo "  [3] Stop VM"
            echo "  [4] Show VM info"
            echo "  [5] Edit VM config"
            echo "  [6] Delete VM"
            echo "  [7] Resize VM disk"
        fi
        echo "  [0] Exit"
        echo "---------"
        read -p "$(print_status "INPUT" "Enter your choice: ")" choice
        case $choice in
            1) create_new_vm ;;
            2) if [ $vm_count -gt 0 ]; then pick_vm_action start_vm "${vms[@]}"; fi ;;
            3) if [ $vm_count -gt 0 ]; then pick_vm_action stop_vm "${vms[@]}"; fi ;;
            4) if [ $vm_count -gt 0 ]; then pick_vm_action show_vm_info "${vms[@]}"; fi ;;
            5) if [ $vm_count -gt 0 ]; then pick_vm_action edit_vm_config "${vms[@]}"; fi ;;
            6) if [ $vm_count -gt 0 ]; then pick_vm_action delete_vm "${vms[@]}"; fi ;;
            7) if [ $vm_count -gt 0 ]; then pick_vm_action resize_vm_disk "${vms[@]}"; fi ;;
            0) print_status "INFO" "Bye!"; exit 0 ;;
            *) print_status "ERROR" "Bad selection!" ;;
        esac
        pause
    done
}

create_new_vm() {
    print_status "INFO" "Creating a New VM"
    local cpu_default="$(nproc)"
    local mem_default="$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 2 ))"   # Half RAM by default
    # OS Selection
    print_status "INFO" "Available OS options:"
    local os_keys=("${!OS_OPTIONS[@]}")
    for i in "${!os_keys[@]}"; do echo "  $((i+1))) ${os_keys[$i]}"; done
    while true; do
        read -p "$(print_status "INPUT" "Choose OS (1-${#os_keys[@]}): ")" os_choice
        if [[ "$os_choice" =~ ^[0-9]+$ ]] && [ "$os_choice" -ge 1 ] && [ "$os_choice" -le "${#os_keys[@]}" ]; then
            local os="${os_keys[$((os_choice-1))]}"
            IFS='|' read OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$os]}"
            break
        fi
        print_status "ERROR" "Invalid selection."
    done
    while true; do read -p "VM Name (default $DEFAULT_HOSTNAME): " VM_NAME; VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"; validate_input "name" "$VM_NAME" && break; done
    while true; do read -p "Hostname (default $VM_NAME): " HOSTNAME; HOSTNAME="${HOSTNAME:-$VM_NAME}"; validate_input "name" "$HOSTNAME" && break; done
    while true; do read -p "Username (default $DEFAULT_USERNAME): " USERNAME; USERNAME="${USERNAME:-$DEFAULT_USERNAME}"; validate_input "username" "$USERNAME" && break; done
    while true; do read -s -p "Password (default $DEFAULT_PASSWORD): " PASSWORD; PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"; echo; [ -n "$PASSWORD" ] && break; done
    while true; do read -p "Disk size (default 20G): " DISK_SIZE; DISK_SIZE="${DISK_SIZE:-20G}"; validate_input "size" "$DISK_SIZE" && break; done
    while true; do read -p "Memory MB (default $mem_default): " MEMORY; MEMORY="${MEMORY:-$mem_default}"; validate_input "number" "$MEMORY" && break; done
    while true; do read -p "CPUs (default $cpu_default): " CPUS; CPUS="${CPUS:-$cpu_default}"; validate_input "number" "$CPUS" && break; done
    while true; do read -p "SSH Port (default 2222): " SSH_PORT; SSH_PORT="${SSH_PORT:-2222}"; validate_input "port" "$SSH_PORT" && break; done
    while true; do read -p "GUI mode? (y/n, default n): " gui_input; GUI_MODE=false; gui_input="${gui_input:-n}"; [[ "$gui_input" =~ ^[Yy]$ ]] && GUI_MODE=true; break; done
    read -p "Additional port forwards (comma separated, e.g. 8080:80): " PORT_FORWARDS
    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date)"
    setup_vm_image
    save_vm_config
}

# Short action picker for VMs
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

# ---- Actions ----
start_vm() {
    local vm_name="$1"
    if load_vm_config "$vm_name"; then
        print_status "INFO" "Starting $vm_name (SSH: $USERNAME@$HOSTNAME -p$SSH_PORT, Password: $PASSWORD)"
        [ ! -f "$IMG_FILE" ] && { print_status "ERROR" "Image not found"; return 1; }
        [ ! -f "$SEED_FILE" ] && { print_status "WARN" "Seed not found, recreating..."; setup_vm_image; }
        local qemu_cmd=(qemu-system-x86_64 -enable-kvm -m "$MEMORY" -smp "$CPUS" -cpu host
            -drive "file=$IMG_FILE,format=qcow2,if=virtio"
            -drive "file=$SEED_FILE,format=raw,if=virtio" -boot order=c
            -netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22" -device virtio-net-pci,netdev=net0
            -device virtio-balloon-pci -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0)
        [[ "$GUI_MODE" == true ]] && qemu_cmd+=(-vga virtio -display gtk,gl=on) || qemu_cmd+=(-nographic -serial mon:stdio)
        "${qemu_cmd[@]}"
        print_status "INFO" "VM $vm_name shut down."
    fi
}
stop_vm() {
    local vm_name="$1"
    if load_vm_config "$vm_name" && pgrep -f "qemu-system-x86_64.*$IMG_FILE" &>/dev/null; then
        print_status "INFO" "Stopping $vm_name"
        pkill -f "qemu-system-x86_64.*$IMG_FILE"
        sleep 2
        pgrep -f "qemu-system-x86_64.*$IMG_FILE" &>/dev/null && pkill -9 -f "qemu-system-x86_64.*$IMG_FILE"
        print_status "SUCCESS" "Stopped $vm_name"
    else
        print_status "WARN" "$vm_name not running."
    fi
}
delete_vm() {
    local vm_name="$1"
    print_status "WARN" "Delete '$vm_name'? This is permanent!"
    read -p "Type 'DELETE' to confirm: " confirm
    if [[ "$confirm" == "DELETE" ]]; then
        load_vm_config "$vm_name"
        rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm_name.conf"
        print_status "SUCCESS" "Deleted $vm_name"
    else
        print_status "INFO" "Cancelled."
    fi
}
show_vm_info() {
    local vm_name="$1"
    if load_vm_config "$vm_name"; then
        echo; print_status "INFO" "VM: $vm_name"
        echo "OS: $OS_TYPE, Hostname: $HOSTNAME, Created: $CREATED"
        echo "User: $USERNAME/$PASSWORD | Disk: $DISK_SIZE | Memory: $MEMORY | CPUs: $CPUS"
        echo "SSH Port: $SSH_PORT | GUI mode: $GUI_MODE | Img: $IMG_FILE | Seed: $SEED_FILE"
        echo "Port Forwards: ${PORT_FORWARDS:-None}"
        pause
    fi
}
edit_vm_config() { print_status "SUCCESS" "WIP: edit config (extend as per need)"; }
resize_vm_disk() { print_status "SUCCESS" "WIP: resize disk (extend as per need)"; }

# === [SUPPORTED OS] ===
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

# === [STARTUP] ===
mkdir -p "$VM_DIR"
check_dependencies
main_menu

