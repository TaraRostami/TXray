#!/bin/bash

# Color Variables
red='\033[0;31m'
green='\033[0;32m'
green_b='\033[1;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
white='\033[0;97m'
white_i='\033[1;3;97m'
teal_i='\033[3;38;5;6m'
orange='\033[38;5;208m'
plain='\033[0m'
color_100='\033[38;5;201m'
color_200='\033[38;5;164m'
color_300='\033[38;5;127m'
color_400='\033[38;5;90m'

# Warp Variables
wgcf_bin="/usr/bin/wgcf"
wgcf_account="wgcf-account.toml"
wgcf_profile="wgcf-profile.conf"
wgcf_dir="/etc/txray-wgcf"

# Cron Variables
cron_file="/var/log/xray/access.log"
cron_cmd="truncate -s 0 \"$cron_file\""

#Message levels functions
function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}

function LOGN() {
    echo -e "${blue}[NOT] $* ${plain}"
}

function LOGW() {
    echo -e "${yellow}[WRN] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

# check root
[[ $EUID -ne 0 ]] && LOGE "ERROR: You must be root to run this script! \n" && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Failed to check the system OS, please contact the author!" >&2
    exit 1
fi

echo -e "The OS release is: ${color_100}$release${plain}"

if [[ "$(uname)" != 'Linux' ]]; then
    echo -e "${red}Your operating system is not supported by this script.${plain}\n"
    echo "Please ensure you are using one of the following supported operating systems:"
    echo "- Ubuntu"
    echo "- Debian"
    echo "- CentOS"
    echo "- OpenEuler"
    echo "- Fedora"
    echo "- Arch Linux"
    echo "- Parch Linux"
    echo "- Manjaro"
    echo "- Armbian"
    echo "- AlmaLinux"
    echo "- Rocky Linux"
    echo "- Oracle Linux"
    echo "- OpenSUSE Tumbleweed"
    echo "- Amazon Linux 2023"
    exit 1
fi

arch() {
  case "$(uname -m)" in
    'i386' | 'i686') echo '32' ;;
    'amd64' | 'x86_64') echo '64' ;;
    'armv5tel') echo 'arm32-v5' ;;
    'armv6l')
      if grep -qw 'vfp' /proc/cpuinfo; then
        echo 'arm32-v6'
      else
        echo 'arm32-v5'
      fi ;;
    'armv7' | 'armv7l')
      if grep -qw 'vfp' /proc/cpuinfo; then
        echo 'arm32-v7a'
      else
        echo 'arm32-v5'
      fi ;;
    'armv8' | 'aarch64') echo 'arm64-v8a' ;;
    'mips') echo 'mips32' ;;
    'mipsle') echo 'mips32le' ;;
    'mips64')
      if lscpu | grep -q "Little Endian"; then
        echo 'mips64le'
      else
        echo 'mips64'
      fi ;;
    'mips64le') echo 'mips64le' ;;
    'ppc64') echo 'ppc64' ;;
    'ppc64le') echo 'ppc64le' ;;
    'riscv64') echo 'riscv64' ;;
    's390x') echo 's390x' ;;
    *) echo -e "${green}Unsupported CPU architecture! ${plain}" && exit 1 ;;
  esac
}

install_base() {
    case "${release}" in
    ubuntu | debian | armbian)
        apt-get update && apt-get install -y -q wget curl tar tzdata unzip
        ;;
    centos | almalinux | rocky | ol)
        yum -y update && yum install -y -q wget curl tar tzdata unzip
        ;;
    fedora | amzn)
        dnf -y update && dnf install -y -q wget curl tar tzdata unzip
        ;;
    arch | manjaro | parch)
        pacman -Syu && pacman -Syu --noconfirm wget curl tar tzdata unzip
        ;;
    opensuse-tumbleweed)
        zypper refresh && zypper -q install -y wget curl tar timezone unzip
        ;;
    *)
        apt-get update && apt install -y -q wget curl tar tzdata unzip
        ;;
    esac
}


