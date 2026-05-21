#!/bin/bash

# [Constants: colors]
red='\033[31m'
green='\033[32m'
yellow='\033[33m'
blue='\033[34m'
white='\033[97m'
teal='\033[38;5;6m'
orange='\033[38;5;208m'
plain='\033[0m'
color_100='\033[38;5;201m'
color_200='\033[38;5;164m'
color_300='\033[38;5;127m'
color_400='\033[38;5;90m'
bold_text='\033[1m'
italic_text='\033[3m'

# [Constants: WARP/wgcf]
wgcf_bin="/usr/bin/wgcf"
wgcf_account="wgcf-account.toml"
wgcf_profile="wgcf-profile.conf"
wgcf_dir="/etc/txray-wgcf"

# [Constants: cron]
cron_file="/var/log/xray/access.log"
cron_cmd="truncate -s 0 \"$cron_file\""

# [Runtime proxy]
# Optional session-wide proxy. Examples:
#   TXRAY_PROXY="socks5h://127.0.0.1:1080" txray install
#   TXRAY_PROXY="http://127.0.0.1:8080" txray update
txray_proxy="${TXRAY_PROXY:-}"

# [Logging and generic helpers]
function LOGI() {
    echo -e "${plain}[INF] $* ${plain}" >&2
}

function LOGN() {
    echo -e "${blue}[NOT] $* ${plain}" >&2
}

function LOGW() {
    echo -e "${yellow}[WRN] $* ${plain}" >&2
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}" >&2
}

function LOGS() {
    echo -e "${green}[SUC] $* ${plain}" >&2
}

function DIE() {
    LOGE "$*"
    exit 1
}

curl_txray() {
    if [[ -n "$txray_proxy" ]]; then
        curl --proxy "$txray_proxy" "$@"
    else
        curl "$@"
    fi
}

trim_value() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    printf '%s\n' "$value"
}

normalize_proxy_url() {
    local proxy
    local scheme
    local scheme_lc
    local rest

    proxy="$(trim_value "$1")"

    if [[ -z "$proxy" ]]; then
        return 1
    fi

    if [[ "$proxy" == *"://"* ]]; then
        scheme="${proxy%%://*}"
        rest="${proxy#*://}"
        scheme_lc="$(printf '%s' "$scheme" | tr '[:upper:]' '[:lower:]')"

        case "$scheme_lc" in
        http | https | socks4 | socks4a | socks5 | socks5h)
            printf '%s://%s\n' "$scheme_lc" "$rest"
            ;;
        *)
            printf '%s\n' "$proxy"
            ;;
        esac
    else
        printf 'http://%s\n' "$proxy"
    fi
}

