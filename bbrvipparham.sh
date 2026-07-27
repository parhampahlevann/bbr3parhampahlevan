#!/bin/bash

#colors
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
purple='\033[0;35m'
cyan='\033[0;36m'
white='\033[0;37m'
rest='\033[0m'

# -----------------------------------------------------------------------
# FIX: همیشه در /root کار می‌کنیم تا با مسیر هاردکد شده در سرویس‌ها
# (ExecStart=/root/RTT) همخوانی داشته باشه، صرف نظر از این که اسکریپت
# از کدام دایرکتوری اجرا شده باشد.
# -----------------------------------------------------------------------
INSTALL_DIR="/root"

root_access() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script requires root access. please run as root."
        exit 1
    fi
}

detect_distribution() {
    local supported_distributions=("ubuntu" "debian" "centos" "fedora")

    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [[ "${ID}" = "ubuntu" || "${ID}" = "debian" || "${ID}" = "centos" || "${ID}" = "fedora" ]]; then
            package_manager="apt-get"
            [ "${ID}" = "centos" ] && package_manager="yum"
            [ "${ID}" = "fedora" ] && package_manager="dnf"
        else
            echo "Unsupported distribution!"
            exit 1
        fi
    else
        echo "Unsupported distribution!"
        exit 1
    fi
}

check_dependencies() {
    detect_distribution

    local dependencies=("wget" "lsof" "iptables" "unzip" "gcc" "git" "curl" "tar")

    for dep in "${dependencies[@]}"; do
        if ! command -v "${dep}" &> /dev/null; then
            echo "${dep} is not installed. Installing..."
            sudo "${package_manager}" install "${dep}" -y
        fi
    done

    # -------------------------------------------------------------------
    # FIX (باگ ۵): روی CentOS/Fedora معمولا firewalld فعاله؛ RTT خودش
    # فقط ufw رو غیرفعال میکنه، پس اینجا صریحا با firewalld هم کنار میایم.
    # -------------------------------------------------------------------
    if command -v firewall-cmd &> /dev/null && sudo systemctl is-active --quiet firewalld; then
        echo -e "${yellow}firewalld detected and active.${rest}"
        echo -e "${yellow}Opening required ports (23-65535/tcp) so the tunnel isn't blocked...${rest}"
        sudo firewall-cmd --permanent --add-port=23-65535/tcp > /dev/null 2>&1
        sudo firewall-cmd --reload > /dev/null 2>&1
    fi
}

check_installed() {
    if [ -f "/etc/systemd/system/tunnel.service" ]; then
        echo "The service is already installed."
        exit 1
    fi
}

install_selected_version() {
    read -p "Do you want to install the Latest version? [yes/no] default: yes): " choice

    if [[ "$choice" == "no" ]]; then
        install_rtt_custom
    else
        install_rtt
    fi
}

# Function to download and install RTT
install_rtt() {
    cd "$INSTALL_DIR" || { echo "Cannot cd to $INSTALL_DIR"; exit 1; }

    # FIX (باگ ۳): بررسی نتیجه دانلود؛ اگر شکست خورد، اجرا متوقف میشه
    # به جای اینکه سرویس با یک باینری خراب/خالی ساخته بشه.
    if ! wget "https://raw.githubusercontent.com/radkesvat/ReverseTlsTunnel/master/scripts/install.sh" -O install.sh; then
        echo -e "${red}Failed to download install.sh. Check your internet/DNS/GitHub access.${rest}"
        exit 1
    fi
    chmod +x install.sh

    if ! bash install.sh; then
        echo -e "${red}install.sh failed to run correctly.${rest}"
        exit 1
    fi

    if [ ! -f "$INSTALL_DIR/RTT" ]; then
        echo -e "${red}RTT binary not found after install. Aborting before creating a broken service.${rest}"
        exit 1
    fi
}