confirm() {
    if [[ $# > 1 ]]; then
        echo && read -p "$1 [Default $2]: " temp
        if [[ "${temp}" == "" ]]; then
            temp=$2
        fi
    else
        read -p "$1 [y/n]: " temp
    fi
    if [[ "${temp}" == "y" || "${temp}" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "Restart Xray Core" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}Press enter to return to the main menu: ${plain}" && read temp
    show_menu
}

extracting() {
  if ! unzip -q "$1" -d "$TMP_DIRECTORY"; then
    echo 'error: Xray extracting failed.'
    rm -rf "$TMP_DIRECTORY"
    echo "removed: $TMP_DIRECTORY"
    exit 1
  fi
  LOGN "Extract the Xray package to $TMP_DIRECTORY and prepare it for installation."
}

get_current_version() {
  # Get the current version
  if [[ -f '/usr/local/xray/xray-linux' ]]; then
    cur_ver="$(/usr/local/xray/xray-linux -version | awk 'NR==1 {print $2}')"
    cur_ver="v${cur_ver#v}"
  else
    cur_ver=""
  fi
}

version_gt() {
  test "$(echo -e "$1\\n$2" | sort -V | head -n 1)" != "$1"
}

get_latest_version() {
    local tmp_file
    tmp_file="$(mktemp)"

    if ! curl -Ls -H "Accept: application/vnd.github.v3+json" -o "$tmp_file" "https://api.github.com/repos/XTLS/Xray-core/releases/latest"; then
      rm "$tmp_file"
      echo 'error: Failed to get release list, please check your network.'
      exit 1
    fi
    tag_version=$(grep '"tag_name":' "$tmp_file" | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$tag_version" ]]; then
      if grep -q "API rate limit exceeded"; then
        echo "error: github API rate limit exceeded"
      else
        echo "${red}Failed to fetch xray version. Please try again later${plain}"
      fi
      rm "$tmp_file"
      exit 1
    fi
    rm "$tmp_file"
}

install_xray() {
    echo -e "The OS release is: ${blue}$release${plain}"
    echo -e "arch: ${blue}$(arch)${plain}"
    install_base
    TMP_DIRECTORY="$(mktemp -d)"
    ZIP_FILE="${TMP_DIRECTORY}/Xray-linux-$(arch).zip"
    XRAY_DIR="/usr/local/xray"
    JSON_DIR="/etc/xray"
    cd /usr/local/

    if [ $# == 0 ]; then
        get_latest_version
        echo -e "Got xray latest version: ${tag_version}, beginning the installation..."
        wget --no-check-certificate -O $ZIP_FILE "https://github.com/XTLS/Xray-core/releases/download/${tag_version}/Xray-linux-$(arch).zip"
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Downloading Xray core failed, ensure your server can access GitHub${plain}"
            rm -rf "$TMP_DIRECTORY"
            exit 1
        fi
    else
        tag_version=$1
        tag_version_numeric=${tag_version#v}
        url="https://github.com/XTLS/Xray-core/releases/download/${tag_version}/Xray-linux-$(arch).zip"
        echo -e "Beginning to install Xray $1"
        wget --no-check-certificate -O $ZIP_FILE ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Download of Xray core $1 failed, check if the version exists${plain}"
            rm -rf "$TMP_DIRECTORY"
            exit 1
        fi
    fi

    if [[ -e /usr/local/xray/ ]]; then
        systemctl stop xray
        rm -rf /usr/local/xray/
    fi

    # Check if the directory doesn't exist
    if [[ ! -d "$XRAY_DIR" ]]; then
      LOGN "Directory $XRAY_DIR does not exist. Creating it..."
      install -d "$XRAY_DIR" && echo "Directory $XRAY_DIR created successfully."
    else
      LOGN "Directory $XRAY_DIR already exists."
    fi

    if [[ ! -d "$JSON_DIR" ]]; then
      LOGN "Directory $JSON_DIR does not exist. Creating it..."
      install -d "$JSON_DIR" && echo "Directory $JSON_DIR created successfully."
    else
      LOGN "Directory $JSON_DIR already exists."
    fi

    extracting "$ZIP_FILE"

    install -m 755 "$TMP_DIRECTORY/xray" $XRAY_DIR/xray-linux
    install -m 644 "$TMP_DIRECTORY/geoip.dat" $XRAY_DIR
    install -m 644 "$TMP_DIRECTORY/geosite.dat" $XRAY_DIR

    rm -rf "$TMP_DIRECTORY"
    LOGN "removed: $TMP_DIRECTORY"

    wget -O /usr/local/xray/geoip_IR.dat https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download/geoip.dat
    geoip_status=$?
    wget -O /usr/local/xray/geosite_IR.dat https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download/geosite.dat
    geosite_status=$?

    # Check if either download failed
    if [[ $geoip_status -ne 0 || $geosite_status -ne 0 ]]; then
        LOGW "File geoip.dat and/or geosite.dat failed to download properly. Download them again via the script menu, option 14."
    fi

    wget --no-check-certificate -O /usr/bin/txray https://raw.githubusercontent.com/tararostami/txray/main/txray.sh
    chmod +x /usr/bin/txray

    if [[ ! -f /etc/xray/config.json ]]; then
        cat > "${JSON_DIR}/config.json" << EOF
{
//  "log": {
//    "access": "/var/log/xray/access.log",  # The access log file is located in this path
//    "error": "/var/log/xray/error.log",    # The error log file is located in this path
//    "loglevel": "warning",
//    "dnsLog": false
//  },
//  "api": {},
//  "dns": {},
//  "routing": {},
//  "policy": {},
//  "inbounds": [],
//  "outbounds": [],
//  "transport": {},
//  "stats": {},
//  "reverse": {},
//  "fakedns": {},
//  "metrics": {},
//  "observatory": {},
//  "burstObservatory": {}
}
EOF
        echo "Created config.json at /etc/xray/config.json"
    else
        echo "config.json already exists."
    fi

    # Create systemd service file if it doesn't exist
    if [[ ! -f /etc/systemd/system/xray.service ]]; then
        cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
Documentation=https://xtls.github.io/en/config/
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
WorkingDirectory=/usr/local/xray/
ExecStart=/usr/local/xray/xray-linux run -confdir /etc/xray/
Restart=on-failure
RestartSec=10s
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    fi

    if [[ ! -d '/var/log/xray/' ]]; then
        install -d -m 700 /var/log/xray/
        install -m 600 /dev/null /var/log/xray/access.log
        install -m 600 /dev/null /var/log/xray/error.log
    fi

    if [[ ! -d '/etc/logrotate.d/' ]]; then
        install -d -m 700 /etc/logrotate.d/
        LOGN "Configured /etc/logrotate.d/xray"
    fi
    cat > /etc/logrotate.d/xray << EOF
/var/log/xray/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0600 root root
}
EOF

    systemctl daemon-reload
    systemctl enable xray
    systemctl start xray

    echo -e "${green}xray ${tag_version}${plain} installation finished, it is running now...\n"
    show_usage
}

install_txray() {
    install_xray
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    get_current_version
    get_latest_version
    if ! version_gt "$tag_version" "$cur_ver"; then
        LOGN "No new version. The current version of Xray is $cur_ver"
        exit 0
    else
        echo -e "\n${green}New version available: ${green_b}$tag_version${plain}"
        confirm "This function will forcefully reinstall the latest version, and the data will not be lost. Do you want to continue?" "y"
        if [[ $? != 0 ]]; then
            LOGE "Cancelled"
            if [[ $# == 0 ]]; then
                before_show_menu
            fi
            return 0
        fi
        install_xray
        if [[ $? == 0 ]]; then
            LOGI "Update is complete, Xray has automatically restarted "
            before_show_menu
        fi
    fi
}

update_menu() {
    echo -e "${yellow}Updating TXray${plain}"
    confirm "Do you want to update the TXray script?" "y"
    if [[ $? != 0 ]]; then
        LOGE "Cancelled"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi

    wget --no-check-certificate -O /usr/bin/txray https://raw.githubusercontent.com/TaraRostami/txray/main/txray.sh
    chmod +x /usr/bin/txray

    if [[ $? == 0 ]]; then
        echo -e "${green}TXray script has been successfully updated.${plain}"
        before_show_menu
    else
        echo -e "${red}Failed to update the menu.${plain}"
        return 1
    fi
}

another_version() {
    version_regex='^[0-9]+\.[0-9]+\.[0-9]+$'

    while true; do
        echo -ne "Enter the Xray version ${yellow}(like 24.11.11)${plain}: "
        read tag_version
        
        if [ -z "$tag_version" ]; then
            echo "Xray version cannot be empty. Exiting."
            exit 1
        fi

        tag_version=$(echo "$tag_version" | xargs)
        if [[ $tag_version =~ $version_regex ]]; then
            break
        else
            echo "Invalid version format. Please enter a valid version."
        fi
    done

    # Prepend the 'v' to the entered version number
    tag_version="v$tag_version"

    echo "Downloading and installing Xray version $tag_version..."

    # Call the install function with the version including 'v'
    install_xray "$tag_version"
    if [[ $? == 0 ]]; then
        LOGI "Xray core version $tag_version installed successfully"
        before_show_menu
    fi
}

# Function to handle the deletion of the script file
delete_script() {
    rm "$0" # Remove the script file itself
    exit 1
}

uninstall() {
    confirm "Are you sure you want to uninstall the Xray?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    systemctl stop xray
    systemctl disable xray
    rm -f /etc/systemd/system/xray.service
    systemctl daemon-reload
    systemctl reset-failed
    rm -f /etc/logrotate.d/xray
    rm -rf /usr/local/xray/
    rm -rf /var/log/xray/
    rm -rf /etc/xray/
    remove_cron

    echo -e "\nUninstalled Successfully.\n"
    echo "If you need to install again, you can use below command:"
    echo -e "${green}bash <(curl -Ls https://raw.githubusercontent.com/tararostami/txray/master/txray.sh)${plain}\n"

    # Trap the SIGTERM signal
    trap delete_script SIGTERM
    delete_script
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        LOGI "Xray is running, No need to start again, If you need to restart, please select restart"
    else
        systemctl start xray
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            LOGI "Xray Started Successfully"
        else
            LOGE "Xray Failed to start, Probably because it takes longer than two seconds to start, Please check the log information later"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    check_status
    if [[ $? == 1 ]]; then
        echo ""
        LOGI "Xray stopped, No need to stop again!"
    else
        systemctl stop xray
        sleep 2
        check_status
        if [[ $? == 1 ]]; then
            LOGI "Xray stopped successfully"
        else
            LOGE "Xray stop failed, Probably because the stop time exceeds two seconds, Please check the log information later"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    systemctl restart xray
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        LOGI "Xray and xray Restarted successfully"
    else
        LOGE "Xray restart failed, Probably because it takes longer than two seconds to start, Please check the log information later"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    systemctl status xray -l
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    systemctl enable xray
    if [[ $? == 0 ]]; then
        LOGI "Xray Set to boot automatically on startup successfully"
    else
        LOGE "Xray Failed to set Autostart"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    systemctl disable xray
    if [[ $? == 0 ]]; then
        LOGI "Xray Autostart Cancelled successfully"
    else
        LOGE "Xray Failed to cancel autostart"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    echo -e "${green}\t1.${plain} Debug Log"
    echo -e "${green}\t2.${plain} Clear All logs"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -p "Choose an option: " choice

    case "$choice" in
    0)
        show_menu
        ;;
    1)
        journalctl -u xray -e --no-pager -f -p debug
        if [[ $# == 0 ]]; then
        before_show_menu
        fi
        ;;
    2)
        sudo journalctl --rotate
        sudo journalctl --vacuum-time=1s
        echo "All Logs cleared."
        restart
        ;;
    *)
        echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
        show_log
        ;;
    esac
}

bbr_menu() {
    echo -e "${green}\t1.${plain} Enable BBR"
    echo -e "${green}\t2.${plain} Disable BBR"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -p "Choose an option: " choice
    case "$choice" in
    0)
        show_menu
        ;;
    1)
        enable_bbr
        bbr_menu
        ;;
    2)
        disable_bbr
        bbr_menu
        ;;
    *) 
        echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
        bbr_menu
        ;;
    esac
}

disable_bbr() {

    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo -e "${yellow}BBR is not currently enabled.${plain}"
        before_show_menu
    fi

    # Replace BBR with CUBIC configurations
    sed -i 's/net.core.default_qdisc=fq/net.core.default_qdisc=pfifo_fast/' /etc/sysctl.conf
    sed -i 's/net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf

    # Apply changes
    sysctl -p

    # Verify that BBR is replaced with CUBIC
    if [[ $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}') == "cubic" ]]; then
        echo -e "${green}BBR has been replaced with CUBIC successfully.${plain}"
    else
        echo -e "${red}Failed to replace BBR with CUBIC. Please check your system configuration.${plain}"
    fi
}

enable_bbr() {
    if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf && grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo -e "${green}BBR is already enabled!${plain}"
        before_show_menu
    fi

    # Check the OS and install necessary packages
    case "${release}" in
    ubuntu | debian | armbian)
        apt-get update && apt-get install -yqq --no-install-recommends ca-certificates
        ;;
    centos | almalinux | rocky | ol)
        yum -y update && yum -y install ca-certificates
        ;;
    fedora | amzn)
        dnf -y update && dnf -y install ca-certificates
        ;;
    arch | manjaro | parch)
        pacman -Sy --noconfirm ca-certificates
        ;;
    *)
        echo -e "${red}Unsupported operating system. Please check the script and install the necessary packages manually.${plain}\n"
        exit 1
        ;;
    esac

    # Enable BBR
    echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf

    # Apply changes
    sysctl -p

    # Verify that BBR is enabled
    if [[ $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}') == "bbr" ]]; then
        echo -e "${green}BBR has been enabled successfully.${plain}"
    else
        echo -e "${red}Failed to enable BBR. Please check your system configuration.${plain}"
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /etc/systemd/system/xray.service ]]; then
        return 2
    fi
    temp=$(systemctl status xray | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
    if [[ "${temp}" == "running" ]]; then
        return 0
    else
        return 1
    fi
}