validate_proxy_url() {
    local proxy="$1"
    local scheme
    local rest
    local host
    local port

    if [[ -z "$proxy" ]]; then
        LOGE "Proxy cannot be empty."
        return 1
    fi

    if [[ "$proxy" =~ [[:space:]] ]]; then
        LOGE "Proxy URL must not contain spaces."
        return 1
    fi

    case "$proxy" in
    http://* | https://* | socks4://* | socks4a://* | socks5://* | socks5h://*)
        ;;
    *)
        LOGE "Unsupported proxy scheme. Use http://, https://, socks4://, socks4a://, socks5://, or socks5h://."
        return 1
        ;;
    esac

    scheme="${proxy%%://*}"
    rest="${proxy#*://}"

    if [[ -z "$rest" ]]; then
        LOGE "Proxy host is missing."
        return 1
    fi

    # Remove optional credentials. For credentials containing '@', users should URL-encode it as %40.
    if [[ "$rest" == *@* ]]; then
        rest="${rest##*@}"
    fi

    if [[ "$rest" == */* || "$rest" == *\?* || "$rest" == *#* ]]; then
        LOGE "Proxy URL must not include a path, query string, or fragment."
        return 1
    fi

    if [[ "$rest" == \[* ]]; then
        # IPv6 format must be exactly: [::1]:1080
        if [[ "$rest" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        else
            LOGE "IPv6 proxy hosts must use brackets and include a port. Example: socks5h://[::1]:1080"
            return 1
        fi
    else
        host="${rest%:*}"
        port="${rest##*:}"
    fi

    if [[ -z "$host" || "$host" == "$rest" ]]; then
        LOGE "Proxy host or port is missing. Example: socks5h://127.0.0.1:1080"
        return 1
    fi

    if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
        LOGE "Proxy port must be a number."
        return 1
    fi

    if (( port < 1 || port > 65535 )); then
        LOGE "Proxy port must be between 1 and 65535."
        return 1
    fi

    if [[ "$host" == *":"* && "$proxy" != *"://["* ]]; then
        LOGE "IPv6 proxy hosts must use brackets. Example: socks5h://[::1]:1080"
        return 1
    fi

    case "$scheme" in
    http | https | socks4 | socks4a | socks5 | socks5h)
        ;;
    *)
        LOGE "Unsupported proxy scheme."
        return 1
        ;;
    esac

    return 0
}

set_proxy_interactive() {
    local input
    local normalized_proxy

    echo "Supported proxy examples:"
    echo "  http://127.0.0.1:8080"
    echo "  http://user:password@127.0.0.1:8080"
    echo "  socks5h://127.0.0.1:1080"
    echo "  socks5h://user:password@127.0.0.1:1080"
    echo "  socks5h://[::1]:1080"
    echo
    read -r -p "Enter proxy URL: " input

    if [[ -z "$input" ]]; then
        LOGW "Proxy was not changed because no value was entered."
        return 1
    fi

    normalized_proxy="$(normalize_proxy_url "$input")" || {
        LOGE "Invalid proxy value."
        return 1
    }

    validate_proxy_url "$normalized_proxy" || return 1

    txray_proxy="$normalized_proxy"
    export TXRAY_PROXY="$txray_proxy"
    LOGS "Proxy enabled for this script session: $txray_proxy"
}

clear_proxy() {
    txray_proxy=""
    unset TXRAY_PROXY
    LOGS "Proxy disabled for this script session."
}

show_proxy_status() {
    if [[ -n "$txray_proxy" ]]; then
        echo -e "Proxy: ${bold_text}${green}Active${plain} (${txray_proxy})"
    else
        echo -e "Proxy: ${yellow}Disabled${plain}"
    fi
}

test_proxy() {
    if [[ -z "$txray_proxy" ]]; then
        LOGW "Proxy is not configured."
        return 1
    fi

    validate_proxy_url "$txray_proxy" || return 1

    if curl_txray -4fsSL --connect-timeout 10 https://api.github.com >/dev/null; then
        LOGS "Proxy test passed."
    else
        LOGE "Proxy test failed. Check the proxy address, port, credentials, and network access."
        return 1
    fi
}

initialize_proxy() {
    local normalized_proxy

    if [[ -z "$txray_proxy" ]]; then
        return 0
    fi

    normalized_proxy="$(normalize_proxy_url "$txray_proxy")" || DIE "Invalid TXRAY_PROXY value."
    validate_proxy_url "$normalized_proxy" || DIE "Invalid TXRAY_PROXY value."

    txray_proxy="$normalized_proxy"
    export TXRAY_PROXY="$txray_proxy"
}

download_file() {
    local output="$1"
    local url="$2"

    if [[ -z "$output" || -z "$url" ]]; then
        LOGE "download_file requires an output path and a URL."
        return 1
    fi

    curl_txray -4fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$output" "$url"
}

download_file_if_modified() {
    local output="$1"
    local url="$2"

    if [[ -z "$output" || -z "$url" ]]; then
        LOGE "download_file_if_modified requires an output path and a URL."
        return 1
    fi

    if [[ -f "$output" ]]; then
        curl_txray -4fLR -z "$output" --retry 3 --retry-delay 2 --connect-timeout 15 -o "$output" "$url"
    else
        curl_txray -4fLR --retry 3 --retry-delay 2 --connect-timeout 15 -o "$output" "$url"
    fi
}

verify_xray_archive() {
    local archive="$1"
    local digest_url="$2"
    local digest_file="${archive}.dgst"
    local expected_sha256=""
    local actual_sha256=""

    if [[ ! -f "$archive" ]]; then
        LOGE "Cannot verify Xray archive because the file does not exist: $archive"
        return 1
    fi

    if ! command -v sha256sum >/dev/null 2>&1; then
        LOGW "sha256sum is not available; skipping checksum verification."
        return 0
    fi

    if ! download_file "$digest_file" "$digest_url"; then
        LOGW "Could not download the Xray checksum file; continuing without checksum verification."
        rm -f "$digest_file"
        return 0
    fi

    expected_sha256="$(awk -F '= ' 'tolower($1) == "sha2-256" {print $2; exit}' "$digest_file" | tr -d '\r')"
    if [[ ! "$expected_sha256" =~ ^[a-fA-F0-9]{64}$ ]]; then
        LOGW "Checksum file did not contain a SHA-256 value; continuing without checksum verification."
        rm -f "$digest_file"
        return 0
    fi

    actual_sha256="$(sha256sum "$archive" | awk '{print $1}')"
    rm -f "$digest_file"

    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        rm -f "$archive"
        LOGE "Xray checksum verification failed. The downloaded archive has been removed."
        return 1
    fi

    LOGS "Xray checksum verification passed."
}

ensure_linux() {
    if [[ "$(uname)" != "Linux" ]]; then
        LOGE "This operating system is not supported by this script.\n"
        echo "Supported operating systems:"
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
}

detect_release() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        release="$ID"
    elif [[ -f /usr/lib/os-release ]]; then
        # shellcheck disable=SC1091
        source /usr/lib/os-release
        release="$ID"
    else
        DIE "Failed to detect the operating system."
    fi

    echo -e "Detected OS release: ${color_100}${release}${plain}"
}

ensure_root() {
    (( EUID == 0 )) || DIE "You must run this script as root."
}

# [Initialization]
ensure_root
ensure_linux
initialize_proxy
detect_release

# [Architecture helpers]

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
        *)
            LOGE "Unsupported CPU architecture."
            return 1
            ;;
    esac
}

# [Base dependency installation]

install_base() {
    case "${release}" in
    ubuntu | debian | armbian)
        apt-get update && apt-get install -y -q curl tar tzdata unzip
        ;;
    centos | almalinux | rocky | ol)
        yum -y update && yum install -y -q curl tar tzdata unzip
        ;;
    fedora | amzn)
        dnf -y update && dnf install -y -q curl tar tzdata unzip
        ;;
    arch | manjaro | parch)
        pacman -Syu && pacman -Syu --noconfirm curl tar tzdata unzip
        ;;
    opensuse-tumbleweed)
        zypper refresh && zypper -q install -y curl tar timezone unzip
        ;;
    *)
        apt-get update && apt install -y -q curl tar tzdata unzip
        ;;
    esac
}


# [Interactive helpers]

confirm() {
    local answer

    if (( $# > 1 )); then
        echo && read -r -p "$1 [Default $2]: " answer
        if [[ -z "$answer" ]]; then
            answer="$2"
        fi
    else
        read -r -p "$1 [y/n]: " answer
    fi

    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

confirm_restart() {
    if confirm "Restart Xray Core" "y"; then
        restart
    fi
}

before_show_menu() {
    local _unused
    echo && echo -ne "${yellow}Press enter to return to the main menu: ${plain}" && read -r _unused
}

# [Xray versioning and installation]

extracting() {
    local archive="$1"
    local target_dir="$2"

    if [[ -z "$archive" || -z "$target_dir" ]]; then
        LOGE "extracting requires an archive path and a target directory."
        return 1
    fi

    if ! unzip -q "$archive" -d "$target_dir"; then
        LOGE "Xray extraction failed."
        rm -rf "$target_dir"
        LOGN "Removed: $target_dir"
        return 1
    fi

    LOGN "Extracted the Xray package to $target_dir and prepared it for installation."
}

get_current_version() {
    local current_version=""

    if [[ -f '/usr/local/xray/xray-linux' ]]; then
        current_version="$(/usr/local/xray/xray-linux -version | awk 'NR==1 {print $2}')"
        current_version="v${current_version#v}"
    fi

    printf '%s\n' "$current_version"
}

version_gt() {
    test "$(echo -e "$1\\n$2" | sort -V | head -n 1)" != "$1"
}

get_latest_version() {
    local tmp_file
    local latest_version
    tmp_file="$(mktemp)"

    if ! curl_txray -4fsSL -H "Accept: application/vnd.github.v3+json" -o "$tmp_file" "https://api.github.com/repos/XTLS/Xray-core/releases/latest"; then
        rm -f "$tmp_file"
        LOGE "Failed to get the Xray release list. Please check your network or proxy settings."
        return 1
    fi

    latest_version="$(sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$tmp_file" | head -n 1 | tr -d '\r')"
    if [[ -z "$latest_version" ]]; then
        if grep -q "API rate limit exceeded" "$tmp_file"; then
            LOGE "GitHub API rate limit exceeded."
        else
            LOGE "Failed to fetch the Xray version. Please try again later."
        fi
        rm -f "$tmp_file"
        return 1
    fi

    if [[ ! "$latest_version" =~ ^v?[0-9][A-Za-z0-9._-]*$ ]]; then
        LOGE "Unexpected Xray release tag received from GitHub: $latest_version"
        rm -f "$tmp_file"
        return 1
    fi

    rm -f "$tmp_file"
    printf '%s\n' "$latest_version"
}

install_xray() {
    local arch_name
    local tmp_directory
    local zip_file
    local xray_dir="/usr/local/xray"
    local json_dir="/etc/xray"
    local tag_version
    local url
    local geoip_status=0
    local geosite_status=0

    if ! arch_name="$(arch)"; then
        return 1
    fi

    echo -e "Detected OS release: ${blue}$release${plain}"
    echo -e "arch: ${blue}${arch_name}${plain}"
    if ! install_base; then
        LOGE "Failed to install required base dependencies."
        LOGE "If a proxy is required for apt/yum/dnf/pacman, configure the package manager proxy separately. TXRAY_PROXY only applies to curl downloads."
        return 1
    fi

    tmp_directory="$(mktemp -d)"
    zip_file="${tmp_directory}/Xray-linux-${arch_name}.zip"
    if ! cd /usr/local/; then
        LOGE "Failed to enter /usr/local."
        rm -rf "$tmp_directory"
        return 1
    fi

    if (( $# == 0 )); then
        if ! tag_version="$(get_latest_version)"; then
            rm -rf "$tmp_directory"
            LOGE "Installation stopped because the latest Xray version could not be resolved."
            return 1
        fi
        url="https://github.com/XTLS/Xray-core/releases/download/${tag_version}/Xray-linux-${arch_name}.zip"
        LOGN "Latest Xray version: [${tag_version}] Starting installation..."
    else
        tag_version="$1"
        url="https://github.com/XTLS/Xray-core/releases/download/${tag_version}/Xray-linux-${arch_name}.zip"
        LOGN "Xray selected version: [${tag_version}] Starting installation..."
    fi

    if ! download_file "$zip_file" "$url"; then
        LOGE "Downloading Xray Core ${tag_version} failed. Check network access, proxy settings, and whether this version exists."
        rm -rf "$tmp_directory"
        return 1
    fi

    if ! verify_xray_archive "$zip_file" "${url}.dgst"; then
        rm -rf "$tmp_directory"
        return 1
    fi

    if [[ -e "$xray_dir" ]]; then
        systemctl stop xray >/dev/null 2>&1 || true
        rm -rf "$xray_dir"
    fi

    if [[ ! -d "$xray_dir" ]]; then
        LOGN "Directory $xray_dir does not exist. Creating it..."
        install -d "$xray_dir" && LOGI "Directory $xray_dir created successfully."
    else
        LOGN "Directory $xray_dir already exists."
    fi

    if [[ ! -d "$json_dir" ]]; then
        LOGN "Directory $json_dir does not exist. Creating it..."
        install -d "$json_dir" && LOGI "Directory $json_dir created successfully."
    else
        LOGN "Directory $json_dir already exists."
    fi

    if ! extracting "$zip_file" "$tmp_directory"; then
        return 1
    fi

    if ! install -m 755 "$tmp_directory/xray" "$xray_dir/xray-linux" ||
       ! install -m 644 "$tmp_directory/geoip.dat" "$xray_dir" ||
       ! install -m 644 "$tmp_directory/geosite.dat" "$xray_dir"; then
        LOGE "Failed to install one or more Xray files from the extracted archive."
        rm -rf "$tmp_directory"
        return 1
    fi

    rm -rf "$tmp_directory"
    LOGN "Removed: $tmp_directory"

    LOGI "Downloading Geo files..."
    download_file "/usr/local/xray/geoip_IR.dat" "https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/geoip.dat"
    geoip_status=$?
    download_file "/usr/local/xray/geosite_IR.dat" "https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/geosite.dat"
    geosite_status=$?

    if (( geoip_status != 0 || geosite_status != 0 )); then
        LOGW "One or more geo data files failed to download. You can retry from menu option 14."
    fi

    if ! download_file "/usr/bin/txray" "https://raw.githubusercontent.com/tararostami/txray/main/txray.sh" || ! chmod +x /usr/bin/txray; then
        LOGW "Failed to install or update /usr/bin/txray. Xray Core was installed, but the TXray command may be unavailable."
    fi

    if [[ ! -f /etc/xray/config.json ]]; then
        cat > "${json_dir}/config.json" << EOF
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
        LOGN "Created config.json at /etc/xray/config.json"
    else
        LOGN "config.json already exists."
    fi

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

    if ! systemctl daemon-reload; then
        LOGE "Failed to reload systemd."
        return 1
    fi

    if ! systemctl enable xray; then
        LOGE "Failed to enable the Xray service."
        return 1
    fi

    if ! systemctl start xray; then
        LOGE "Failed to start the Xray service."
        return 1
    fi

    if ! check_status; then
        LOGE "Xray service did not report as running after start."
        return 1
    fi

    LOGS "Xray ${tag_version} installation completed and the service is running.\n"
    show_usage
    return 0
}

install_txray() {
    install_xray || return 1

    if (( $# == 0 )); then
        start
    else
        start 0
    fi
}

update() {
    local cur_ver
    local tag_version

    cur_ver="$(get_current_version)"
    if ! tag_version="$(get_latest_version)"; then
        LOGE "Update stopped because the latest Xray version could not be resolved."
        if (( $# == 0 )); then
            before_show_menu
        fi
        return 1
    fi

    if ! version_gt "$tag_version" "$cur_ver"; then
        LOGN "No new version. The current version of Xray is $cur_ver"
        if (( $# == 0 )); then
            before_show_menu
        fi
        return 0
    fi

    echo -e "\n${green}New version available: ${bold_text}${green}$tag_version${plain}"
    if ! confirm "This will reinstall the latest version without deleting your existing data. Do you want to continue?" "y"; then
        LOGE "Cancelled"
        if (( $# == 0 )); then
            before_show_menu
        fi
        return 0
    fi

    if install_xray "$tag_version"; then
        LOGS "Update completed. Xray has been restarted automatically."
        if (( $# == 0 )); then
            before_show_menu
        fi
        return 0
    fi

    return 1
}

update_menu() {
    LOGN "Updating TXray"
    if ! confirm "Do you want to update the TXray script?" "y"; then
        LOGE "Cancelled"
        if (( $# == 0 )); then
            before_show_menu
        fi
        return 0
    fi

    if download_file "/usr/bin/txray" "https://raw.githubusercontent.com/TaraRostami/txray/main/txray.sh" && chmod +x /usr/bin/txray; then
        LOGS "TXray has been updated successfully."
        before_show_menu
    else
        LOGE "Failed to update TXray."
        return 1
    fi
}

another_version() {
    local version_regex='^[0-9]+\.[0-9]+\.[0-9]+$'
    local tag_version

    while true; do
        echo -ne "Enter the Xray version ${yellow}(like: 24.11.11)${plain} or 0 to go back: "
        read -r tag_version

        tag_version="$(echo "$tag_version" | xargs)"

        if [[ "$tag_version" == "0" ]]; then
            return 0
        fi

        if [[ -z "$tag_version" ]]; then
            LOGW "Xray version cannot be empty."
            continue
        fi

        if [[ $tag_version =~ $version_regex ]]; then
            break
        else
            LOGW "Invalid version format. Please enter a version like: 24.11.11"
        fi
    done

    tag_version="v$tag_version"

    LOGN "Downloading and installing Xray version [${tag_version}]"

    if install_xray "$tag_version"; then
        LOGS "Xray Core version $tag_version installed successfully."
        if (( $# == 0 )); then
            before_show_menu
        fi
        return 0
    fi

    return 1
}

remove_script_file_if_requested() {
    local invoked_path="$0"
    local script_path

    confirm "Also remove the TXray script file that launched this command?" "n" || return 0

    case "$invoked_path" in
    bash | sh | -bash | -sh | /dev/fd/* | /proc/* | /bin/bash | /usr/bin/bash | /bin/sh | /usr/bin/sh)
        LOGW "Skipping script removal because the launch path is not a normal script file: $invoked_path"
        return 1
        ;;
    */*)
        script_path="$(readlink -f -- "$invoked_path" 2>/dev/null || printf '%s\n' "$invoked_path")"
        ;;
    *)
        script_path="$(command -v -- "$invoked_path" 2>/dev/null || printf '%s\n' "$invoked_path")"
        script_path="$(readlink -f -- "$script_path" 2>/dev/null || printf '%s\n' "$script_path")"
        ;;
    esac

    if [[ ! -f "$script_path" ]]; then
        LOGW "Skipping script removal because the file was not found: $script_path"
        return 1
    fi

    if rm -f -- "$script_path"; then
        LOGN "Removed script file: $script_path"
    else
        LOGW "Failed to remove script file: $script_path"
        return 1
    fi
}