# custom version
install_rtt_custom() {
    if pgrep -x "RTT" > /dev/null; then
        echo "Tunnel is running! You must stop the tunnel before update. (pkill RTT)"
        echo "Update is canceled."
        exit 1
    fi

    cd "$INSTALL_DIR" || { echo "Cannot cd to $INSTALL_DIR"; exit 1; }

    read -p "Please Enter your custom version (e.g : 7.1) : " version
    apt-get update -y 2>/dev/null

    echo "Downloading ReverseTlsTunnel version : $version"
    printf "\n"

    # FIX (باگ ۴): حذف شاخه‌ی اشتباه arm32->arm64 و مشخص کردن معماری‌های
    # واقعا پشتیبانی‌شده. اگر معماری arm واقعی (32-bit) بود، خطای واضح میدیم
    # چون در ریلیزهای پروژه بیلد جداگانه‌ای برایش منتشر نشده.
    case "$(uname -m)" in
        x86_64)
            URL="https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V${version}/v${version}_linux_amd64.zip"
            OUT_FILE="v${version}_linux_amd64.zip"
            ;;
        aarch64|arm64)
            URL="https://github.com/radkesvat/ReverseTlsTunnel/releases/download/V${version}/v${version}_linux_arm64.zip"
            OUT_FILE="v${version}_linux_arm64.zip"
            ;;
        *)
            echo "Unsupported/undetected architecture: $(uname -m)"
            exit 1
            ;;
    esac

    if ! wget "$URL" -O "$OUT_FILE"; then
        echo -e "${red}Failed to download RTT version $version. Check the version number and your internet access.${rest}"
        exit 1
    fi

    if ! unzip -o "$OUT_FILE"; then
        echo -e "${red}Failed to unzip $OUT_FILE (corrupted download?).${rest}"
        exit 1
    fi

    chmod +x RTT
    rm -f "$OUT_FILE"

    if [ ! -f "$INSTALL_DIR/RTT" ]; then
        echo -e "${red}RTT binary missing after extraction. Aborting.${rest}"
        exit 1
    fi

    echo "Finished."
}

# Function to configure arguments based on user's choice
configure_arguments() {
    read -p "Which server do you want to use? (Enter '1' for Iran(internal-server) or '2' for Kharej(external-server) ) : " server_choice
    read -p "Please Enter SNI (default : sheypoor.com): " sni
    sni=${sni:-sheypoor.com}

    # FIX (باگ ۱): استفاده از --connection-age:4800 طبق توصیه رسمی پروژه
    # برای نسخه‌های بالاتر از 5.4 که مشکل قطعی زمانی داره، به‌جای
    # فلگ منسوخ/ناشناخته --terminate که باعث کرش/ری‌استارت مکرر میشه.
    local stability_flag="--connection-age:4800"

    if [ "$server_choice" == "2" ]; then
        read -p "Please Enter IRAN IP(internal-server) : " server_ip
        read -p "Please Enter Password (Please choose the same password on both servers): " password
        arguments="--kharej --iran-ip:$server_ip --iran-port:443 --toip:127.0.0.1 --toport:multiport --password:$password --sni:$sni $stability_flag"
    elif [ "$server_choice" == "1" ]; then
        read -p "Please Enter Password (Please choose the same password on both servers): " password
        read -p "Do you want to use fake upload? (yes/no): " use_fake_upload
        if [ "$use_fake_upload" == "yes" ]; then
            read -p "Enter upload-to-download ratio (e.g., 5 for 5:1 ratio): " upload_ratio
            upload_ratio=$((upload_ratio - 1))
            arguments="--iran --lport:23-65535 --sni:$sni --password:$password --noise:$upload_ratio $stability_flag"
        else
            arguments="--iran --lport:23-65535 --sni:$sni --password:$password $stability_flag"
        fi
    else
        echo "Invalid choice. Please enter '1' or '2'."
        exit 1
    fi
}