check_enabled() {
    temp=$(systemctl is-enabled xray)
    if [[ "${temp}" == "enabled" ]]; then
        return 0
    else
        return 1
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        LOGE "Xray Core installed, Please do not reinstall"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        LOGE "Please install the Xray Core first"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    status_result=$?
    if [[ $status_result -ne 2 ]]; then
        show_version_status
    fi
    case $status_result in
    0)
        echo -e "Xray state: ${green_b}Running${plain}"
        show_enable_status
        ;;
    1)
        echo -e "Xray state: ${yellow}Not Running${plain}"
        show_enable_status
        ;;
    2)
        echo -e "Xray state: ${red}Not Installed${plain}"
        ;;
    esac
    check_cron
}

show_version_status() {
    get_current_version
    echo -e "Current Xray Core Version: ${green_b}$cur_ver${plain}"
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "Start automatically: ${green_b}Active${plain}"
    else
        echo -e "Start automatically: ${red}Disable${plain}"
    fi
}

update_geo() {
    echo -e "${green}\t1.${plain} Loyalsoldier (geoip.dat, geosite.dat)"
    echo -e "${green}\t2.${plain} chocolate4u (geoip_IR.dat, geosite_IR.dat)"
    echo -e "${green}\t3.${plain} vuong2023 (geoip_VN.dat, geosite_VN.dat)"
    echo -e "${green}\t0.${plain} Back to Main Menu"
    read -p "Choose an option: " choice

    cd /usr/local/xray

    case "$choice" in
    0)
        show_menu
        ;;
    1)
        systemctl stop xray
        rm -f geoip.dat geosite.dat
        wget -N https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
        wget -N https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
        echo -e "${green}Loyalsoldier datasets have been updated successfully!${plain}"
        restart
        ;;
    2)
        systemctl stop xray
        rm -f geoip_IR.dat geosite_IR.dat
        wget -O geoip_IR.dat -N https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download/geoip.dat
        wget -O geosite_IR.dat -N https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download/geosite.dat
        echo -e "${green}chocolate4u datasets have been updated successfully!${plain}"
        restart
        ;;
    3)
        systemctl stop xray
        rm -f geoip_VN.dat geosite_VN.dat
        wget -O geoip_VN.dat -N https://github.com/vuong2023/vn-v2ray-rules/releases/latest/download/geoip.dat
        wget -O geosite_VN.dat -N https://github.com/vuong2023/vn-v2ray-rules/releases/latest/download/geosite.dat
        echo -e "${green}vuong2023 datasets have been updated successfully!${plain}"
        restart
        ;;
    *)
        echo -e "${red}Invalid option. Please select a valid number.${plain}\n"
        update_geo
        ;;
    esac
    before_show_menu
}