# [Xray service lifecycle]

uninstall() {
    if ! confirm "Are you sure you want to uninstall the Xray?" "n"; then
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

    LOGS "Uninstalled successfully.\n"
    echo "To install again, use this command:"
    echo -e "${green}bash <(curl -Ls https://raw.githubusercontent.com/tararostami/txray/master/txray.sh)${plain}"

    remove_script_file_if_requested
    exit 0
}

start() {
    local result=0

    if check_status; then
        echo && LOGN "Xray is already running. Use restart if you need to reload it."
    else
        if ! systemctl start xray; then
            LOGE "Failed to start the Xray service."
            result=1
        else
            sleep 2
            if check_status; then
                LOGS "Xray started successfully."
            else
                LOGE "Xray did not report as running after two seconds. Check the service logs for details."
                result=1
            fi
        fi
    fi

    if (( $# == 0 )); then
        before_show_menu
    fi

    return "$result"
}

stop() {
    local status_result
    local result=0

    check_status
    status_result=$?

    if (( status_result == 1 )); then
        echo && LOGN "Xray is already stopped."
    else
        if ! systemctl stop xray; then
            LOGE "Failed to stop the Xray service."
            result=1
        else
            sleep 2
            check_status
            status_result=$?

            if (( status_result == 1 )); then
                LOGS "Xray stopped successfully."
            else
                LOGE "Xray did not stop within two seconds. Check the service logs for details."
                result=1
            fi
        fi
    fi

    if (( $# == 0 )); then
        before_show_menu
    fi

    return "$result"
}

restart() {
    local result=0

    if ! systemctl restart xray; then
        LOGE "Failed to restart the Xray service."
        result=1
    else
        sleep 2
        if check_status; then
            LOGS "Xray restarted successfully."
        else
            LOGE "Xray did not report as running after restart. Check the service logs for details."
            result=1
        fi
    fi

    if (( $# == 0 )); then
        before_show_menu
    fi

    return "$result"
}

status() {
    local result

    systemctl status xray -l
    result=$?

    if (( $# == 0 )); then
        before_show_menu
    fi

    return "$result"
}

enable() {
    local result=0

    if systemctl enable xray; then
        LOGS "Xray autostart has been enabled."
    else
        LOGE "Failed to enable Xray autostart."
        result=1
    fi

    if (( $# == 0 )); then
        before_show_menu
    fi

    return "$result"
}

disable() {
    local result=0

    if systemctl disable xray; then
        LOGS "Xray autostart has been disabled."
    else
        LOGE "Failed to disable Xray autostart."
        result=1
    fi

    if (( $# == 0 )); then
        before_show_menu
    fi

    return "$result"
}

show_log() {
    local choice

    while true; do
        echo -e "${green}\t1.${plain} Debug Log"
        echo -e "${green}\t2.${plain} Clear all logs"
        echo -e "${green}\t0.${plain} Back to Main Menu"
        read -r -p "Choose an option: " choice

        case "$choice" in
        0)
            return 0
            ;;
        1)
            journalctl -u xray -e --no-pager -f -p debug
            if (( $# == 0 )); then
                before_show_menu
            fi
            return 0
            ;;
        2)
            journalctl --rotate
            journalctl --vacuum-time=1s
            LOGS "All logs have been cleared."
            restart 0
            if (( $# == 0 )); then
                before_show_menu
            fi
            return 0
            ;;
        *)
            LOGE "Invalid option. Please select a valid number."
            ;;
        esac
    done
}

# [BBR management]

bbr_menu() {
    local choice

    while true; do
        echo -e "${green}\t1.${plain} Enable BBR"
        echo -e "${green}\t2.${plain} Disable BBR"
        echo -e "${green}\t0.${plain} Back to Main Menu"
        read -r -p "Choose an option: " choice

        case "$choice" in
        0)
            return 0
            ;;
        1)
            enable_bbr
            ;;
        2)
            disable_bbr
            ;;
        *)
            LOGE "Invalid option. Please select a valid number.\n"
            ;;
        esac
    done
}

disable_bbr() {
    local bbr_conf="/etc/sysctl.d/99-txray-bbr.conf"

    if [[ ! -f "$bbr_conf" ]] && ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
        LOGW "BBR is not currently enabled by TXray."
        before_show_menu
        return 0
    fi

    rm -f "$bbr_conf"

    if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^net.core.default_qdisc=fq/net.core.default_qdisc=pfifo_fast/' /etc/sysctl.conf
    fi

    if grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf
    fi

    sysctl --system >/dev/null 2>&1 || sysctl -p

    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "cubic" ]]; then
        LOGS "BBR has been disabled and CUBIC is now active."
    else
        LOGN "BBR configuration was removed. A reboot may be required for the new congestion control setting to take effect."
    fi

    return 0
}

enable_bbr() {
    local bbr_conf="/etc/sysctl.d/99-txray-bbr.conf"

    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
        LOGN "BBR is already active."
        before_show_menu
        return 0
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
        LOGE "Unsupported operating system. Please install the required packages manually."
        return 1
        ;;
    esac || {
        LOGE "Failed to install required packages for BBR."
        return 1
    }

    cat > "$bbr_conf" << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl --system >/dev/null 2>&1 || sysctl -p "$bbr_conf"

    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
        LOGS "BBR has been enabled successfully."
        return 0
    fi

    LOGE "Failed to enable BBR. Please check your system configuration."
    return 1
}

# [Status helpers]

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /etc/systemd/system/xray.service ]]; then
        return 2
    fi

    if systemctl is-active --quiet xray; then
        return 0
    fi

    return 1
}

check_enabled() {
    systemctl is-enabled --quiet xray
}

check_uninstall() {
    local status_result

    check_status
    status_result=$?

    if (( status_result != 2 )); then
        echo && LOGE "Xray Core is already installed. Please uninstall it before reinstalling."
        if (( $# == 0 )); then
            before_show_menu
        fi
        return 1
    fi

    return 0
}

check_install() {
    local status_result

    check_status
    status_result=$?

    if (( status_result == 2 )); then
        echo && LOGE "Please install Xray Core first."
        if (( $# == 0 )); then
            before_show_menu
        fi
        return 1
    fi

    return 0
}

show_status() {
    local status_result

    check_status
    status_result=$?
    if (( status_result != 2 )); then
        show_version_status
    fi
    case $status_result in
    0)
        echo -e "Xray state: ${bold_text}${green}Running${plain}"
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
    show_proxy_status
}

show_version_status() {
    local cur_ver

    cur_ver="$(get_current_version)"
    echo -e "Current Xray Core Version: ${bold_text}${green}$cur_ver${plain}"
}

show_enable_status() {
    if check_enabled; then
        echo -e "Autostart: ${bold_text}${green}Active${plain}"
    else
        echo -e "Autostart: ${red}Disabled${plain}"
    fi
}

# [Geo data management]

update_geo() {
    local choice

    while true; do
        echo -e "${green}\t1.${plain} Loyalsoldier (geoip.dat, geosite.dat)"
        echo -e "${green}\t2.${plain} Chocolate4U (geoip_IR.dat, geosite_IR.dat)"
        echo -e "${green}\t3.${plain} vuong2023 (geoip_VN.dat, geosite_VN.dat)"
        echo -e "${green}\t0.${plain} Back to Main Menu"
        read -r -p "Choose an option: " choice

        case "$choice" in
        0)
            return 0
            ;;
        1)
            if ! cd /usr/local/xray; then
                LOGE "Failed to enter /usr/local/xray."
                before_show_menu
                return 1
            fi
            systemctl stop xray >/dev/null 2>&1 || true
            rm -f geoip.dat geosite.dat
            download_file_if_modified "geoip.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" || LOGW "Failed to update geoip.dat."
            download_file_if_modified "geosite.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" || LOGW "Failed to update geosite.dat."
            LOGS "Loyalsoldier datasets have been updated."
            restart 0
            before_show_menu
            return 0
            ;;
        2)
            if ! cd /usr/local/xray; then
                LOGE "Failed to enter /usr/local/xray."
                before_show_menu
                return 1
            fi
            systemctl stop xray >/dev/null 2>&1 || true
            rm -f geoip_IR.dat geosite_IR.dat
            download_file_if_modified "geoip_IR.dat" "https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/geoip.dat" || LOGW "Failed to update geoip_IR.dat."
            download_file_if_modified "geosite_IR.dat" "https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/geosite.dat" || LOGW "Failed to update geosite_IR.dat."
            LOGS "Chocolate4U datasets have been updated."
            restart 0
            before_show_menu
            return 0
            ;;
        3)
            if ! cd /usr/local/xray; then
                LOGE "Failed to enter /usr/local/xray."
                before_show_menu
                return 1
            fi
            systemctl stop xray >/dev/null 2>&1 || true
            rm -f geoip_VN.dat geosite_VN.dat
            download_file_if_modified "geoip_VN.dat" "https://github.com/vuong2023/vn-v2ray-rules/releases/latest/download/geoip.dat" || LOGW "Failed to update geoip_VN.dat."
            download_file_if_modified "geosite_VN.dat" "https://github.com/vuong2023/vn-v2ray-rules/releases/latest/download/geosite.dat" || LOGW "Failed to update geosite_VN.dat."
            LOGS "vuong2023 datasets have been updated."
            restart 0
            before_show_menu
            return 0
            ;;
        *)
            LOGE "Invalid option. Please select a valid number.\n"
            ;;
        esac
    done
}

# [CLI usage]

show_usage() {
    echo -e "${bold_text}${italic_text}${white}TXray${plain} command usage: "
    echo -e "────────────────────────────────────────────────"
    echo -e "${color_100}txray${plain}              - Administration menu"
    echo -e "${color_100}txray start${plain}        - Start"
    echo -e "${color_100}txray stop${plain}         - Stop"
    echo -e "${color_100}txray restart${plain}      - Restart"
    echo -e "${color_100}txray status${plain}       - Current status"
    echo -e "${color_100}txray enable${plain}       - Enable autostart on OS startup"
    echo -e "${color_100}txray disable${plain}      - Disable autostart on OS startup"
    echo -e "${color_100}txray log${plain}          - View logs"
    echo -e "${color_100}txray update${plain}       - Update"
    echo -e "${color_100}txray another${plain}      - Install a specific version"
    echo -e "${color_100}txray install${plain}      - Install"
    echo -e "${color_100}txray uninstall${plain}    - Uninstall"
    echo -e "────────────────────────────────────────────────"
    echo -e "Optional Proxy:"
    echo -e "${color_100}TXRAY_PROXY=socks5h://127.0.0.1:1080 txray install${plain}"
    echo -e "────────────────────────────────────────────────"
}

# [WARP / wgcf management]

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
        *)
            LOGE "Unsupported WARP architecture."
            return 1
            ;;
    esac
}

