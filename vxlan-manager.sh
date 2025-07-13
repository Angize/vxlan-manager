#!/bin/bash
set -euo pipefail

# Colors (auto-disable if not terminal)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[1;34m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  CYAN=''
  NC=''
fi

auto_install_prereqs_with_progress() {
    if command -v jq &>/dev/null && command -v ovs-vsctl &>/dev/null && command -v sshpass &>/dev/null; then
        echo -e "[✔] All dependencies already installed."
        return
    fi

    echo -n "Installing dependencies: ["

    (
        DEBIAN_FRONTEND=noninteractive sudo apt update -y >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive sudo apt install -y jq openvswitch-switch sshpass >/dev/null 2>&1
    ) &
    pid=$!

    duration=20
    interval=0.2
    steps=$(awk "BEGIN {print $duration / $interval}")
    i=0

    while kill -0 $pid 2>/dev/null && [ $i -le $steps ]; do
        percent=$((i * 100 / steps))
        filled=$((percent / 10))
        empty=$((10 - filled))
        bar=$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' ' ')
        echo -ne "\rInstalling dependencies: [$bar] $percent%"
        sleep $interval
        i=$((i + 1))
    done

    wait $pid
    status=$?

    if [[ $status -eq 0 ]]; then
        echo -e "\rInstalling dependencies: [##########] 100%"
        echo -e "[✔] Dependencies installed successfully.\n"
    else
        echo -e "\rInstalling dependencies: [!!!!!!!!!!] FAILED"
        echo -e "[✗] Failed to install dependencies. Please check your internet or apt sources.\n"
        return 1
    fi
}

CONFIG_DIR="/opt/vxlan"
RELOAD_SCRIPT="$CONFIG_DIR/reload.sh"

check_prereqs() {
    for cmd in ip awk grep sudo jq; do
        if ! command -v $cmd &>/dev/null; then
            echo -e "${RED}Missing command: $cmd${NC}"
            exit 1
        fi
    done
    sudo mkdir -p "$CONFIG_DIR"
}

ip2int() {
    local IFS=.
    read -r i1 i2 i3 i4 <<< "$1"
    echo "$(( (i1<<24) + (i2<<16) + (i3<<8) + i4 ))"
}

list_vxlans() {
    echo -e "${BLUE}Active VXLAN Interfaces:${NC}"

    # لیست اینترفیس‌ها از سیستم
    system_ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep '^vxlan' | grep -v '^vxlan_sys_' || true)

    # لیست اینترفیس‌ها از فایل‌های کانفیگ
    config_ifaces=$(find "$CONFIG_DIR" -name "*.json" -exec jq -r '.name' {} \; 2>/dev/null)

    # ترکیب لیست‌ها و حذف تکراری‌ها
    all_ifaces=$(echo -e "${system_ifaces}\n${config_ifaces}" | sort -u)

    if [[ -z "$all_ifaces" ]]; then
        echo -e "${YELLOW}No VXLAN interfaces found.${NC}"
        return 0
    fi

    for iface in $all_ifaces; do
        echo -e "${YELLOW}- Interface: $iface${NC}"

        cfg="$CONFIG_DIR/$iface.json"
        if [[ -f "$cfg" ]]; then
            id=$(jq -r '.id' "$cfg")
            remote=$(jq -r '.remote_ip' "$cfg")
            vxlan_ip=$(jq -r '.vxlan_ip' "$cfg")
            echo "  ID        : $id"
            echo "  Remote IP : $remote"
            echo "  VXLAN IP  : $vxlan_ip"
        else
            echo "  ${RED}No config file found${NC}"
        fi
        echo
    done
}