install() {
    root_access
    check_dependencies
    check_installed
    install_selected_version

    configure_arguments

    cd /etc/systemd/system || exit 1

    # FIX (باگ ۲): ExecStart همیشه به INSTALL_DIR اشاره میکنه که همون جاییه
    # که واقعا فایل RTT دانلود شده (نه یک مسیر هاردکد که ممکنه نادرست باشه).
    cat <<EOL > tunnel.service
[Unit]
Description=my tunnel service
After=network.target

[Service]
Type=idle
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/RTT $arguments
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl start tunnel.service
    sudo systemctl enable tunnel.service

    sleep 2
    if sudo systemctl is-active --quiet tunnel.service; then
        echo -e "${green}Tunnel service started successfully.${rest}"
    else
        echo -e "${red}Tunnel service failed to start! Check: journalctl -u tunnel.service -n 50${rest}"
    fi
}

check_lbinstalled() {
    if [ -f "/etc/systemd/system/lbtunnel.service" ]; then
        echo "The Load-balancer is already installed."
        exit 1
    fi
}

configure_arguments2() {
    read -p "Which server do you want to use? (Enter '1' for Iran(internal-server) or '2' for Kharej(external-server) ) : " server_choice
    read -p "Please Enter SNI (default : sheypoor.com): " sni
    sni=${sni:-sheypoor.com}

    local stability_flag="--connection-age:4800"

    if [ "$server_choice" == "2" ]; then
        read -p "Is this your main server (VPN server)? (yes/no): " is_main_server
        read -p "Please Enter IRAN IP(internal-server) : " server_ip
        read -p "Please Enter Password (Please choose the same password on both servers): " password

        if [ "$is_main_server" == "yes" ]; then
            arguments="--kharej --iran-ip:$server_ip --iran-port:443 --toip:127.0.0.1 --toport:multiport --password:$password --sni:$sni $stability_flag"
        elif [ "$is_main_server" == "no" ]; then
            read -p "Enter your main IP (VPN Server):  " main_ip
            arguments="--kharej --iran-ip:$server_ip --iran-port:443 --toip:$main_ip --toport:multiport --password:$password --sni:$sni $stability_flag"
        else
            echo "Invalid choice for main server. Please enter 'yes' or 'no'."
            exit 1
        fi

    elif [ "$server_choice" == "1" ]; then
        read -p "Please Enter Password (Please choose the same password on both servers): " password
        read -p "Do you want to use fake upload? (yes/no): " use_fake_upload
        if [ "$use_fake_upload" == "yes" ]; then
            read -p "Enter upload-to-download ratio (e.g., 5 for 5:1 ratio): " upload_ratio
            upload_ratio=$((upload_ratio - 1))
            arguments="--iran --lport:23-65535 --password:$password --sni:$sni --noise:$upload_ratio $stability_flag"
        else
            arguments="--iran --lport:23-65535 --password:$password --sni:$sni $stability_flag"
        fi

        num_ips=0
        while true; do
            ((num_ips++))
            read -p "Please enter ip server $num_ips (or type 'done' to finish): " ip

            if [ "$ip" == "done" ]; then
                break
            else
                arguments="$arguments --peer:$ip"
            fi
        done
    else
        echo "Invalid choice. Please enter '1' or '2'."
        exit 1
    fi

    echo "Configured arguments: $arguments"
}

load-balancer() {
    root_access
    check_dependencies
    check_lbinstalled
    install_selected_version

    configure_arguments2

    cd /etc/systemd/system || exit 1

    cat <<EOL > lbtunnel.service
[Unit]
Description=my lbtunnel service
After=network.target

[Service]
Type=idle
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/RTT $arguments
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl start lbtunnel.service
    sudo systemctl enable lbtunnel.service

    sleep 2
    if sudo systemctl is-active --quiet lbtunnel.service; then
        echo -e "${green}Load-balancer service started successfully.${rest}"
    else
        echo -e "${red}Load-balancer service failed to start! Check: journalctl -u lbtunnel.service -n 50${rest}"
    fi
}