calculate_warp_mtu() {
    local v4
    local v6
    local ping_cmd
    local ip_primary
    local ip_secondary
    local mtu_probe=1500
    local mtu_step=10
    local calculated_mtu

    v4="$(curl_txray -s4m6 ip.sb -k)"
    v6="$(curl_txray -s6m6 ip.sb -k)"

    if [[ -n "$v6" && -z "$v4" ]]; then
        ping_cmd='ping6'
        ip_primary='2606:4700:4700::1111'
        ip_secondary='2001:4860:4860::8888'
    else
        ping_cmd='ping'
        ip_primary='1.1.1.1'
        ip_secondary='8.8.8.8'
    fi

    while true; do
        if "$ping_cmd" -c1 -W1 -s$((mtu_probe - 28)) -Mdo "$ip_primary" >/dev/null 2>&1 || "$ping_cmd" -c1 -W1 -s$((mtu_probe - 28)) -Mdo "$ip_secondary" >/dev/null 2>&1; then
            mtu_step=1
            mtu_probe=$((mtu_probe + mtu_step))
        else
            mtu_probe=$((mtu_probe - mtu_step))
            (( mtu_step == 1 )) && break
        fi

        (( mtu_probe <= 1360 )) && mtu_probe=1360 && break
    done

    calculated_mtu=$((mtu_probe - 80))
    printf '%s\n' "$calculated_mtu"
}