show_usage() {
    echo -e "${white_i}TXray${plain} control menu usages: "
    echo "────────────────────────────────────────────────"
    echo -e "SUBCOMMANDS:"
    echo -e "txray              - Admin Management Script"
    echo -e "txray ${color_100}start${plain}        - Start"
    echo -e "txray ${color_100}stop${plain}         - Stop"
    echo -e "txray ${color_100}restart${plain}      - Restart"
    echo -e "txray ${color_100}status${plain}       - Current Status"
    echo -e "txray ${color_100}settings${plain}     - Current Settings"
    echo -e "txray ${color_100}enable${plain}       - Enable Autostart on OS Startup"
    echo -e "txray ${color_100}disable${plain}      - Disable Autostart on OS Startup"
    echo -e "txray ${color_100}log${plain}          - Check logs"
    echo -e "txray ${color_100}update${plain}       - Update"
    echo -e "txray ${color_100}another${plain}      - Another version"
    echo -e "txray ${color_100}install${plain}      - Install"
    echo -e "txray ${color_100}uninstall${plain}    - Uninstall"
    echo "────────────────────────────────────────────────"
}

# Function to detect CPU architecture
arch_wgcf() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv5* | armv5) echo 'armv5' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        mips64) echo 'mips64_softfloat' ;;
        mips64le) echo 'mips64le_softfloat' ;;
        mips) echo 'mips_softfloat' ;;
        mipsle) echo 'mipsle_softfloat' ;;
        s390x) echo 's390x' ;;
        *) echo "Unsupported architecture" && exit 1 ;;
    esac
}