lb_uninstall() {
    if [ ! -f "/etc/systemd/system/lbtunnel.service" ]; then
        echo "The Load-balancer is not installed."
        return
    fi

    sudo systemctl stop lbtunnel.service
    sudo systemctl disable lbtunnel.service

    sudo rm -f /etc/systemd/system/lbtunnel.service
    sudo systemctl reset-failed
    sudo rm -f "$INSTALL_DIR/RTT"
    sudo rm -f "$INSTALL_DIR/install.sh" 2>/dev/null

    echo "Uninstallation completed successfully."
}

uninstall() {
    if [ ! -f "/etc/systemd/system/tunnel.service" ]; then
        echo "The service is not installed."
        return
    fi

    sudo systemctl stop tunnel.service
    sudo systemctl disable tunnel.service

    sudo rm -f /etc/systemd/system/tunnel.service
    sudo systemctl reset-failed
    sudo rm -f "$INSTALL_DIR/RTT"
    sudo rm -f "$INSTALL_DIR/install.sh" 2>/dev/null

    echo "Uninstallation completed successfully."
}

# FIX (باگ ۶): مقایسه‌ی صحیح نسخه‌ها با sort -V به‌جای مقایسه‌ی رشته‌ای
version_gt() {
    # returns 0 (true) if $1 > $2, using version sort
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

update_services() {
    cd "$INSTALL_DIR" || exit 1

    installed_version=$(./RTT -v 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    latest_version=$(curl -s https://api.github.com/repos/radkesvat/ReverseTlsTunnel/releases/latest \
        | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 | sed 's/^[Vv]//')

    if [ -z "$latest_version" ]; then
        echo -e "${red}Could not fetch latest version from GitHub API (rate-limited or blocked?).${rest}"
        return 1
    fi

    if version_gt "$latest_version" "$installed_version"; then
        echo "Updating to $latest_version (Installed: $installed_version)..."

        local was_tunnel_active=0
        local was_lb_active=0

        if sudo systemctl is-active --quiet tunnel.service; then
            echo "tunnel.service is active, stopping..."
            sudo systemctl stop tunnel.service > /dev/null 2>&1
            was_tunnel_active=1
        fi

        if sudo systemctl is-active --quiet lbtunnel.service; then
            echo "lbtunnel.service is active, stopping..."
            sudo systemctl stop lbtunnel.service > /dev/null 2>&1
            was_lb_active=1
        fi

        if ! wget "https://raw.githubusercontent.com/radkesvat/ReverseTlsTunnel/master/scripts/install.sh" -O install.sh; then
            echo -e "${red}Failed to download install.sh, update aborted.${rest}"
            return 1
        fi
        chmod +x install.sh
        bash install.sh

        [ "$was_tunnel_active" -eq 1 ] && { echo "Starting tunnel.service..."; sudo systemctl start tunnel.service; }
        [ "$was_lb_active" -eq 1 ] && { echo "Starting lbtunnel.service..."; sudo systemctl start lbtunnel.service; }

        echo "Service updated and restarted successfully."
    else
        echo "You have the latest version ($installed_version)."
    fi
}

compile() {
    detect_distribution
    check_dependencies

    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        case "$(uname -m)" in
            x86_64)  file_url="https://github.com/nim-lang/nightlies/releases/download/latest-version-2-0/linux_x64.tar.xz" ;;
            aarch64) file_url="https://github.com/nim-lang/nightlies/releases/download/latest-version-2-0/linux_arm64.tar.xz" ;;
            armv7l)  file_url="https://github.com/nim-lang/nightlies/releases/download/latest-version-2-0/linux_armv7l.tar.xz" ;;
            *) echo "Unknown architecture!"; exit 1 ;;
        esac
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        file_url="https://github.com/nim-lang/nightlies/releases/download/latest-version-2-0/macosx_x64.tar.xz"
    else
        echo "Unsupported operating system!"
        exit 1
    fi

    cd "$INSTALL_DIR" || exit 1

    if ! wget "$file_url"; then
        echo -e "${red}Failed to download Nim toolchain.${rest}"
        exit 1
    fi
    tar -xvf "$(basename "$file_url")"

    export PATH="$(pwd)/nim-2.0.1/bin:$PATH"

    if ! git clone https://github.com/radkesvat/ReverseTlsTunnel.git; then
        echo -e "${red}Failed to clone repository.${rest}"
        exit 1
    fi

    cd ReverseTlsTunnel || exit 1

    nim install
    nim build

    echo "Project compiled successfully."
    echo "RTT file is located at: $INSTALL_DIR/ReverseTlsTunnel/dist"
}