mtu_transfer() {
    local backup_mtu

    backup_mtu="$(grep -Po '(?<=^MTU = )\d+' "$wgcf_dir/backup-profile.conf" 2>/dev/null)"
    if [[ -z "$backup_mtu" ]]; then
        backup_mtu=1280
    fi

    if [[ ! -f "$wgcf_dir/$wgcf_profile" ]]; then
        LOGE "WARP profile was not found: $wgcf_dir/$wgcf_profile"
        return 1
    fi

    sed -i "s/^MTU = .*/MTU = $backup_mtu/" "$wgcf_dir/$wgcf_profile"
}

get_latest_wgcf() {
    local tmp_file
    local latest_version
    tmp_file="$(mktemp)"

    if ! curl_txray -4fsSL -H "Accept: application/vnd.github.v3+json" -o "$tmp_file" "https://api.github.com/repos/ViRb3/wgcf/releases/latest"; then
        rm -f "$tmp_file"
        LOGE "Failed to get the wgcf release list. Please check your network or proxy settings."
        return 1
    fi

    latest_version="$(sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$tmp_file" | head -n 1 | tr -d '\r')"
    if [[ -z "$latest_version" ]]; then
        if grep -q "API rate limit exceeded" "$tmp_file"; then
            LOGE "GitHub API rate limit exceeded."
        else
            LOGE "Failed to fetch the wgcf version. Please try again later."
        fi
        rm -f "$tmp_file"
        return 1
    fi

    if [[ ! "$latest_version" =~ ^v?[0-9][A-Za-z0-9._-]*$ ]]; then
        LOGE "Unexpected wgcf release tag received from GitHub: $latest_version"
        rm -f "$tmp_file"
        return 1
    fi

    rm -f "$tmp_file"
    printf '%s\n' "$latest_version"
}