get_ip_v4v6() {
    # Get IPv4 and IPv6 addresses from ip.sb
    v4=$(curl -s4m6 ip.sb -k)
    v6=$(curl -s6m6 ip.sb -k)
    # Alternative sources for IP addresses (commented out)
    # v6=$(curl -s6m6 api64.ipify.org -k)
    # v4=$(curl -s4m6 api64.ipify.org -k)
}

mtu_warp() {
    get_ip_v4v6
    echo "Starting automatic MTU optimization for WARP network to improve network throughput!"
    MTUy=1500  # Initial MTU value (default for Ethernet)
    MTUc=10    # Increment for MTU testing

    # Check if the system is using IPv6 but not IPv4
    if [[ -n $v6 && -z $v4 ]]; then
        ping='ping6'
        IP1='2606:4700:4700::1111'
        IP2='2001:4860:4860::8888'
    else
        ping='ping'
        IP1='1.1.1.1'
        IP2='8.8.8.8'
    fi
    
    # Loop to find the optimal MTU value
    while true; do
        if ${ping} -c1 -W1 -s$((${MTUy} - 28)) -Mdo ${IP1} >/dev/null 2>&1 || ${ping} -c1 -W1 -s$((${MTUy} - 28)) -Mdo ${IP2} >/dev/null 2>&1; then
            MTUc=1  # If ping succeeds, increase MTU by 1
            MTUy=$((${MTUy} + ${MTUc}))
        else
            MTUy=$((${MTUy} - ${MTUc}))  # If ping fails, decrease MTU by 1
            [[ ${MTUc} = 1 ]] && break  # Stop loop if MTU size is stable
        fi

        # If MTU value is less than or equal to 1360, set it to 1360 and exit
        [[ ${MTUy} -le 1360 ]] && MTUy='1360' && break
    done

    # Adjust the MTU value by subtracting 80 to account for headers
    MTU=$((${MTUy} - 80))

    # Print the final MTU value in green
    LOGN "Optimal MTU value for network throughput = $MTU has been set."
}

mtu_transfer() {
    backup_mtu=$(grep -Po '(?<=^MTU = )\d+' "$wgcf_dir/backup-profile.conf")
    if [[ -z $backup_mtu ]]; then
        backup_mtu=1480
    fi
    sed -i "s/^MTU = .*/MTU = $backup_mtu/" "$wgcf_dir/$wgcf_profile"
}