start_tunnel() {
    if sudo systemctl is-enabled --quiet tunnel.service; then
        sudo systemctl start tunnel.service > /dev/null 2>&1

        if sudo systemctl is-active --quiet tunnel.service; then
            echo "Tunnel service started."
        else
            echo "Tunnel service failed to start."
        fi
    else
        echo "Multiport Tunnel is not installed."
    fi
}

stop_tunnel() {
    if sudo systemctl is-enabled --quiet tunnel.service; then
        sudo systemctl stop tunnel.service > /dev/null 2>&1

        if sudo systemctl is-active --quiet tunnel.service; then
            echo "Tunnel service failed to stop."
        else
            echo "Tunnel service stopped."
        fi
    else
        echo "Multiport Tunnel is not installed."
    fi
}

check_tunnel_status() {
    if sudo systemctl is-active --quiet tunnel.service; then
        echo -e "${yellow}Multiport is: ${green}    [running ✔]${rest}"
    else
        echo -e "${yellow}Multiport is:${red}    [Not running ✗ ]${rest}"
    fi
}

start_lb_tunnel() {
    if sudo systemctl is-enabled --quiet lbtunnel.service; then
        sudo systemctl start lbtunnel.service > /dev/null 2>&1

        if sudo systemctl is-active --quiet lbtunnel.service; then
            echo "Tunnel service started."
        else
            echo "Tunnel service failed to start."
        fi
    else
        echo "Load-Balancer is not installed."
    fi
}

stop_lb_tunnel() {
    if sudo systemctl is-enabled --quiet lbtunnel.service; then
        sudo systemctl stop lbtunnel.service > /dev/null 2>&1

        if sudo systemctl is-active --quiet lbtunnel.service; then
            echo "Load-Balancer failed to stop."
        else
            echo "Load-Balancer stopped."
        fi
    else
        echo "Load-Balancer is not installed."
    fi
}

check_lb_tunnel_status() {
    if sudo systemctl is-active --quiet lbtunnel.service; then
        echo -e "${yellow}Load balancer is: ${green}[running ✔]${rest}"
    else
        echo -e "${yellow}Load balancer is:${red}[Not running ✗ ]${rest}"
    fi
}

check_c_installed() {
    if [ -f "/etc/systemd/system/custom_tunnel.service" ]; then
        echo "The Custom Tunnel is already installed."
        exit 1
    fi
}

start_c_tunnel() {
    if sudo systemctl is-enabled --quiet custom_tunnel.service; then
        sudo systemctl start custom_tunnel.service > /dev/null 2>&1

        if sudo systemctl is-active --quiet custom_tunnel.service; then
            echo "Custom Tunnel started."
        else
            echo "Custom Tunnel failed to start."
        fi
    else
        echo "Custom Tunnel is not installed."
    fi
}

check_c_tunnel_status() {
    if sudo systemctl is-active --quiet custom_tunnel.service; then
        echo -e "${yellow}Custom Tunnel is: ${green}[running ✔]${rest}"
    else
        echo -e "${yellow}Custom Tunnel is:${red}[Not running ✗ ]${rest}"
    fi
}