check_absence_wgcf() {
    if [[ -f "$wgcf_bin" ]]; then
        LOGN "WARP is already installed."
        return 1
    fi

    return 0
}

check_existence_wgcf() {
    if [[ ! -f "$wgcf_bin" || ! -f "$wgcf_dir/$wgcf_profile" ]]; then
        LOGW "WARP is not installed. Please install WARP first."
        return 1
    fi

    return 0
}

wgcf_get_configuration() {
    local private_key
    local address
    local mtu

    private_key="$(grep 'PrivateKey' "$wgcf_dir/$wgcf_profile" | cut -d' ' -f3)"
    address="$(grep 'Address' "$wgcf_dir/$wgcf_profile" | cut -d' ' -f3- | awk -F', ' '{for(i=1;i<=NF;i++) if($i ~ /:/) print $i}')"
    mtu="$(grep 'MTU' "$wgcf_dir/$wgcf_profile" | cut -d' ' -f3)"

    printf '%s\n%s\n%s\n' "$private_key" "$address" "$mtu"
}

wgcf_status() {
    local cfg="$wgcf_dir/$wgcf_account"
    if ! [ -f "$cfg" ]; then
        LOGW "Account file not found. Please reinstall WARP."
        return 1
    fi

    local raw rc cleaned account_type account_type_lc plan_line
    local private_key address mtu
    raw="$($wgcf_bin --config "$cfg" status 2>&1)"
    rc=$?
    (( rc == 0 )) || { echo -e "$raw"; return "$rc"; }

    cleaned="$(printf '%s\n' "$raw" | tail -n +3 | sed '/=/d')"

    account_type="$(printf '%s\n' "$cleaned" | awk -F':[[:space:]]*' '/^[[:space:]]*Account type[[:space:]]*:/ {print $2; exit}')"
    account_type_lc="$(printf '%s' "$account_type" | tr '[:upper:]' '[:lower:]')"

    if [[ "$account_type_lc" == "limited" || "$account_type_lc" == "warp+" || "$account_type_lc" == "plus" ]]; then
        plan_line="${orange}You are using WARP+${plain}"
    else
        plan_line="You are using free WARP"
    fi

    echo -e "───────────────────────────────────────────────────────────"
    echo -e "${plan_line}"

    printf '%s\n' "$cleaned" | awk -v o="$orange" -v p="$plain" -v b="$bold_text" '
      {
        if ($0 ~ /^[[:space:]]*(Account|Devices)[[:space:]]*$/) {
          print b o "[" $0 "]" p
          next
        }

        m = match($0, /:[[:space:]]+/)
        if (m) {
          left  = substr($0, 1, RSTART)
          right = substr($0, RSTART + RLENGTH)
          print left " " o right p
        } else {
          print $0
        }
      }
      END { print "" }
    '

    {
        IFS= read -r private_key
        IFS= read -r address
        IFS= read -r mtu
    } < <(wgcf_get_configuration)

    echo -e "${bold_text}${italic_text}${white}Installed WARP Details:${plain}"
    echo -e "${orange}PrivateKey:${plain} $private_key"
    echo -e "${orange}Address:${plain} $address"
    echo -e "${orange}MTU:${plain} $mtu"
    echo -e "───────────────────────────────────────────────────────────"
}

register_warp() {
    local attempts=0
    local max_attempts=5
    local wgcf_cmd

    LOGI "Registering WARP account..."

    until [[ -e "$wgcf_account" ]] || (( attempts >= max_attempts )); do
        wgcf_cmd="$(echo | "$wgcf_bin" register 2>&1)"
        if echo "$wgcf_cmd" | grep -q "Successfully created"; then
            LOGN "WARP account has been created successfully."
            return 0
        fi

        ((attempts++))
        if (( attempts < max_attempts )); then
            LOGW "Attempt $attempts failed. Retrying... (max attempts: $max_attempts)"
            LOGW "During WARP account registration, you may see repeated 429 Too Many Requests responses. Retrying shortly."
            sleep 1
            echo | "$wgcf_bin" register --accept-tos >/dev/null 2>&1 || true
        fi
    done

    return 1
}