get_latest_wgcf() {
    local tmp_file
    tmp_file="$(mktemp)"

    if ! curl -Ls -H "Accept: application/vnd.github.v3+json" -o "$tmp_file" "https://api.github.com/repos/ViRb3/wgcf/releases/latest"; then
      rm "$tmp_file"
      LOGE "Failed to get release list, please check your network."
      exit 1
    fi
    tag_version=$(grep '"tag_name":' "$tmp_file" | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$tag_version" ]]; then
      if grep -q "API rate limit exceeded" "$tmp_file"; then
        LOGE "github API rate limit exceeded"
      else
        LOGE "Failed to fetch xray version. Please try again later"
      fi
      rm "$tmp_file"
      exit 1
    fi
    rm "$tmp_file"
}

check_absence_wgcf() {
    if [ -f "$wgcf_bin" ]; then
        LOGI "Warp is already installed."
        exit 0
    fi
}

check_existence_wgcf() {
    if [ ! -f "$wgcf_bin" ] || [ ! -f "$wgcf_dir/$wgcf_profile" ]; then
        LOGW "Warp is not installed, Please install Warp first."
        wgcf_menu
        return 1
    else
        return 0
    fi
}

wgcf_get_configuration() {
    private_key=$(grep 'PrivateKey' "$wgcf_dir/$wgcf_profile" | cut -d' ' -f3)
    address=$(grep 'Address' "$wgcf_dir/$wgcf_profile" | cut -d' ' -f3- | awk -F', ' '{for(i=1;i<=NF;i++) if($i ~ /:/) print $i}')
    mtu=$(grep 'MTU' "$wgcf_dir/$wgcf_profile" | cut -d' ' -f3)
}

wgcf_status() {
    if [ -f "$wgcf_dir/$wgcf_account" ]; then
        st_output=$($wgcf_bin --config "$wgcf_dir/$wgcf_account" status 2>&1)
        st_device_name=$(echo "$st_output" | awk -F': +' '/Device name/ {print $2}')
        st_device_model=$(echo "$st_output" | awk -F': +' '/Device model/ {print $2}')
        st_device_active=$(echo "$st_output" | awk -F': +' '/Device active/ {print $2}')
        st_account_type=$(echo "$st_output" | awk -F': +' '/Account type/ {print $2}')
        st_role=$(echo "$st_output" | awk -F': +' '/Role/ {print $2}')
        st_premium_data=$(echo "$st_output" | awk -F': +' '/Premium data/ {print $2}')
        st_quota=$(echo "$st_output" | awk -F': +' '/Quota/ {print $2}')

        echo -e "───────────────────────────────────────────────────────────"
        # Check if the Account type is "limited" and print a message
        if [[ "$st_account_type" == "limited" ]]; then
            echo -e "${orange}You are using Warp+${plain}\n"
        else
            echo -e "You are using free Warp\n"
        fi
        echo -e "Device name   : ${orange}$st_device_name${plain}"
        echo -e "Device model  : ${orange}$st_device_model${plain}"
        echo -e "Device active : ${orange}$st_device_active${plain}"
        echo -e "Account type  : ${orange}$st_account_type${plain}"
        echo -e "Role          : ${orange}$st_role${plain}"
        echo -e "Premium data  : ${orange}$st_premium_data${plain}"
        echo -e "Quota         : ${orange}$st_quota${plain}\n"
        wgcf_get_configuration
        echo -e "${white_i}Installed Warp Details:${plain}"
        echo -e "${orange}PrivateKey:${plain} $private_key"
        echo -e "${orange}Address:${plain} $address"
        echo -e "${orange}MTU:${plain} $mtu"
        echo -e "───────────────────────────────────────────────────────────"
    else
        LOGW "Account file not found, Please reinstall warp."
    fi
}

register_warp() {
    echo "Registering Warp account..."
    attempts=0
    max_attempts=5
    # Loop for registration attempts
    until [[ -e "$wgcf_account" || $attempts -ge $max_attempts ]]; do
        wgcf_cmd=$(echo | $wgcf_bin register 2>&1)
        if echo "$wgcf_cmd" | grep -q "Successfully created"; then
            LOGN "Warp has been successfully created."
            return 0
        else
            attempts=$((attempts + 1))
            if [[ $attempts -lt $max_attempts ]]; then
                echo "Attempt $attempts failed. Retrying... (max attempts: $max_attempts)"
                LOGW "During the application of warp ordinary account, you may be prompted multiple times: 429 Too Many Requests, please wait few seconds" && sleep 1
                echo | $wgcf_bin register --accept-tos
            fi
        fi
    done
    return 1
}

# Function to install Warp
install_warp() {
    echo -e "arch: ${color_100}$(arch_wgcf)${plain}"
    LOGI "Installing Warp..."
    cd /root/
    temp_dir="$(mktemp -d)"
    wgcf_file="${temp_dir}/wgcf"

    get_latest_wgcf
    wget --no-check-certificate -O "$wgcf_file" "https://github.com/ViRb3/wgcf/releases/download/${tag_version}/wgcf_${tag_version#v}_linux_$(arch_wgcf)"
    if [[ $? -ne 0 ]]; then
        LOGE "Downloading Xray core failed, ensure your server can access GitHub"
        rm -rf "$temp_dir"
        exit 1
    fi
    install -D "$wgcf_file" "$wgcf_bin"
    chmod +x "$wgcf_bin"
    register_warp

    if [[ $? -ne 0 ]]; then
        LOGE "Failed to register Warp account after $max_attempts attempts, Try again later."
        rm -rf "$temp_dir"
        rm -f "$wgcf_bin"
        exit 1
    fi

    echo "Generating Warp profile..."
    wgcf_cmd=$("$wgcf_bin" generate 2>&1)
    if echo "$wgcf_cmd" | grep -q "Successfully generated"; then
        LOGN "Successfully generated Warp profile"
    else
        rm -rf "$temp_dir"
        rm -f "$wgcf_bin" "$wgcf_account"
        LOGW "Failed, try again later."
        exit 1
    fi
    mtu_warp
    sed -i "s/MTU.*/MTU = $MTU/g" "$wgcf_profile"
    install -D "$wgcf_account" "$wgcf_dir/backup-account.toml"
    install -D "$wgcf_profile" "$wgcf_dir/backup-profile.conf"
    mv -f "$wgcf_profile" "$wgcf_dir" >/dev/null 2>&1
    mv -f "$wgcf_account" "$wgcf_dir" >/dev/null 2>&1
    wgcf_status
    LOGI "Warp installed successfully.\n"
    rm -rf "$temp_dir"
}

get_back() {
    echo "Registration failed. Trying to get back to the free account."
    cp "$wgcf_dir/backup-account.toml" "$wgcf_dir/$wgcf_account"

    wgcf_cmd=$($wgcf_bin --config "$wgcf_dir/$wgcf_account" generate 2>&1)
    if [[ $? -eq 0 ]]; then
        mtu_transfer
        echo "Return to free account successfully completed."
        upgrade_warp_plus
    else
        echo "Failed to switch back to free account, Please reinstall warp"
        exit 1
    fi
}

# Function to upgrade to Warp+
upgrade_warp_plus() {
    plus_status=$($wgcf_bin --config "$wgcf_dir/$wgcf_account" status 2>&1)
    account_type=$(echo "$plus_status" | awk -F': +' '/Account type/ {print $2}')

    if [[ $account_type == "limited" ]]; then
        echo "Warp+ is installed. No need to upgrade again."
        return
    fi

    while true; do
        echo -n "Enter Warp+ license (or 0 to go back): "
        read -r license
        if [[ $license == "0" ]]; then
            return
        fi
        # Validate the license
        if [[ ${#license} -eq 26 && $license =~ ^[a-zA-Z0-9-]+$ ]]; then
            break  # Exit loop if the license is valid
        else
            echo "Invalid license. Please enter a valid Warp+ license."
        fi
    done

    rm -f "$wgcf_dir/$wgcf_account" >/dev/null 2>&1
    rm -f "$wgcf_dir/$wgcf_profile" >/dev/null 2>&1
    cd "$wgcf_dir"
    register_warp

    if [[ $? -ne 0 ]]; then
        get_back
    fi

    sed -i "s|license_key = .*|license_key = '$license'|" "$wgcf_dir/$wgcf_account"
    wgcf_cmd=$($wgcf_bin --config "$wgcf_dir/$wgcf_account" update 2>&1)
    if echo "$wgcf_cmd" | grep -q "Successfully updated"; then
        wgcf_cmd=$("$wgcf_bin" --config "$wgcf_dir/$wgcf_account" generate >/dev/null 2>&1)
        mtu_transfer
        echo "Warp has been successfully upgraded to Warp+."
    else
        echo "Failed, use another license."
        get_back
    fi
}

wgcf_outbound_json() {
    wgcf_get_configuration
    # Generate and display JSON structure
    echo -e "${teal_i}    {
      \"tag\": \"warp\",
      \"protocol\": \"wireguard\",
      \"settings\": {
        \"mtu\": $mtu,
        \"secretKey\": \"$private_key\",
        \"address\": [
          \"172.16.0.2/32\",
          \"$address\"
        ],
        \"domainStrategy\": \"ForceIPv4v6\",
        \"peers\": [
          {
            \"publicKey\": \"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=\",
            \"allowedIPs\": [
              \"0.0.0.0/0\",
              \"::/0\"
            ],
            \"endpoint\": \"engage.cloudflareclient.com:2408\"
          }
        ]
      }
    }${plain}"
    exit 0
}