stop_c_tunnel() {
    if sudo systemctl is-enabled --quiet custom_tunnel.service; then
        sudo systemctl stop custom_tunnel.service > /dev/null 2>&1

        if sudo systemctl is-active --quiet custom_tunnel.service; then
            echo "Custom Tunnel failed to stop."
        else
            echo "Custom Tunnel stopped."
        fi
    else
        echo "Custom Tunnel is not installed."
    fi
}

install_custom() {
    root_access
    check_dependencies
    check_c_installed
    install_selected_version

    cd /etc/systemd/system || exit 1
    read -p "Enter RTT arguments (Example: RTT --iran --lport:443 --sni:splus.ir --password:123): " arguments

    cat <<EOL > custom_tunnel.service
[Unit]
Description=my custom tunnel service
After=network.target

[Service]
Type=idle
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/$arguments
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl start custom_tunnel.service
    sudo systemctl enable custom_tunnel.service
}

c_uninstall() {
    if [ ! -f "/etc/systemd/system/custom_tunnel.service" ]; then
        echo "The Custom Tunnel is not installed."
        return
    fi

    sudo systemctl stop custom_tunnel.service
    sudo systemctl disable custom_tunnel.service

    sudo rm -f /etc/systemd/system/custom_tunnel.service
    sudo systemctl reset-failed
    sudo rm -f "$INSTALL_DIR/RTT"
    sudo rm -f "$INSTALL_DIR/install.sh" 2>/dev/null

    echo "Uninstallation completed successfully."
}

# ip & version
myip=$(hostname -I | awk '{print $1}')
version=$([ -f "$INSTALL_DIR/RTT" ] && "$INSTALL_DIR/RTT" -v 2>&1 | grep -o 'version="[0-9.]*"')

clear
echo -e "${cyan}By --> Peyman * Github.com/Ptechgithub * (fixed)${rest}"
echo -e "Your IP is: ${cyan}($myip)${rest} "
echo -e "${yellow}******************************${rest}"
check_tunnel_status
check_lb_tunnel_status
check_c_tunnel_status
echo -e "${yellow}******************************${rest}"
echo -e " ${purple}--------#- Reverse Tls Tunnel -#--------${rest}"
echo -e "${green}1) Install (Multiport)${rest}"
echo -e "${red}2) Uninstall (Multiport)${rest}"
echo "3) Start Multiport"
echo "4) Stop Multiport"
echo "5) Check Status"
echo -e "${yellow} ----------------------------${rest}"
echo -e "${green}6) Install Load-balancer${rest}"
echo -e "${red}7) Uninstall Load-balancer${rest}"
echo "8) Start Load Balancer"
echo "9) Stop Load Balancer"
echo "10) Check status"
echo -e "${yellow} ----------------------------${rest}"
echo -e "${green}11) Install Custom${rest}"
echo -e "${red}12) Uninstall Custom${rest}"
echo "13) Start Custom"
echo "14) Stop Custom"
echo "15) Check status"
echo -e "${yellow} ----------------------------${rest}"
echo -e "${cyan}16) Update RTT${rest}"
echo -e "${cyan}17) Compile RTT${rest}"
echo "0) Exit"
echo -e "${purple} --------------${cyan}$version${purple}--------------${rest}"
read -p "Please choose: " choice

case $choice in
    1) install ;;
    2) uninstall ;;
    3) start_tunnel ;;
    4) stop_tunnel ;;
    5) check_tunnel_status ;;
    6) load-balancer ;;
    7) lb_uninstall ;;
    8) start_lb_tunnel ;;
    9) stop_lb_tunnel ;;
    10) check_lb_tunnel_status ;;
    11) install_custom ;;
    12) c_uninstall ;;
    13) start_c_tunnel ;;
    14) stop_c_tunnel ;;
    15) check_c_tunnel_status ;;
    16) update_services ;;
    17) compile ;;
    0) exit ;;
    *) echo "Invalid choice. Please try again." ;;
esac