check_vxlan_health() {
    echo -e "\n${BLUE}=== VXLAN Health Check ===${NC}"

    configs=$(find "$CONFIG_DIR" -name "*.json" 2>/dev/null)

    declare -A info          # name -> "vxlan_ip:remote_ip:id"
    declare -A seen          # برای چاپ مرتب

    for f in $configs; do
        name=$(jq -r '.name' "$f")
        [[ -z "$name" ]] && continue
        info["$name"]="$(jq -r '.vxlan_ip' "$f"):$(
                       jq -r '.remote_ip' "$f"):$(
                       jq -r '.id'        "$f")"
        seen["$name"]=1
    done

    if ((${#info[@]}==0)); then
        echo -e "${YELLOW}No VXLAN interfaces found.${NC}"
        return
    fi

    for name in "${!info[@]}"; do
        IFS=':' read -r vxlan_ip remote_ip id <<<"${info[$name]}"

        echo -e "\n${CYAN}● Interface: $name${NC}"
        echo    "  ID        : $id"
        echo    "  Remote IP : $remote_ip"
        echo    "  VXLAN IP  : $vxlan_ip"

        if ip link show "$name" &>/dev/null; then
            echo -ne "  Link      : ${GREEN}UP ✅${NC}"
        else
            echo -ne "  Link      : ${RED}DOWN ❌${NC}"
        fi

        # اگر IP یا remote مشخص نباشد، ادامه نمی‌دهیم
        [[ "$vxlan_ip" == "N/A" ]] && { echo; continue; }

        self_ip=${vxlan_ip%%/*}
        base=${self_ip%.*}; last=${self_ip##*.}
        peer_ip=$([[ $last == 1 ]] && echo "$base.2" || echo "$base.1")

        echo -n " | Peer Ping ($peer_ip): "

        if result=$(ping -c 4 -W 1 "$peer_ip" 2>/dev/null); then
            if echo "$result" | grep -q "0 received"; then
                echo -e "${RED}No response ❌${NC}"
            else
                loss=$(echo "$result" | grep -oP '\d+(?=% packet loss)')
                avg=$(echo "$result" | awk -F'/' '/rtt/ {print $5}')
                echo -e "${GREEN}${avg} ms (${loss}% loss) ✅${NC}"
            fi
        else
            echo -e "${RED}Ping failed ❌${NC}"
        fi
    done

    echo -e "\n${GREEN}✔ Health check complete.${NC}"
}

delete_vxlan() {
    echo -e "${YELLOW}Delete VXLAN Interfaces:${NC}"

    real_ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep '^vxlan' | grep -v '^vxlan_sys_' || true)
    config_ifaces=$(find "$CONFIG_DIR" -name "*.json" -exec jq -r '.name' {} \; 2>/dev/null)
    mapfile -t all_ifaces < <(echo -e "${real_ifaces}\n${config_ifaces}" | sort -u | grep -v '^$')

    # اگر هیچی برای حذف نیست
    if [[ ${#all_ifaces[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No VXLAN interfaces or configs found to delete.${NC}"
        return 0
    fi

    echo "1) Delete specific interface"
    echo "2) Delete all VXLAN interfaces"
    read -rp "Choose [1-2]: " delopt

    if [[ "$delopt" == "1" ]]; then
        echo -e "\nAvailable VXLAN interfaces:"
        index=1
        declare -A iface_map

        for iface in "${all_ifaces[@]}"; do
            json_file="$CONFIG_DIR/${iface}.json"
            echo -e "${YELLOW}$index) Interface: $iface${NC}"
            if [[ -f "$json_file" ]]; then
                id=$(jq -r '.id' "$json_file")
                remote=$(jq -r '.remote_ip' "$json_file")
                vxlan_ip=$(jq -r '.vxlan_ip' "$json_file")
                echo "   ID        : $id"
                echo "   Remote IP : $remote"
                echo "   VXLAN IP  : $vxlan_ip"
            else
                echo -e "   ${RED}No config file found${NC}"
                id=""
            fi
            echo
            iface_map["$index"]="$iface:$id"
            ((index++))
        done

        echo "0) Cancel and return to menu"
        read -rp "Enter number to delete: " sel

        if [[ "$sel" == "0" ]]; then
            echo -e "${YELLOW}Cancelled.${NC}"
            return 0
        fi

        if [[ -n "${iface_map[$sel]}" ]]; then
            IFS=':' read -r iface id <<< "${iface_map[$sel]}"
            [[ -n "$id" ]] && {
                ip link del "veth${id}a" 2>/dev/null || true
                ip link del "veth${id}b" 2>/dev/null || true
            }
            ovs-vsctl --if-exists del-br "$iface" 2>/dev/null
            [[ -f "$CONFIG_DIR/${iface}.json" ]] && rm -f "$CONFIG_DIR/${iface}.json"
            echo -e "${GREEN}Deleted interface: $iface${NC}"
        else
            echo -e "${RED}Invalid selection. Nothing deleted.${NC}"
        fi

    elif [[ "$delopt" == "2" ]]; then
        for iface in "${all_ifaces[@]}"; do
            json_file="$CONFIG_DIR/${iface}.json"
            if [[ -f "$json_file" ]]; then
                id=$(jq -r '.id' "$json_file")
                [[ -n "$id" ]] && {
                    ip link del "veth${id}a" 2>/dev/null || true
                    ip link del "veth${id}b" 2>/dev/null || true
                }
                rm -f "$json_file"
            fi
            ovs-vsctl --if-exists del-br "$iface" 2>/dev/null
            echo -e "${GREEN}Deleted: $iface${NC}"
        done
    else
        echo -e "${RED}Invalid option.${NC}"
    fi
}

create_vxlanOVS() {
    local br_name="$1"           # مثال: vxlan42_0
    local vxlan_id="$2"          # مثال: 42   (هم نام پورت VXLAN)
    local remote_ip="$3"    # مثال: 192.168.101.1
    local vxlan_ip="$4"     # مثال: 192.168.101.2/24
    local veth_a="veth${vxlan_id}a"
    local veth_b="veth${vxlan_id}b"

    # پاک‌سازی بقایای قبلی
    for intf in "$veth_a" "$veth_b"; do
        ip link del "$intf" 2>/dev/null || true
    done
    ovs-vsctl --if-exists del-br "$br_name" 2>/dev/null

    # ایجاد Bridge و پورت VXLAN
    ovs-vsctl add-br "$br_name"
    ovs-vsctl add-port "$br_name" "$vxlan_id" \
        -- set interface "$vxlan_id" type=vxlan \
        options:remote_ip="$remote_ip" \
        options:key="$vxlan_id" \
        options:dst_port=4789

    # ساخت و اتصال veth
    ip link add "$veth_a" type veth peer name "$veth_b"
    ovs-vsctl add-port "$br_name" "$veth_a"

    # IP و بالا آوردن
    ip addr add "$vxlan_ip" dev "$veth_b"
    ip link set "$veth_a" up
    ip link set "$veth_b" up
}

create_vxlan() {
    echo -e "${BLUE}Create New VXLAN${NC}"
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|vxlan')
    available_ifaces=($interfaces)

    if [[ ${#available_ifaces[@]} -eq 0 ]]; then
        echo -e "${RED}No usable network interfaces found.${NC}"
        return
    elif [[ ${#available_ifaces[@]} -eq 1 ]]; then
        iface="${available_ifaces[0]}"
        echo -e "${GREEN}Only one interface found: $iface (auto-selected)${NC}"
    else
        echo -e "${BLUE}Available network interfaces:${NC}"
        i=1
        for dev in "${available_ifaces[@]}"; do
            echo "  $i) $dev"
            ((i++))
        done
        echo "  m) Manually enter interface name"
        read -rp "Choose interface [1-${#available_ifaces[@]} or m]: " selection
        if [[ "$selection" == "m" ]]; then
            read -rp "Enter interface manually: " iface
        elif [[ "$selection" =~ ^[0-9]+$ && $selection -ge 1 && $selection -le ${#available_ifaces[@]} ]]; then
            iface="${available_ifaces[$((selection - 1))]}"
        else
            echo -e "${RED}Invalid selection.${NC}"
            return
        fi
    fi

    echo -e "${YELLOW}Selected interface: $iface${NC}"
    local_ip=$(ip -4 addr show dev "$iface" | awk '/inet / {print $2}' | cut -d/ -f1)
    [[ -z "$local_ip" ]] && { echo -e "${RED}No IP on $iface${NC}"; return; }
    echo -e "${GREEN}Detected local IP: $local_ip${NC}"

    read -rp "Remote peer IP: " remote_ip

    echo -e "${YELLOW}Checking connectivity to $remote_ip...${NC}"
    if ping -c 1 -W 1 "$remote_ip" &>/dev/null; then
        echo -e "${GREEN}Remote IP reachable.${NC}"
    else
        echo -e "${RED}Warning: Cannot reach remote IP '$remote_ip'.${NC}"
        read -rp "Continue anyway? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return
    fi

    used_ids=$(find "$CONFIG_DIR" -type f -name "*.json" -exec jq -r '.id' {} \; 2>/dev/null | sort -n)
    suggested_id=42
    for i in $(seq 42 200); do
        if ! echo "$used_ids" | grep -qw "$i"; then
            suggested_id=$i
            break
        fi
    done

    read -rp "VXLAN ID [default $suggested_id]: " vxlan_id
    vxlan_id=${vxlan_id:-$suggested_id}
    echo -e "${YELLOW}VXLAN ID selected: $vxlan_id${NC}"

    echo -e "${BLUE}Checking for existing VXLAN ID usage...${NC}"
    existing_ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep "^vxlan${vxlan_id}" || true)
    existing_jsons=$(find "$CONFIG_DIR" -name "vxlan${vxlan_id}*.json" 2>/dev/null || true)
    echo -e "${YELLOW}Interfaces found: ${existing_ifaces:-none}${NC}"
    echo -e "${YELLOW}Config files found: ${existing_jsons:-none}${NC}"

    if [[ -n "$existing_ifaces" || -n "$existing_jsons" ]]; then
        echo -e "${RED}VXLAN ID '$vxlan_id' is already in use.${NC}"
        read -rp "Do you want to [D]elete old and reuse, or [A]uto-pick a new ID? [D/A]: " choice
        if [[ "$choice" =~ ^[Dd]$ ]]; then
            for ifname in $existing_ifaces; do
            	ip link delete "$ifname" &>/dev/null || true
	            sudo ovs-vsctl del-br "$ifname"
                echo -e "${YELLOW}Deleted interface: $ifname${NC}"
            done
            for conf in $existing_jsons; do
                sudo rm -f "$conf"
                echo -e "${YELLOW}Deleted config: $conf${NC}"
            done
        else
            for i in $(seq $((vxlan_id + 1)) 300); do
                if ! echo "$used_ids" | grep -qw "$i"; then
                    vxlan_id=$i
                    echo -e "${YELLOW}Using new VXLAN ID: $vxlan_id${NC}"
                    break
                fi
            done
        fi
    else
        echo -e "${GREEN}VXLAN ID $vxlan_id is available. Continuing...${NC}"
    fi

    suffix=0
    while true; do
        vxlan_if="vxlan${vxlan_id}_${suffix}"
        if ! ip link show "$vxlan_if" &>/dev/null; then
            break
        fi
        ((suffix++))
    done
    echo -e "${GREEN}Interface name selected: $vxlan_if${NC}"

    echo -e "${YELLOW}Ready for subnet input...${NC}"
    read -rp "Enter VXLAN subnet (CIDR) [default: auto or 192.168.100.0/24]: " vxlan_subnet
    if [[ -z "$vxlan_subnet" ]]; then
        used_subnets=$(find "$CONFIG_DIR" -type f -name "*.json" -exec jq -r '.vxlan_ip' {} \; 2>/dev/null | cut -d. -f1-3 | sort -u)
        base_subnet="192.168.100"
        for i in $(seq 100 250); do
            candidate="192.168.$i"
            if ! echo "$used_subnets" | grep -qw "$candidate"; then
                base_subnet="$candidate"
                break
            fi
        done
        vxlan_subnet="$base_subnet.0/24"
    fi
    echo -e "${YELLOW}VXLAN Subnet selected: $vxlan_subnet${NC}"

    base_ip=${vxlan_subnet%/*}; prefix=${vxlan_subnet#*/}
    ip_a=$(ip2int "$local_ip"); ip_b=$(ip2int "$remote_ip")

    if (( ip_a < ip_b )); then
        vxlan_ip="${base_ip%.*}.1/$prefix"
    else
        vxlan_ip="${base_ip%.*}.2/$prefix"
    fi

    echo -e "${GREEN}Creating interface: $vxlan_if${NC}"
    echo -e "${YELLOW}VXLAN IP will be: $vxlan_ip${NC}"
	create_vxlanOVS "$vxlan_if" "$vxlan_id" "$remote_ip" "$vxlan_ip"
    sudo tee "$CONFIG_DIR/${vxlan_if}.json" > /dev/null <<EOF
{
  "name": "$vxlan_if",
  "id": $vxlan_id,
  "iface": "$iface",
  "remote_ip": "$remote_ip",
  "vxlan_ip": "$vxlan_ip"
}
EOF

    echo -e "${GREEN}VXLAN $vxlan_if created and configuration saved.${NC}"
}

setup_reload_systemd() {
    echo -e "${BLUE}Creating reload.sh and enabling systemd...${NC}"

    # Create reload.sh
    sudo tee "$RELOAD_SCRIPT" > /dev/null <<'EOF'
#!/bin/bash
set -e
CONFIG_DIR="/opt/vxlan"
for f in "$CONFIG_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    name=$(jq -r '.name' "$f")
    id=$(jq -r '.id' "$f")
    iface=$(jq -r '.iface' "$f")
    remote_ip=$(jq -r '.remote_ip' "$f")
    vxlan_ip=$(jq -r '.vxlan_ip' "$f")
    local_ip=$(ip -4 addr show dev "$iface" | awk '/inet / {print $2}' | cut -d/ -f1)
    veth_a="veth${id}a"
    veth_b="veth${id}b"

    # پاک‌سازی بقایای قبلی
    for intf in "$veth_a" "$veth_b"; do
        ip link del "$intf" 2>/dev/null || true
    done
    ovs-vsctl --if-exists del-br "$name" 2>/dev/null

    # ایجاد Bridge و پورت VXLAN
    ovs-vsctl add-br "$name"
    ovs-vsctl add-port "$name" "$id" \
        -- set interface "$id" type=vxlan \
        options:remote_ip="$remote_ip" \
        options:key="$id" \
        options:dst_port=4789

    # ساخت و اتصال veth
    ip link add "$veth_a" type veth peer name "$veth_b"
    ovs-vsctl add-port "$name" "$veth_a"

    # IP و بالا آوردن
    ip addr add "$vxlan_ip" dev "$veth_b"
    ip link set "$veth_a" up
    ip link set "$veth_b" up
done
EOF

    sudo chmod +x "$RELOAD_SCRIPT"
    echo -e "${GREEN}✔ reload.sh created${NC}"

    # Create systemd service
    sudo tee /etc/systemd/system/vxlan-reload.service > /dev/null <<EOF
[Unit]
Description=Reload VXLANs from JSON configs
After=network.target openvswitch-switch.service
Requires=openvswitch-switch.service

[Service]
Type=oneshot
ExecStart=$RELOAD_SCRIPT
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable vxlan-reload.service
    sudo systemctl start vxlan-reload.service

    echo -e "${GREEN}✔ systemd enabled and started${NC}"
}

run_reload_now() {
    echo -e "${BLUE}Running reload.sh...${NC}"
    if [[ -x "$RELOAD_SCRIPT" ]]; then
        sudo "$RELOAD_SCRIPT"
        echo -e "${GREEN}VXLAN interfaces reloaded.${NC}"
    else
        echo -e "${RED}✘ reload.sh not found or not executable.${NC}"
        echo -e "${YELLOW}Hint: Use option [1] to create it first.${NC}"
    fi
}

start_systemd_service() {
    echo -e "${YELLOW}Starting systemd service...${NC}"
    if systemctl start vxlan-reload.service &>/dev/null; then
        echo -e "${GREEN}Systemd service started.${NC}"
    else
        echo -e "${RED}Failed to start systemd service.${NC}"
    fi
}

stop_systemd_service() {
    echo -e "${YELLOW}Stopping systemd service...${NC}"
    if systemctl is-active --quiet vxlan-reload.service; then
        sudo systemctl stop vxlan-reload.service
        echo -e "${GREEN}Service stopped.${NC}"
    else
        echo -e "${RED}Service is not running.${NC}"
    fi
}

remove_systemd_service() {
    echo -e "${YELLOW}Removing systemd service...${NC}"
    
    # Stop and disable the service if it exists
    sudo systemctl stop vxlan-reload.service &>/dev/null || true
    sudo systemctl disable vxlan-reload.service &>/dev/null || true
    sudo rm -f /etc/systemd/system/vxlan-reload.service
    sudo systemctl daemon-reexec
    sudo systemctl daemon-reload

    # Remove reload.sh if it exists
    if [[ -f "$RELOAD_SCRIPT" ]]; then
        sudo rm -f "$RELOAD_SCRIPT"
        echo -e "${GREEN}Removed reload.sh script.${NC}"
    else
        echo -e "${YELLOW}reload.sh was already missing.${NC}"
    fi

    echo -e "${GREEN}Systemd service removed.${NC}"
}

startup_menu() {
    while true; do
        echo -e "\n${BLUE}=== Startup Setup ===${NC}"

        # Check reload.sh
        if [[ -x "$RELOAD_SCRIPT" ]]; then
            echo -e "${GREEN}[✔] reload.sh ready ${NC}"
        else
            echo -e "${RED}[✘] reload.sh missing ${NC}"
        fi

        # Check systemd: enabled + active
        systemd_enabled=false
        systemd_active=false
        if systemctl list-unit-files vxlan-reload.service &>/dev/null; then
            if systemctl is-enabled vxlan-reload.service &>/dev/null; then
                systemd_enabled=true
                echo -en "${GREEN}[✔] systemd enabled ${NC} "
            else
                echo -en "${YELLOW}[✘] systemd disabled ${NC} "
            fi

            if systemctl is-active vxlan-reload.service &>/dev/null; then
                systemd_active=true
                echo -e "${GREEN}(running)${NC}"
            else
                echo -e "${YELLOW}(not running)${NC}"
            fi
        else
            echo -e "${RED}[✘] systemd service not found${NC}"
        fi

        # Show menu
        echo -e "\n${BLUE}Options:${NC}"
        echo -e "  ${YELLOW}1)${NC} Setup systemd (script + enable)"
        echo -e "  ${YELLOW}2)${NC} Run reload.sh"
        if $systemd_active; then
            echo -e "  ${YELLOW}3)${NC} Stop systemd"
        else
            echo -e "  ${YELLOW}3)${NC} Start systemd"
        fi
        echo -e "  ${YELLOW}4)${NC} Remove systemd + script"
        echo -e "  ${YELLOW}5)${NC} Back"

        read -rp $'\nChoice [1-5]: ' smenu
        case "$smenu" in
            1) setup_reload_systemd ;;
            2) run_reload_now ;;
            3)
                if $systemd_active; then
                    stop_systemd_service
                else
                    start_systemd_service
                fi
                ;;
            4) remove_systemd_service ;;
            5) break ;;
            *) echo -e "${RED}Invalid.${NC}" ;;
        esac
    done
}