# Function to install WARP
install_warp() {
    local wgcf_arch
    local temp_dir
    local wgcf_file
    local tag_version
    local wgcf_cmd
    local warp_mtu
    local previous_dir

    if ! wgcf_arch="$(arch_wgcf)"; then
        return 1
    fi

    echo -e "arch: ${color_100}${wgcf_arch}${plain}"

    LOGI "Installing WARP..."

    previous_dir="$(pwd -P 2>/dev/null || printf '/')"
    temp_dir="$(mktemp -d)"
    wgcf_file="${temp_dir}/wgcf"

    cd "$temp_dir" || {
        LOGE "Failed to enter temporary WARP working directory."
        rm -rf "$temp_dir"
        return 1
    }

    if ! tag_version="$(get_latest_wgcf)"; then
        cd "$previous_dir" >/dev/null 2>&1 || cd / >/dev/null 2>&1 || true
        rm -rf "$temp_dir"
        LOGE "WARP installation stopped because the latest wgcf version could not be resolved."
        return 1
    fi

    if ! download_file "$wgcf_file" "https://github.com/ViRb3/wgcf/releases/download/${tag_version}/wgcf_${tag_version#v}_linux_${wgcf_arch}"; then
        LOGE "Downloading WARP failed. Ensure this server can access GitHub or check proxy settings."
        cd "$previous_dir" >/dev/null 2>&1 || cd / >/dev/null 2>&1 || true
        rm -rf "$temp_dir"
        return 1
    fi

    if ! install -D "$wgcf_file" "$wgcf_bin" || ! chmod +x "$wgcf_bin"; then
        LOGE "Failed to install the wgcf binary."
        cd "$previous_dir" >/dev/null 2>&1 || cd / >/dev/null 2>&1 || true
        rm -rf "$temp_dir"
        rm -f "$wgcf_bin"
        return 1
    fi

    if ! register_warp; then
        LOGE "Failed to register the WARP account after repeated attempts. Please try again later."
        cd "$previous_dir" >/dev/null 2>&1 || cd / >/dev/null 2>&1 || true
        rm -rf "$temp_dir"
        rm -f "$wgcf_bin"
        return 1
    fi

    LOGI "Generating WARP profile..."
    wgcf_cmd="$("$wgcf_bin" generate 2>&1)"
    if echo "$wgcf_cmd" | grep -q "Successfully generated"; then
        LOGN "WARP profile generated successfully."
    else
        rm -f "$wgcf_bin" "$wgcf_account"
        cd "$previous_dir" >/dev/null 2>&1 || cd / >/dev/null 2>&1 || true
        rm -rf "$temp_dir"
        LOGW "Operation failed. Please try again later."
        return 1
    fi

    LOGI "Starting automatic MTU optimization for WARP network throughput."
    warp_mtu="$(calculate_warp_mtu)"
    if [[ -z "$warp_mtu" || ! "$warp_mtu" =~ ^[0-9]+$ ]]; then
        LOGE "Failed to calculate a valid WARP MTU value."
        cd "$previous_dir" >/dev/null 2>&1 || cd / >/dev/null 2>&1 || true
        rm -rf "$temp_dir"
        return 1
    fi
    LOGN "Optimal WARP MTU value has been set to $warp_mtu."
    if ! sed -i "s/MTU.*/MTU = $warp_mtu/g" "$wgcf_profile"; then
        LOGE "Failed to update the WARP profile MTU value."
        cd "$previous_dir" >/dev/null 2>&1 || cd / >/dev/null 2>&1 || true
        rm -rf "$temp_dir"
        return 1
    fi

    if ! install -D "$wgcf_account" "$wgcf_dir/backup-account.toml" ||
       ! install -D "$wgcf_profile" "$wgcf_dir/backup-profile.conf" ||
       ! mv -f "$wgcf_profile" "$wgcf_dir" >/dev/null 2>&1 ||
       ! mv -f "$wgcf_account" "$wgcf_dir" >/dev/null 2>&1; then
        LOGE "Failed to store WARP configuration files."
        cd "$previous_dir" >/dev/null 2>&1 || cd / >/dev/null 2>&1 || true
        rm -rf "$temp_dir"
        return 1
    fi

    cd "$previous_dir" >/dev/null 2>&1 || cd / >/dev/null 2>&1 || true
    rm -rf "$temp_dir"
    wgcf_status
    LOGS "WARP installed successfully.\n"
    return 0
}

get_back() {
    local wgcf_cmd

    LOGW "Registration failed. Restoring the free WARP account."
    if ! cp "$wgcf_dir/backup-account.toml" "$wgcf_dir/$wgcf_account"; then
        LOGE "Failed to restore the backup WARP account."
        return 1
    fi

    if wgcf_cmd="$("$wgcf_bin" --config "$wgcf_dir/$wgcf_account" generate 2>&1)"; then
        mtu_transfer
        LOGS "Returned to the free WARP account successfully."
        upgrade_warp_plus
    else
        echo "$wgcf_cmd"
        LOGE "Failed to switch back to the free account. Please reinstall WARP."
        return 1
    fi
}