# Function to uninstall Warp
uninstall_warp() {
    confirm "Are you sure you want to uninstall the Warp?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            wgcf_menu
        fi
        return 0
    fi
    rm -f "$wgcf_bin"
    rm -fr "$wgcf_dir"
    LOGI "Warp removed successfully."
    exit 0
}

wgcf_menu() {
    echo -e "\t${orange}Warp Management${plain}"
    echo -e "\t${orange}1.${plain} Status"
    echo -e "\t${orange}2.${plain} Install Warp (wgcf)"
    echo -e "\t${orange}3.${plain} Warp Plus"
    echo -e "\t${orange}4.${plain} Warp Outbound (json)"
    echo -e "\t${orange}5.${plain} Uninstall Warp"
    echo -e "\t${orange}0.${plain} Back to Main Menu"
    echo -n "Select an option: "
    read -r option

    case $option in
        0)
            show_menu
            ;;
        1)
            check_existence_wgcf && wgcf_status
            wgcf_menu
            ;;
        2)
            check_absence_wgcf && install_warp
            wgcf_menu
            ;;
        3)
            check_existence_wgcf && upgrade_warp_plus
            wgcf_menu
            ;;
        4)
            check_existence_wgcf && wgcf_outbound_json
            ;;
        5)
            check_existence_wgcf && uninstall_warp
            ;;
        *)
            LOGE "Invalid option. Please try again."
            wgcf_menu
            ;;
    esac
}

install_cron() {
    echo -e "The OS release is: ${color_100}$release${plain}"
    case "$release" in
    ubuntu | debian | armbian)
        apt-get update && apt-get install --no-install-recommends -y -q cron
        ;;
    *)
        LOGE "Your operating system is not supported"
        exit 1
        ;;
    esac

    if command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1; then
        LOGN "Cron is installed."
    else
        LOGE "Failed to install Cron. Please install it manually."
        exit 1
    fi
}

# Function to check if a cron job exists
check_cron() {
    local cron_line
    cron_line=$(crontab -l 2>/dev/null | grep "$cron_cmd")
    if [[ -n "$cron_line" ]]; then
        local cron_interval
        cron_interval=$(echo "$cron_line" | awk -F'/' '{print $2}' | awk '{print $1}')
        echo -e "Cron job: ${green_b}Active${green} (Every $cron_interval minutes)${plain}"
    else
        echo -e "Cron job: ${yellow}not active${plain}"
    fi
}