edit_vxlan() {
    echo -e "${BLUE}Edit VXLAN Configuration${NC}"
    configs=$(ls "$CONFIG_DIR"/*.json 2>/dev/null || true)

    if [[ -z "$configs" ]]; then
        echo -e "${RED}No VXLAN configurations found.${NC}"
        return
    fi

    echo "Available VXLANs:"
    select config_file in $configs "Cancel"; do
        [[ "$REPLY" == "$(( $(echo "$configs" | wc -w) + 1 ))" ]] && return
        if [[ -n "$config_file" && -f "$config_file" ]]; then
            iface=$(jq -r '.name' "$config_file")
            current_remote=$(jq -r '.remote_ip' "$config_file")
            current_ip=$(jq -r '.vxlan_ip' "$config_file")
            current_id=$(jq -r '.id' "$config_file")
            current_dev=$(jq -r '.iface' "$config_file")
            local_ip=$(ip -4 addr show dev "$current_dev" | awk '/inet / {print $2}' | cut -d/ -f1)

            echo -e "\nEditing interface: ${YELLOW}$iface${NC}"
            read -rp "New Remote IP [$current_remote]: " new_remote
            read -rp "New VXLAN IP [$current_ip]: " new_ip
            new_remote=${new_remote:-$current_remote}
            new_ip=${new_ip:-$current_ip}

            # Re-create updated interface
            create_vxlanOVS "$iface" "$current_id" "$new_remote" "$new_ip"

            # Update JSON
            sudo tee "$config_file" > /dev/null <<EOF
{
  "name": "$iface",
  "id": $current_id,
  "iface": "$current_dev",
  "remote_ip": "$new_remote",
  "vxlan_ip": "$new_ip"
}
EOF
            echo -e "${GREEN}Configuration for '$iface' updated successfully.${NC}"
            break
        else
            echo -e "${RED}Invalid selection.${NC}"
        fi
    done
}
setup_remote_vxlan() {
    echo -e "\n${CYAN}≡ Remote VXLAN Auto Setup ≡${NC}"

    read -rp "Remote IP: " remote_ip
    read -rp "Remote SSH user [default: root]: " remote_user
    remote_user=${remote_user:-root}
    read -rp "Remote SSH password: " -s ssh_pass
    echo

    host_ip=$(hostname -I | awk '{print $1}')

    json_file=$(find /opt/vxlan -name '*.json' -exec grep -l "$remote_ip" {} \; | head -n1)

    if [[ -n "$json_file" ]]; then
        vxlan_id=$(jq -r '.id' "$json_file")
        vxlan_ip=$(jq -r '.vxlan_ip' "$json_file")
        local_vxlan_ip="${vxlan_ip%%/*}"
        prefix="${vxlan_ip#*/}"
        IFS='.' read -r a b c _ <<< "$local_vxlan_ip"
        suggested_subnet="$a.$b.$c.0/$prefix"

        echo -e "[${GREEN}✔${NC}] Found existing VXLAN for ${YELLOW}$remote_ip${NC}"
        echo -ne "Use subnet ${CYAN}$suggested_subnet${NC}? [Y/n]: "
        read -r use_old
        [[ $use_old =~ ^[Nn]$ ]] && read -rp "Enter VXLAN subnet: " vxlan_subnet || vxlan_subnet=$suggested_subnet
    else
        echo -e "[${YELLOW}•${NC}] No existing VXLAN for ${YELLOW}$remote_ip${NC}"
        read -rp "Enter VXLAN ID: " vxlan_id
        read -rp "Enter VXLAN subnet (e.g. 192.168.88.0/24): " vxlan_subnet
    fi

    echo -e "[${BLUE}i${NC}] Subnet: ${CYAN}$vxlan_subnet${NC}  |  ID: ${CYAN}$vxlan_id${NC}"

    echo "[*] Sending script to remote..."
    sshpass -p "$ssh_pass" scp -o StrictHostKeyChecking=no ./vxlan-manager.sh "$remote_user@$remote_ip:/root/vxlan-manager.sh" || {
        echo "[!] SCP failed."
        return 1
    }
    
    echo "[*] Executing remote VXLAN setup..."
    sshpass -p "$ssh_pass" ssh -q -o StrictHostKeyChecking=no "$remote_user@$remote_ip" bash -s <<EOF
set -e

# Progress bar
progress() {
    pid=\$1; spin='|/-\\'; i=0
    echo -n "Installing: ["
    while kill -0 \$pid 2>/dev/null; do
        i=\$(( (i+1) %4 ))
        printf "\rInstalling: [%s]" "\${spin:\$i:1}"
        sleep 0.2
    done
    echo -e "\rInstalling: [##########] 100%"
}

# Check & install only missing packages
missing=()
[[ ! \$(command -v sshpass) ]] && missing+=("sshpass")
[[ ! \$(command -v jq) ]] && missing+=("jq")
[[ ! \$(command -v ovs-vsctl) ]] && missing+=("openvswitch-switch")

if (( \${#missing[@]} )); then
    echo "[*] Installing missing packages: \${missing[*]}"
    (
      apt-get -qq update >/dev/null 2>&1
      DEBIAN_FRONTEND=noninteractive apt-get -yqq install \${missing[*]} >/dev/null 2>&1
    ) &
    progress \$!
else
    echo -e "[✔] All required packages already installed."
fi

# Final check
if ! command -v ovs-vsctl >/dev/null 2>&1; then
    echo -e "\${RED}[✗] ovs-vsctl still missing. Exiting.\${NC}"
    exit 1
fi

# Call actual setup
bash /root/vxlan-manager.sh --remote-setup "$host_ip" "$vxlan_subnet" "$vxlan_id"
EOF

    echo -e "\n${GREEN}✔ Remote VXLAN configured successfully on $remote_ip${NC}"
}


if [[ "${1:-}" == "--remote-setup" ]]; then
    peer_ip="$2"
    vxlan_subnet="$3"
    vxlan_id="$4"

    CONFIG_DIR="/opt/vxlan"
    mkdir -p "$CONFIG_DIR"

    iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|vxlan' | head -n1)
    local_ip=$(ip -4 addr show "$iface" | awk '/inet / {print $2}' | cut -d/ -f1)

    base_ip="${vxlan_subnet%/*}"
    prefix="${vxlan_subnet#*/}"

    if (( $(ip2int "$local_ip") < $(ip2int "$peer_ip") )); then
        vxlan_ip="${base_ip%.*}.1/$prefix"
    else
        vxlan_ip="${base_ip%.*}.2/$prefix"
    fi

    vxlan_if="vxlan${vxlan_id}_0"
    json_file="$CONFIG_DIR/${vxlan_if}.json"

    [[ -f "$json_file" ]] && rm -f "$json_file"

    echo "[*] Creating VXLAN interface $vxlan_if..."
    create_vxlanOVS "$vxlan_if" "$vxlan_id" "$peer_ip" "$vxlan_ip"

    cat > "$json_file" <<EOF
{
  "name": "$vxlan_if",
  "id": $vxlan_id,
  "iface": "$iface",
  "remote_ip": "$peer_ip",
  "vxlan_ip": "$vxlan_ip"
}
EOF

    setup_reload_systemd
    echo "${GREEN}[✔] Remote VXLAN setup complete!${NC}"
    exit 0
fi

main_menu() {
    auto_install_prereqs_with_progress
    check_prereqs
    while true; do
        echo -e "\n${BLUE}=== VXLAN Manager Menu ===${NC}"
		echo "1) List VXLAN interfaces"
		echo "2) Create new VXLAN"
		echo "3) Delete VXLAN interface(s)"
		echo "4) Edit VXLAN configuration"
		echo "5) Startup configuration"
		echo "6) Check VXLAN health"
		echo "7) Setup VXLAN on remote server"
		echo "8) Exit"
        read -rp "Choose [1-8]: " opt
        case "$opt" in
		    1) list_vxlans ;;
		    2) create_vxlan ;;
		    3) delete_vxlan ;;
		    4) edit_vxlan ;;
		    5) startup_menu ;;
    		6) check_vxlan_health ;;
            7) setup_remote_vxlan ;;
		    8) echo "Exiting..."; exit 0 ;;
		    *) echo -e "${RED}Invalid option.${NC}" ;;
		esac
    done
}

main_menu