# Function to upgrade to WARP+
upgrade_warp_plus() {
    local plus_status
    local account_type
    local license
    local wgcf_cmd

    plus_status="$($wgcf_bin --config "$wgcf_dir/$wgcf_account" status 2>&1)"
    account_type="$(echo "$plus_status" | awk -F': +' '/Account type/ {print $2}')"

    if [[ "$account_type" == "limited" ]]; then
        LOGN "WARP+ is already installed."
        return 0
    fi

    while true; do
        echo -n "Enter WARP+ license (or 0 to go back): "
        read -r license
        if [[ "$license" == "0" ]]; then
            return 0
        fi

        if (( ${#license} == 26 )) && [[ "$license" =~ ^[a-zA-Z0-9-]+$ ]]; then
            break
        else
            LOGW "Invalid license. Please enter a valid WARP+ license."
        fi
    done

    if ! cd "$wgcf_dir"; then
        LOGE "Failed to enter $wgcf_dir."
        return 1
    fi

    rm -f "$wgcf_dir/$wgcf_account" >/dev/null 2>&1
    rm -f "$wgcf_dir/$wgcf_profile" >/dev/null 2>&1

    if ! register_warp; then
        get_back
        return $?
    fi

    wgcf_cmd="$($wgcf_bin --config "$wgcf_dir/$wgcf_account" update --license-key "${license}" 2>&1)"
    if echo "$wgcf_cmd" | grep -q "Successfully updated"; then
        if ! "$wgcf_bin" --config "$wgcf_dir/$wgcf_account" generate >/dev/null 2>&1; then
            LOGE "WARP+ license was updated, but profile generation failed. Restoring the free WARP account."
            get_back
            return $?
        fi
        if ! mtu_transfer; then
            LOGE "WARP+ profile was generated, but MTU restoration failed."
            return 1
        fi
        LOGS "WARP has been upgraded to WARP+ successfully."
        return 0
    else
        LOGE "Upgrade failed. Please use another license."
        get_back
        return $?
    fi
}

wgcf_outbound_json() {
    local private_key
    local address
    local mtu

    {
        IFS= read -r private_key
        IFS= read -r address
        IFS= read -r mtu
    } < <(wgcf_get_configuration)

    echo -e "${italic_text}${teal}    {
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

# Function to uninstall WARP
uninstall_warp() {
    if ! confirm "Are you sure you want to uninstall WARP?" "n"; then
        return 0
    fi
    rm -f "$wgcf_bin"
    rm -fr "$wgcf_dir"
    LOGS "WARP removed successfully."
    exit 0
}

wgcf_menu() {
    local option

    while true; do
        echo -e "\t${orange}WARP Management${plain}"
        echo -e "\t${orange}1.${plain} Status"
        echo -e "\t${orange}2.${plain} Install WARP (wgcf)"
        echo -e "\t${orange}3.${plain} WARP Plus"
        echo -e "\t${orange}4.${plain} WARP Outbound (json)"
        echo -e "\t${orange}5.${plain} Uninstall WARP"
        echo -e "\t${orange}0.${plain} Back to Main Menu"
        read -r -p "Select an option: " option

        case "$option" in
        0)
            return 0
            ;;
        1)
            check_existence_wgcf && wgcf_status
            ;;
        2)
            check_absence_wgcf && install_warp
            ;;
        3)
            check_existence_wgcf && upgrade_warp_plus
            ;;
        4)
            check_existence_wgcf && wgcf_outbound_json
            ;;
        5)
            check_existence_wgcf && uninstall_warp
            ;;
        *)
            LOGE "Invalid option. Please try again."
            ;;
        esac
    done
}

# [Proxy management]

proxy_menu() {
    local choice

    while true; do
        show_proxy_status
        echo -e "\t${blue}1.${plain} Set proxy"
        echo -e "\t${blue}2.${plain} Clear proxy"
        echo -e "\t${blue}3.${plain} Test proxy"
        echo -e "\t${blue}0.${plain} Back to Main Menu"
        read -r -p "Choose an option: " choice

        case "$choice" in
        0)
            return 0
            ;;
        1)
            set_proxy_interactive
            ;;
        2)
            clear_proxy
            ;;
        3)
            test_proxy
            ;;
        *)
            LOGE "Invalid option. Please try again."
            ;;
        esac
    done
}

# [Cron management]

install_cron() {
    echo -e "Detected OS release: ${color_100}$release${plain}"
    case "$release" in
    ubuntu | debian | armbian)
        apt-get update && apt-get install --no-install-recommends -y -q cron
        ;;
    *)
        LOGE "Your operating system is not supported"
        return 1
        ;;
    esac

    if command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1; then
        LOGN "Cron is installed."
    else
        LOGE "Failed to install Cron. Please install it manually."
        return 1
    fi
}

# Function to check if a cron job exists
check_cron() {
    local cron_line
    cron_line=$(crontab -l 2>/dev/null | grep -F "$cron_cmd")
    if [[ -n "$cron_line" ]]; then
        local cron_interval
        cron_interval=$(echo "$cron_line" | awk -F'/' '{print $2}' | awk '{print $1}')
        echo -e "Cron job: ${bold_text}${green}Active${green} (Every $cron_interval minutes)${plain}"
    else
        echo -e "Cron job: ${yellow}Not Active${plain}"
    fi
}

# Function to add a cron job
add_cron() {
    local cron_interval
    local input
    while true; do
        echo -ne "Enter a number between 1 and 30 - ${blue}default is every minute${plain} (or 0 to exit):"
        read -r input
        if [[ "$input" == "0" ]]; then
            return 0
        elif [[ -z "$input" ]]; then
            cron_interval=1
            break
        elif [[ "$input" =~ ^[0-9]+$ ]] && ((input >= 1 && input <= 30)); then
            cron_interval=$input
            break
        else
            LOGW "The number is not between 1 and 30."
        fi
    done
    if ! install_cron; then
        before_show_menu
        return 1
    fi
    # Remove existing cron job if it exists
    crontab -l 2>/dev/null | grep -F -v "$cron_cmd" | crontab -
    # Add new cron job
    if (crontab -l 2>/dev/null; echo "*/$cron_interval * * * * $cron_cmd") | crontab -; then
        LOGS "Cron job added successfully"
        before_show_menu
        return 0
    fi

    LOGE "Failed to add cron job."
    before_show_menu
    return 1
}

# Function to remove a cron job
remove_cron() {
    if crontab -l 2>/dev/null | grep -q "$cron_cmd"; then
        crontab -l 2>/dev/null | grep -F -v "$cron_cmd" | crontab -
        LOGS "Cron job removed successfully."
    else
        LOGW "No cron job was found."
    fi
}

cron_menu() {
    local choice

    while true; do
        echo -e "\t${blue}1.${plain} Add cron job"
        echo -e "\t${blue}2.${plain} Remove cron"
        echo -e "\t${blue}0.${plain} Return to the menu"
        echo -n "Enter your choice: "
        read -r choice

        case "$choice" in
        0)
            return 0
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

# [Interactive main menu]

show_menu() {
    local num

    while true; do
        echo -e "╔═══════════════════════════════╗
║   ${color_100} _______  __${plain}                ║
║   ${color_100}/_  __/ |/_/${color_200}___${color_300}___ _${color_400}__ __${plain}   ║
║   ${color_100} / / _>  </${color_200} __/${color_300} _ \`${color_400}/ // /${plain}   ║
║   ${color_100}/_/ /_/|_/${color_200}_/  ${color_300}\_,_/${color_400}\_, /${plain}    ║
║                     ${color_400}/___/${plain}     ║
║   ${bold_text}${italic_text}${white}TXray Script${plain}                ║
║   ${color_100}0.${plain} Exit Script              ║
║───────────────────────────────║
║   ${color_100}1.${plain} Install                  ║
║   ${color_100}2.${plain} Update                   ║
║   ${color_100}3.${plain} Update ${bold_text}${italic_text}${color_100}TXray${plain}             ║
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
║  ${color_100}15.${plain} WARP (wgcf)              ║
║  ${color_100}16.${plain} Cron (for access.log)    ║
║  ${color_100}17.${plain} Proxy Settings           ║
╚═══════════════════════════════╝
"
        show_status
        echo
        read -r -p "Please enter your selection [0-17]: " num

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
        17)
            proxy_menu
            ;;
        *)
            LOGE "Please enter a number between 0 and 17."
            ;;
        esac
    done
}

if (( $# > 0 )); then
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