# Function to add a cron job
add_cron() {
    local cron_interval
    while true; do
        echo -ne "Enter a number between 1 and 30 - ${blue}default is every minute${plain} (or 0 to exit):"
        read -r input
        if [[ "$input" == "0" ]]; then
            echo "Exiting..."
            exit 0
        elif [[ -z "$input" ]]; then
            cron_interval=1
            break
        elif [[ "$input" =~ ^[0-9]+$ ]] && ((input >= 1 && input <= 30)); then
            cron_interval=$input
            break
        else
            echo "The number is not between 1 and 30."
        fi
    done
    install_cron
    # Remove existing cron job if it exists
    crontab -l 2>/dev/null | grep -v "$cron_cmd" | crontab -
    # Add new cron job
    (crontab -l 2>/dev/null; echo "*/$cron_interval * * * * $cron_cmd") | crontab -
    if [[ $? == 0 ]]; then
        LOGI "Cron job added successfully"
        before_show_menu
    fi
}

# Function to remove a cron job
remove_cron() {
    if crontab -l 2>/dev/null | grep -q "$cron_cmd"; then
        crontab -l 2>/dev/null | grep -v "$cron_cmd" | crontab -
        LOGI "Cron job removed successfully."
    else
        LOGW "No cron job found to remove."
    fi
}

cron_menu() {
    while true; do
        echo -e "\t${blue}1.${plain} Add cron job"
        echo -e "\t${blue}2.${plain} Remove cron"
        echo -e "\t${blue}0.${plain} Return to the menu"
        echo -n "Enter your choice: "
        read -r choice

        case $choice in
            0)
                show_menu
                ;;
            1)
                add_cron
                ;;
            2)
                remove_cron
                ;;
            *)
                echo "Invalid choice. Please try again."
                ;;
        esac
    done
}

show_menu() {
    echo -e "╔═══════════════════════════════╗
║   ${color_100} _______  __${plain}                ║
║   ${color_100}/_  __/ |/_/${color_200}___${color_300}___ _${color_400}__ __${plain}   ║
║   ${color_100} / / _>  </${color_200} __/${color_300} _ \`${color_400}/ // /${plain}   ║
║   ${color_100}/_/ /_/|_/${color_200}_/  ${color_300}\_,_/${color_400}\_, /${plain}    ║
║                     ${color_400}/___/${plain}     ║
║   ${white_i}TXray Script${plain}                ║
║   ${color_100}0.${plain} Exit Script              ║
║───────────────────────────────║
║   ${color_100}1.${plain} Install                  ║
║   ${color_100}2.${plain} Update                   ║
║   ${color_100}3.${plain} Update Menu              ║
║   ${color_100}4.${plain} Another Version          ║
║   ${color_100}5.${plain} Uninstall                ║
║───────────────────────────────║
║   ${color_100}6.${plain} Start                    ║
║   ${color_100}7.${plain} Stop                     ║
║   ${color_100}8.${plain} Restart                  ║
║   ${color_100}9.${plain} Check Status             ║
║  ${color_100}10.${plain} Logs Management          ║
║───────────────────────────────║
║  ${color_100}11.${plain} Enable Autostart         ║
║  ${color_100}12.${plain} Disable Autostart        ║
║───────────────────────────────║
║  ${color_100}13.${plain} Enable BBR               ║
║  ${color_100}14.${plain} Update Geo Files         ║
║  ${color_100}15.${plain} Warp (wgcf)              ║
║  ${color_100}16.${plain} Cron (for access.log)    ║
╚═══════════════════════════════╝
"
    show_status
    echo && read -p "Please enter your selection [0-14]: " num

    case "${num}" in
    0)
        exit 0
        ;;
    1)
        check_uninstall && install_txray
        ;;
    2)
        check_install && update
        ;;
    3)
        check_install && update_menu
        ;;
    4)
        another_version
        ;;
    5)
        check_install && uninstall
        ;;
    6)
        check_install && start
        ;;
    7)
        check_install && stop
        ;;
    8)
        check_install && restart
        ;;
    9)
        check_install && status
        ;;
    10)
        check_install && show_log
        ;;
    11)
        check_install && enable
        ;;
    12)
        check_install && disable
        ;;
    13)
        bbr_menu
        ;;
    14)
        check_install && update_geo
        ;;
    15)
        wgcf_menu
        ;;
    16)
        check_install && cron_menu
        ;;
    *)
        LOGE "Please enter the correct number [0-14]"
        ;;
    esac
}

if [[ $# > 0 ]]; then
    case $1 in
    "start")
        check_install 0 && start 0
        ;;
    "stop")
        check_install 0 && stop 0
        ;;
    "restart")
        check_install 0 && restart 0
        ;;
    "status")
        check_install 0 && status 0
        ;;
    "settings")
        check_install 0 && check_config 0
        ;;
    "enable")
        check_install 0 && enable 0
        ;;
    "disable")
        check_install 0 && disable 0
        ;;
    "log")
        check_install 0 && show_log 0
        ;;
    "update")
        check_install 0 && update 0
        ;;
    "another")
        another_version 0
        ;;
    "install")
        check_uninstall 0 && install_txray 0
        ;;
    "uninstall")
        check_install 0 && uninstall 0
        ;;
    *) show_usage ;;
    esac
else
    show_menu
fi