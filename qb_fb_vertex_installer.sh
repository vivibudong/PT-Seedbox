#!/bin/bash

################################################################################
# qBittorrent 4.3.9 + libtorrent v1.2.20 + Vertex + FileBrowser 一键安装脚本
# 适用于 Debian 10+ / Ubuntu 20.04+ (包括 RAID 环境)
# 
# 使用方法:
# bash <(wget -qO- https://raw.githubusercontent.com/vivibudong/PT-Seedbox/refs/heads/main/qb_fb_vertex_installer.sh) -u 用户名 -p 密码 -c 缓存大小 -q 4.3.9 -l v1.2.20 -v
#
# 参数说明:
#   -u : 用户名
#   -p : 密码
#   -c : qBittorrent 缓存大小 (MiB)
#   -q : qBittorrent 版本 (4.3.9)
#   -l : libtorrent 版本 (v1.2.20)
#   -v : 安装 Vertex
#   -f : 安装 FileBrowser
#   -o : 自定义端口 (会提示输入)
#   -d : Vertex data 目录 ZIP 下载链接 (可选)
#   -k : Vertex data ZIP 解压密码 (可选)
#   -t : 启用系统优化
#   -h : 显示帮助
################################################################################

QB_NOX_X86_URL="https://github.com/vivibudong/PT-Seedbox/raw/refs/heads/main/Torrent%20Clients/qBittorrent/x86_64/qBittorrent-4.3.9%20-%20libtorrent-v1.2.20/qbittorrent-nox"
QB_NOX_ARM_URL="https://github.com/vivibudong/PT-Seedbox/raw/refs/heads/main/Torrent%20Clients/qBittorrent/ARM64/qBittorrent-4.3.9%20-%20libtorrent-v1.2.20/qbittorrent-nox"
QB_PASS_GEN_X86_URL="https://github.com/vivibudong/PT-Seedbox/raw/refs/heads/main/Torrent%20Clients/qBittorrent/x86_64/qBittorrent-4.3.9%20-%20libtorrent-v1.2.20/qb_password_gen"
QB_PASS_GEN_ARM_URL="https://github.com/vivibudong/PT-Seedbox/raw/refs/heads/main/Torrent%20Clients/qBittorrent/ARM64/qBittorrent-4.3.9%20-%20libtorrent-v1.2.20/qb_password_gen"

# Vertex Docker 镜像
VERTEX_DOCKER_IMAGE="lswl/vertex:stable"

# FileBrowser Docker 镜像
FILEBROWSER_DOCKER_IMAGE="filebrowser/filebrowser:latest"

# ===== 随机端口生成函数 =====
generate_random_port() {
    # 生成 30000-65535 之间的随机端口
    echo $((30000 + RANDOM % 35536))
}

# ===== 端口检查函数 =====
port_in_use() {
    local port=$1

    if command -v ss >/dev/null 2>&1; then
        ss -lntuH 2>/dev/null | awk -v p="$port" '
            {
                gsub(/\[|\]/, "", $5)
                n=split($5, a, ":")
                if (a[n] == p) found=1
            }
            END { exit !found }
        '
        return $?
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntu 2>/dev/null | awk -v p="$port" '
            NR>2 {
                gsub(/\[|\]/, "", $4)
                n=split($4, a, ":")
                if (a[n] == p) found=1
            }
            END { exit !found }
        '
        return $?
    else
        return 1
    fi
}

selected_ports=()
port_selected() {
    local port=$1
    for used in "${selected_ports[@]}"; do
        if [ "$used" = "$port" ]; then
            return 0
        fi
    done
    return 1
}

port_available() {
    local port=$1
    if port_in_use "$port"; then
        return 1
    fi
    if port_selected "$port"; then
        return 1
    fi
    return 0
}

register_port() {
    selected_ports+=("$1")
}

pick_free_port() {
    local port
    for _ in $(seq 1 50); do
        port=$(generate_random_port)
        if port_available "$port"; then
            echo "$port"
            return 0
        fi
    done
    return 1
}

prompt_for_port() {
    local label=$1
    local var_name=$2
    local port

    while true; do
        need_input "请输入 ${label}端口:"
        read port
        while ! [[ "$port" =~ ^[0-9]+$ ]]; do
            warn "端口必须是数字"
            need_input "请输入 ${label}端口:"
            read port
        done
        if port_available "$port"; then
            eval "$var_name=$port"
            register_port "$port"
            return 0
        else
            warn "端口 $port 已被占用或与已选端口冲突"
        fi
    done
}

prompt_instance_name() {
    local base=$1
    local dir_prefix=$2
    local suffix=2
    local name

    if command -v docker >/dev/null 2>&1; then
        local max_docker_suffix
        max_docker_suffix=$(docker ps -a --format '{{.Names}}' 2>/dev/null | awk -v base="$base" '
            $0 ~ "^" base "[0-9]+$" {
                sub("^" base, "", $0)
                if ($0 + 0 > max) max = $0 + 0
            }
            END { print max + 0 }
        ')
        if [ "$max_docker_suffix" -ge "$suffix" ]; then
            suffix=$((max_docker_suffix + 1))
        fi
    fi

    if [ -n "$dir_prefix" ]; then
        local max_dir_suffix
        max_dir_suffix=$(ls -1 "${dir_prefix}${base}"* 2>/dev/null | awk -v base="$base" '
            {
                n=$0
                sub(".*/", "", n)
                if (n ~ "^" base "[0-9]+$") {
                    sub("^" base, "", n)
                    if (n + 0 > max) max = n + 0
                }
            }
            END { print max + 0 }
        ')
        if [ "$max_dir_suffix" -ge "$suffix" ]; then
            suffix=$((max_dir_suffix + 1))
        fi
    fi

    while true; do
        local default_name="${base}${suffix}"
        need_input "请输入 ${base} 实例名称 (默认: ${default_name}):"
        read name
        if [ -z "$name" ]; then
            name="$default_name"
        fi
        name=$(printf '%s' "$name" | tr -d '[:space:]')
        if [ -z "$name" ]; then
            warn "实例名称不能为空"
            suffix=$((suffix + 1))
            continue
        fi
        if ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
            warn "实例名称仅支持字母数字及 . _ -"
            suffix=$((suffix + 1))
            continue
        fi
        if command -v docker >/dev/null 2>&1; then
            if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$name"; then
                warn "实例名称已存在: $name"
                suffix=$((suffix + 1))
                continue
            fi
        fi
        if [ -n "$dir_prefix" ] && [ -e "${dir_prefix}${name}" ]; then
            warn "目录已存在: ${dir_prefix}${name}"
            suffix=$((suffix + 1))
            continue
        fi
        echo "$name"
        return 0
    done
}

sanitize_container_name() {
    local name=$1
    local fallback=$2

    name=$(printf '%s' "$name" | tr -cd 'A-Za-z0-9_.-')
    if [ -z "$name" ]; then
        name="$fallback"
    fi
    if ! [[ "$name" =~ ^[A-Za-z0-9] ]]; then
        name="${fallback}${name}"
    fi
    echo "$name"
}

# ===== 颜色输出函数 =====
info() {
    tput sgr0; tput setaf 2; tput bold
    echo "$1"
    tput sgr0
}
info_2() {
    tput sgr0; tput setaf 2
    echo -n "	$1"
    tput sgr0
}
boring_text() {
    tput sgr0; tput setaf 7; tput dim
    echo "$1"
    tput sgr0
}
need_input() {
    tput sgr0; tput setaf 6; tput bold
    echo "$1" 1>&2
    tput sgr0
}
warn() {
    tput sgr0; tput setaf 3
    echo "$1" 1>&2
    tput sgr0
}
fail() {
    tput sgr0; tput setaf 1; tput bold
    echo "$1" 1>&2
    tput sgr0
}
fail_exit() {
    tput sgr0; tput setaf 1; tput bold
    echo "$1" 1>&2
    tput sgr0
    exit 1
}
seperator() {
    echo -e "\n"
    echo $(printf '%*s' "$(tput cols)" | tr ' ' '=')
    echo -e "\n"
}

# ===== 等待 dpkg 锁释放 =====
wait_for_dpkg_lock() {
    local max_wait=300
    local waited=0
    
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        
        if [ $waited -eq 0 ]; then
            info_2 "等待其他包管理器进程结束..."
            echo ""
        fi
        
        sleep 2
        waited=$((waited + 2))
        
        if [ $waited -ge $max_wait ]; then
            warn "等待超时,尝试强制解锁..."
            systemctl stop unattended-upgrades 2>/dev/null || true
            systemctl stop apt-daily.timer 2>/dev/null || true
            systemctl stop apt-daily-upgrade.timer 2>/dev/null || true
            killall apt-get 2>/dev/null || true
            killall dpkg 2>/dev/null || true
            sleep 2
            break
        fi
    done
    
    if [ $waited -gt 0 ]; then
        info "✓ 锁已释放"
    fi
    
    return 0
}

# ===== 禁用自动更新服务 =====
disable_auto_updates() {
    systemctl stop unattended-upgrades 2>/dev/null || true
    systemctl disable unattended-upgrades 2>/dev/null || true
    systemctl stop apt-daily.timer 2>/dev/null || true
    systemctl disable apt-daily.timer 2>/dev/null || true
    systemctl stop apt-daily-upgrade.timer 2>/dev/null || true
    systemctl disable apt-daily-upgrade.timer 2>/dev/null || true
}

# ===== 系统更新和依赖安装 =====
update() {
    disable_auto_updates
    wait_for_dpkg_lock
    
    DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get -y -qq upgrade -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" >/dev/null 2>&1

    for pkg in sudo wget curl sysstat psmisc unzip jq; do 
        if [ -z $(which $pkg 2>/dev/null) ]; then
            wait_for_dpkg_lock
            DEBIAN_FRONTEND=noninteractive apt-get install $pkg -y -qq >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                fail "$pkg 安装失败"
                return 1
            fi
        fi
    done
    return 0
}

# ===== Docker 安装函数 (带重试机制) =====
install_docker_() {
    if command -v docker >/dev/null 2>&1; then
        return 0
    fi
    
    info_2 "安装 Docker..."
    
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        wait_for_dpkg_lock
        
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh >/dev/null 2>&1
        if [ ! -f /tmp/get-docker.sh ]; then
            fail "Docker 安装脚本下载失败"
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                warn "重试中... ($((retry_count + 1))/$max_retries)"
                sleep 5
                continue
            else
                return 1
            fi
        fi
        
        DEBIAN_FRONTEND=noninteractive sh /tmp/get-docker.sh >/dev/null 2>&1
        local install_result=$?
        rm -f /tmp/get-docker.sh
        
        if [ $install_result -eq 0 ]; then
            echo ""
            info "✓ Docker 安装成功"
            return 0
        else
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                warn "Docker 安装失败,重试中... ($((retry_count + 1))/$max_retries)"
                sleep 10
            else
                echo ""
                fail "Docker 安装失败"
                return 1
            fi
        fi
    done
    
    return 1
}

# ===== qBittorrent 安装函数 =====
install_qBittorrent_() {
    local username=$1
    local password=$2
    local qb_cache=$3
    local qb_port=$4
    local qb_incoming_port=$5
    local multi_instance=$6

    if [ "$multi_instance" != "1" ]; then
        if systemctl is-active --quiet qbittorrent-nox@$username 2>/dev/null; then
            warn "qBittorrent 正在运行,正在停止..."
            systemctl stop qbittorrent-nox@$username 2>/dev/null || true
            pkill -u "$username" -f qbittorrent 2>/dev/null || true
            sleep 2
        fi
    fi

    if [[ $(uname -m) == "x86_64" ]]; then
        QB_URL=$QB_NOX_X86_URL
        PASS_GEN_URL=$QB_PASS_GEN_X86_URL
    elif [[ $(uname -m) == "aarch64" ]]; then
        QB_URL=$QB_NOX_ARM_URL
        PASS_GEN_URL=$QB_PASS_GEN_ARM_URL
    else
        fail "不支持的 CPU 架构: $(uname -m)"
        return 1
    fi

    if [ -f /usr/bin/qbittorrent-nox ] && [ "$multi_instance" = "1" ]; then
        info_2 "检测到 qBittorrent 已安装,复用现有二进制..."
        echo " 完成"
    else
        info_2 "下载 qBittorrent 4.3.9..."
        wget -q $QB_URL -O /tmp/qbittorrent-nox
        if [ $? -ne 0 ] || [ ! -f /tmp/qbittorrent-nox ]; then
            fail "qBittorrent 下载失败"
            return 1
        fi
        chmod +x /tmp/qbittorrent-nox
        mv /tmp/qbittorrent-nox /usr/bin/qbittorrent-nox
        echo " 完成"
    fi

    info_2 "下载密码生成器..."
    wget -q $PASS_GEN_URL -O /tmp/qb_password_gen
    if [ $? -ne 0 ] || [ ! -f /tmp/qb_password_gen ]; then
        fail "密码生成器下载失败"
        rm /usr/bin/qbittorrent-nox
        return 1
    fi
    chmod +x /tmp/qb_password_gen
    echo " 完成"

    mkdir -p /home/$username/qbittorrent/Downloads
    mkdir -p /home/$username/.config/qBittorrent
    chown -R $username:$username /home/$username/

    cat > /etc/systemd/system/qbittorrent-nox@.service << 'EOF'
[Unit]
Description=qBittorrent
After=network.target

[Service]
Type=forking
User=%i
Group=%i
LimitNOFILE=infinity
ExecStart=/usr/bin/qbittorrent-nox -d
ExecStop=/usr/bin/killall -w -s 9 /usr/bin/qbittorrent-nox
Restart=on-failure
TimeoutStopSec=20
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    local disk_name=$(lsblk -nd --output NAME 2>/dev/null | grep -v '^md' | head -n1)
    local disktype=1
    if [ -n "$disk_name" ] && [ -f /sys/block/$disk_name/queue/rotational ]; then
        disktype=$(cat /sys/block/$disk_name/queue/rotational)
    fi

    if [ "${disktype}" == 0 ]; then
        aio=12
        low_buffer=5120
        buffer=20480
        buffer_factor=250
    else
        aio=4
        low_buffer=3072
        buffer=10240
        buffer_factor=150
    fi

    info_2 "生成密码哈希..."
    PBKDF2password=$(/tmp/qb_password_gen $password)
    if [ -z "$PBKDF2password" ]; then
        fail "密码生成失败"
        rm /tmp/qb_password_gen
        return 1
    fi
    rm /tmp/qb_password_gen
    echo " 完成"

    cat > /home/$username/.config/qBittorrent/qBittorrent.conf << EOF
[BitTorrent]
Session\AsyncIOThreadsCount=$aio
Session\SendBufferLowWatermark=$low_buffer
Session\SendBufferWatermark=$buffer
Session\SendBufferWatermarkFactor=$buffer_factor

[LegalNotice]
Accepted=true

[Network]
Cookies=@Invalid()

[Preferences]
Connection\PortRangeMin=$qb_incoming_port
Downloads\DiskWriteCacheSize=$qb_cache
Downloads\SavePath=/home/$username/qbittorrent/Downloads/
Queueing\QueueingEnabled=false
WebUI\Password_PBKDF2="@ByteArray($PBKDF2password)"
WebUI\Port=$qb_port
WebUI\Username=$username
WebUI\AuthSubnetWhitelist=127.0.0.1/32, 172.16.0.0/12
WebUI\AuthSubnetWhitelistEnabled=true
EOF

    chown -R $username:$username /home/$username/.config/qBittorrent

    info_2 "启动 qBittorrent 服务..."
    systemctl daemon-reload
    systemctl enable qbittorrent-nox@$username >/dev/null 2>&1
    systemctl start qbittorrent-nox@$username

    sleep 3
    if ! systemctl is-active --quiet qbittorrent-nox@$username; then
        fail "qBittorrent 启动失败"
        return 1
    fi
    echo " 完成"

    return 0
}

# ===== Vertex 安装函数 =====
install_vertex_() {
    local username=$1
    local password=$2
    local vertex_port=$3
    local qb_port=$4
    local vertex_name=$5
    local vertex_data_dir=$6
    vertex_name=$(sanitize_container_name "$vertex_name" "vertex")

    if ! install_docker_; then
        return 1
    fi

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$vertex_name"; then
        warn "Vertex 容器已存在,正在删除旧容器..."
        docker stop "$vertex_name" 2>/dev/null || true
        docker rm "$vertex_name" 2>/dev/null || true
    fi

    info_2 "安装依赖..."
    wait_for_dpkg_lock
    for pkg in apparmor apparmor-utils; do
        if ! dpkg -l | grep -qw $pkg 2>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get -y -qq install $pkg >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                warn "$pkg 安装失败,但继续..."
            fi
        fi
    done
    echo " 完成"

    timedatectl set-timezone Asia/Shanghai 2>/dev/null || warn "时区设置失败,但继续..."

    mkdir -p "$vertex_data_dir"
    chmod 755 "$vertex_data_dir"

    info_2 "拉取 Vertex 镜像..."
    docker pull $VERTEX_DOCKER_IMAGE >/dev/null 2>&1
    echo " 完成"

    info_2 "启动 Vertex 容器..."
    docker run -d --name "$vertex_name" --restart unless-stopped \
        -v "$vertex_data_dir":/vertex \
        -p "$vertex_port":3000 \
        -e TZ=Asia/Shanghai \
        $VERTEX_DOCKER_IMAGE >/tmp/vertex_run.log 2>&1

    if [ $? -ne 0 ]; then
        warn "Vertex 启动失败,请检查端口或容器日志"
        tail -n 5 /tmp/vertex_run.log 2>/dev/null || true
        return 1
    fi

    sleep 5

    if ! [ "$(docker container inspect -f '{{.State.Status}}' "$vertex_name" 2>/dev/null)" = "running" ]; then
        fail "Vertex 启动失败"
        return 1
    fi
    echo " 完成"

    # 🆕 ===== 恢复自定义 data 目录 (如果提供了下载链接) =====
    if [[ -n "$vertex_data_url" ]]; then
        info_2 "检测到自定义 data 配置,正在恢复..."
        
        # 停止 Vertex 容器
        docker stop "$vertex_name" >/dev/null 2>&1
        sleep 3
        
        # 下载 data.zip
        wget -q "$vertex_data_url" -O /tmp/vertex_data.zip 2>/dev/null
        if [ $? -ne 0 ] || [ ! -f /tmp/vertex_data.zip ]; then
            warn "data 目录下载失败,使用默认配置"
        else
            # 构建解压命令（覆盖模式）
            local unzip_cmd="unzip -o -q"
            if [[ -n "$vertex_data_pw" ]]; then
                unzip_cmd="unzip -P '$vertex_data_pw' -o -q"
            fi

            # 解压并覆盖到 /root/vertex/ 目录
            eval $unzip_cmd /tmp/vertex_data.zip -d "$vertex_data_dir"/ >/dev/null 2>&1
            
            # 判断解压是否成功
            if [ $? -eq 0 ] && [ -d "$vertex_data_dir/data" ]; then
                rm -f /tmp/vertex_data.zip
                echo " 完成"
                
                # 自动查找并修改 qBittorrent 客户端配置文件
                if [ -d "$vertex_data_dir/data/client" ]; then
                    info_2 "更新 qBittorrent 客户端配置..."

                    # ✅ 新增：在函数内部提前获取 bridge gateway
                    if [ -z "$vertex_bridge_gateway" ] && command -v docker >/dev/null 2>&1; then
                        vertex_bridge_gateway=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
                    fi
                    
                    # 查找所有 type 为 qBittorrent 的客户端配置文件
                    local updated_count=0
                    for client_file in "$vertex_data_dir"/data/client/*.json; do
                        if [ -f "$client_file" ]; then
                            # 检查是否为 qBittorrent 类型的客户端
                            local client_type=$(jq -r '.type // empty' "$client_file" 2>/dev/null)
                            
                            if [ "$client_type" = "qBittorrent" ]; then
                                # 使用 jq 更新配置
                                if command -v jq >/dev/null 2>&1; then
                                    jq --arg url "http://$vertex_bridge_gateway:$qb_port" \
                                       --arg port "$qb_port" \
                                       --arg username "$username" \
                                       --arg password "$password" \
                                       '.clientUrl = $url | .port = $port | .username = $username | .password = $password' \
                                       "$client_file" > "${client_file}.tmp" && \
                                       mv "${client_file}.tmp" "$client_file"
                                    
                                    if [ $? -eq 0 ]; then
                                        updated_count=$((updated_count + 1))
                                    fi
                                fi
                            fi
                        fi
                    done
                    
                    if [ $updated_count -gt 0 ]; then
                        echo " 完成 (更新了 $updated_count 个客户端)"
                    else
                        warn "未找到 qBittorrent 客户端配置"
                    fi
                fi
            else
                warn "data 目录解压失败 (请检查密码是否正确),使用默认配置"
                rm -f /tmp/vertex_data.zip
            fi
        fi
        
        # 重新启动容器
        docker start "$vertex_name" >/dev/null 2>&1
        sleep 5
        
        if ! [ "$(docker container inspect -f '{{.State.Status}}' "$vertex_name" 2>/dev/null)" = "running" ]; then
            fail "Vertex 重启失败"
            return 1
        fi
    fi
    # 🆕 ===== data 目录恢复结束 =====

    info_2 "配置 Vertex 用户..."
    docker stop "$vertex_name" >/dev/null 2>&1
    sleep 5

    if ! [ "$(docker container inspect -f '{{.State.Status}}' "$vertex_name" 2>/dev/null)" = "exited" ]; then
        fail "Vertex 停止失败"
        return 1
    fi

    vertex_pass=$(echo -n $password | md5sum | awk '{print $1}')
    
    # 使用 jq 合并 JSON，保留原有配置
    if [ -f "$vertex_data_dir/data/setting.json" ]; then
        jq --arg user "$username" --arg pass "$vertex_pass" \
           '.username = $user | .password = $pass' \
           "$vertex_data_dir/data/setting.json" > /tmp/setting.json.tmp && \
           mv /tmp/setting.json.tmp "$vertex_data_dir/data/setting.json"
    else
        # 如果文件不存在，创建新文件
        cat > "$vertex_data_dir/data/setting.json" << EOF
{
  "username": "$username",
  "password": "$vertex_pass"
}
EOF
    fi

    docker start "$vertex_name" >/dev/null 2>&1
    sleep 5

    if ! [ "$(docker container inspect -f '{{.State.Status}}' "$vertex_name" 2>/dev/null)" = "running" ]; then
        fail "Vertex 重启失败"
        return 1
    fi
    echo " 完成"
    
    return 0
}

# ===== FileBrowser 安装函数 =====
install_filebrowser_() {
    local username=$1
    local password=$2
    local fb_port=$3
    local fb_name=$4
    local fb_data_dir=$5
    fb_name=$(sanitize_container_name "$fb_name" "filebrowser")

    if ! install_docker_; then
        return 1
    fi

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$fb_name"; then
        warn "FileBrowser 容器已存在,正在删除旧容器..."
        docker stop "$fb_name" 2>/dev/null || true
        docker rm "$fb_name" 2>/dev/null || true
    fi

    # 创建配置目录并设置正确权限 (UID 1000:GID 1000)
    info_2 "配置 FileBrowser 目录..."
    mkdir -p "$fb_data_dir"
    chown -R 1000:1000 "$fb_data_dir"
    chmod 755 "$fb_data_dir"
    echo " 完成"

    # 🆕 设置 qBittorrent 目录权限,确保 FileBrowser 可以读写
    info_2 "设置数据目录权限..."
    # 保持用户所有权,添加 1000 为组成员,设置组写权限
    chown -R $username:$username /home/$username/qbittorrent
    chmod -R 775 /home/$username/qbittorrent
    # 将 qBittorrent 目录的组改为 1000,这样 FileBrowser (UID 1000) 也有完整权限
    chgrp -R 1000 /home/$username/qbittorrent
    echo " 完成"

    # 拉取镜像 (静默)
    info_2 "拉取 FileBrowser 镜像..."
    docker pull $FILEBROWSER_DOCKER_IMAGE >/dev/null 2>&1
    echo " 完成"

    # 启动 FileBrowser
    info_2 "启动 FileBrowser 容器..."
    docker run -d --name "$fb_name" --restart unless-stopped \
        -v /home/$username/qbittorrent:/srv \
        -v "$fb_data_dir":/database \
        -p "$fb_port":80 \
        $FILEBROWSER_DOCKER_IMAGE >/tmp/filebrowser_run.log 2>&1

    if [ $? -ne 0 ]; then
        warn "FileBrowser 启动失败,请检查端口或容器日志"
        tail -n 5 /tmp/filebrowser_run.log 2>/dev/null || true
        return 1
    fi

    sleep 5

    # 验证启动
    if ! [ "$(docker container inspect -f '{{.State.Status}}' "$fb_name" 2>/dev/null)" = "running" ]; then
        fail "FileBrowser 启动失败"
        return 1
    fi
    echo " 完成"

    # 🆕 修改默认用户名密码 (正确方法)
    info_2 "配置 FileBrowser 用户..."
    sleep 5  # 等待数据库初始化
    
    # 停止容器以避免 SQLite 锁冲突
    docker stop "$fb_name" >/dev/null 2>&1
    sleep 3
    
    # 使用临时容器修改密码 (必须指定 --database 参数)
    docker run --rm \
        -v "$fb_data_dir"/:/database/ \
        $FILEBROWSER_DOCKER_IMAGE \
        users update admin \
        --username="$username" \
        --password="$password" \
        --locale="zh-cn" \
        --database="/database/filebrowser.db" >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo " 完成"
    else
        warn "用户配置可能失败,请使用docker logs filebrowser查询初始密码后,登录手动修改"
        echo ""
    fi
    
    # 启动容器
    docker start "$fb_name" >/dev/null 2>&1
    sleep 3

    if ! [ "$(docker container inspect -f '{{.State.Status}}' "$fb_name" 2>/dev/null)" = "running" ]; then
        fail "FileBrowser 重启失败"
        return 1
    fi

    return 0
}

# ===== 系统优化函数 =====
tuned_() {
    if [ -z $(which tuned 2>/dev/null) ]; then
        wait_for_dpkg_lock
        DEBIAN_FRONTEND=noninteractive apt-get -qqy install tuned >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    return 0
}

set_ring_buffer_() {
    local interface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}')
    if [ -z "$interface" ]; then
        return 1
    fi
    
    if [ -z $(which ethtool 2>/dev/null) ]; then
        wait_for_dpkg_lock
        DEBIAN_FRONTEND=noninteractive apt-get -y -qq install ethtool >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    ethtool -G $interface rx 1024 2>/dev/null || true
    sleep 1
    ethtool -G $interface tx 2048 2>/dev/null || true
    sleep 1
    return 0
}

set_txqueuelen_() {
    local interface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}')
    if [ -z "$interface" ]; then
        return 1
    fi
    
    if [ -z $(which ifconfig 2>/dev/null) ]; then
        wait_for_dpkg_lock
        DEBIAN_FRONTEND=noninteractive apt-get -y -qq install net-tools >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            return 1
        fi
    fi
    
    ifconfig $interface txqueuelen 10000 2>/dev/null
    sleep 1
    return 0
}

set_initial_congestion_window_() {
    local iproute=$(ip -o -4 route show to default 2>/dev/null)
    if [ -z "$iproute" ]; then
        return 1
    fi
    ip route change $iproute initcwnd 25 initrwnd 25 2>/dev/null
    return $?
}

set_disk_scheduler_() {
    local disk=$(lsblk -nd --output NAME 2>/dev/null | grep -v '^md')
    
    if [[ -z $disk ]]; then
        return 0
    fi
    
    for diskname in $disk; do
        if [ ! -f /sys/block/$diskname/queue/scheduler ]; then
            continue
        fi
        
        local current_scheduler=$(cat /sys/block/$diskname/queue/scheduler 2>/dev/null)
        if [ -z "$current_scheduler" ]; then
            continue
        fi
        
        if [[ "$current_scheduler" == *"none"* ]] && [[ ! "$current_scheduler" =~ mq-deadline|kyber|bfq ]]; then
            continue
        fi
        
        local disktype=$(cat /sys/block/$diskname/queue/rotational 2>/dev/null || echo "1")
        
        if [ "${disktype}" == "0" ]; then
            if [[ "$current_scheduler" =~ kyber ]]; then
                echo kyber > /sys/block/$diskname/queue/scheduler 2>/dev/null || true
            elif [[ "$current_scheduler" =~ mq-deadline ]]; then
                echo mq-deadline > /sys/block/$diskname/queue/scheduler 2>/dev/null || true
            fi
        else
            if [[ "$current_scheduler" =~ mq-deadline ]]; then
                echo mq-deadline > /sys/block/$diskname/queue/scheduler 2>/dev/null || true
            fi
        fi
    done
    
    return 0
}

set_file_open_limit_() {
    if [[ -z $username ]]; then
        return 1
    fi
    
    if grep -q "## qBittorrent 文件打开限制" /etc/security/limits.conf 2>/dev/null; then
        return 0
    fi
    
    cat << EOF >> /etc/security/limits.conf
## qBittorrent 文件打开限制
$username hard nofile 1048576
$username soft nofile 1048576
EOF
    return 0
}

kernel_settings_() {
    local memory_size=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
    
    if [ -z "$memory_size" ]; then
        return 1
    fi
    
    local tcp_mem_min_cap=262144
    local tcp_mem_pressure_cap=2097152
    local tcp_mem_max_cap=4194304
    
    local memory_4k=$((memory_size / 4))
    
    if [ $memory_size -le 524288 ]; then
        tcp_mem_min=$((memory_4k / 32))
        tcp_mem_pressure=$((memory_4k / 16))
        tcp_mem_max=$((memory_4k / 8))
        rmem_max=8388608
        wmem_max=8388608
        win_scale=3
    elif [ $memory_size -le 1048576 ]; then
        tcp_mem_min=$((memory_4k / 16))
        tcp_mem_pressure=$((memory_4k / 8))
        tcp_mem_max=$((memory_4k / 6))
        rmem_max=16777216
        wmem_max=16777216
        win_scale=2
    elif [ $memory_size -le 4194304 ]; then
        tcp_mem_min=$((memory_4k / 8))
        tcp_mem_pressure=$((memory_4k / 6))
        tcp_mem_max=$((memory_4k / 4))
        rmem_max=33554432
        wmem_max=33554432
        win_scale=2
    elif [ $memory_size -le 16777216 ]; then
        tcp_mem_min=$((memory_4k / 8))
        tcp_mem_pressure=$((memory_4k / 4))
        tcp_mem_max=$((memory_4k / 2))
        rmem_max=67108864
        wmem_max=67108864
        win_scale=1
    else
        tcp_mem_min=$((memory_4k / 8))
        tcp_mem_pressure=$((memory_4k / 4))
        tcp_mem_max=$((memory_4k / 2))
        rmem_max=134217728
        wmem_max=134217728
        win_scale=-2
    fi
    
    [ $tcp_mem_min -gt $tcp_mem_min_cap ] && tcp_mem_min=$tcp_mem_min_cap
    [ $tcp_mem_pressure -gt $tcp_mem_pressure_cap ] && tcp_mem_pressure=$tcp_mem_pressure_cap
    [ $tcp_mem_max -gt $tcp_mem_max_cap ] && tcp_mem_max=$tcp_mem_max_cap
    
    tcp_mem="$tcp_mem_min $tcp_mem_pressure $tcp_mem_max"
    
    local rmem_default=262144
    local wmem_default=16384
    local tcp_rmem="8192 $rmem_default $rmem_max"
    local tcp_wmem="4096 $wmem_default $wmem_max"
    
    modprobe tcp_bbr 2>/dev/null || true
    
    cat > /etc/sysctl.d/99-qbittorrent.conf << EOF
# qBittorrent 内核优化

# 进程调度
kernel.pid_max = 4194303
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.sched_migration_cost_ns = 5000000
kernel.sched_autogroup_enabled = 0
kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000

# 文件系统
fs.file-max = 1048576
fs.nr_open = 1048576

# 虚拟内存
vm.dirty_background_ratio = 5
vm.dirty_ratio = 30
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 100
vm.swappiness = 10

# 网络核心
net.core.netdev_budget = 50000
net.core.netdev_budget_usecs = 8000
net.core.netdev_max_backlog = 100000
net.core.rmem_default = $rmem_default
net.core.rmem_max = $rmem_max
net.core.wmem_default = $wmem_default
net.core.wmem_max = $wmem_max
net.core.optmem_max = 4194304

# IPv4 路由
net.ipv4.route.mtu_expires = 1800
net.ipv4.route.min_adv_mss = 536
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_no_pmtu_disc = 0

# ARP
net.ipv4.neigh.default.unres_qlen_bytes = 16777216

# TCP
net.core.somaxconn = 524288
net.ipv4.tcp_max_syn_backlog = 524288
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_max_tw_buckets = 10240
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_base_mss = 1460
net.ipv4.tcp_min_snd_mss = 536
net.ipv4.tcp_sack = 1
net.ipv4.tcp_comp_sack_delay_ns = 250000
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_mem = $tcp_mem
net.ipv4.tcp_rmem = $tcp_rmem
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = $win_scale
net.ipv4.tcp_wmem = $tcp_wmem
net.ipv4.tcp_reordering = 10
net.ipv4.tcp_max_reordering = 600
net.ipv4.tcp_synack_retries = 10
net.ipv4.tcp_syn_retries = 7
net.ipv4.tcp_keepalive_time = 7200
net.ipv4.tcp_keepalive_probes = 15
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 10
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_fin_timeout = 5
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_workaround_signed_windows = 1
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_limit_output_bytes = 3276800

# 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    
    sysctl -p /etc/sysctl.d/99-qbittorrent.conf >/dev/null 2>&1 || true
    
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$current_cc" = "bbr" ]; then
        return 0
    else
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
        return 1
    fi
}

# ===== 完整卸载函数 =====
uninstall_all() {
    info "开始完整卸载所有组件..."
    seperator
    
    # 1. 停止并删除 systemd 服务
    info "清理 systemd 服务..."
    
    # 停止 qBittorrent 服务（所有用户）并收集用户名
    detected_users=()
    for service in $(systemctl list-units --all 'qbittorrent-nox@*' --no-legend | awk '{print $1}'); do
        username=$(echo "$service" | sed 's/qbittorrent-nox@\(.*\)\.service/\1/')
        detected_users+=("$username")
        info_2 "停止服务: $service"
        systemctl stop "$service" >/dev/null 2>&1 || true
        systemctl disable "$service" >/dev/null 2>&1 || true
        echo " 完成"
    done
    
    # 删除 qBittorrent service 文件
    if [ -f /etc/systemd/system/qbittorrent-nox@.service ]; then
        rm -f /etc/systemd/system/qbittorrent-nox@.service
        info "✓ 已删除 qBittorrent service 文件"
    fi
    
    # 停止并删除开机启动脚本服务
    if systemctl is-enabled boot-script.service >/dev/null 2>&1; then
        systemctl stop boot-script.service >/dev/null 2>&1 || true
        systemctl disable boot-script.service >/dev/null 2>&1 || true
        info "✓ 已停止开机启动脚本服务"
    fi
    
    if [ -f /etc/systemd/system/boot-script.service ]; then
        rm -f /etc/systemd/system/boot-script.service
        rm -f /root/.boot-script.sh
        info "✓ 已删除开机启动脚本"
    fi
    
    systemctl daemon-reload >/dev/null 2>&1 || true
    echo ""
    
    # 2. 停止并删除 Docker 容器和镜像
    if command -v docker >/dev/null 2>&1; then
        info "清理 Docker 容器和镜像..."
        
        # Vertex
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^vertex'; then
            info_2 "删除 Vertex 容器..."
            for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^vertex'); do
                docker stop "$c" >/dev/null 2>&1 || true
                docker rm "$c" >/dev/null 2>&1 || true
            done
            echo " 完成"
        fi
        
        if docker images 2>/dev/null | grep -q "lswl/vertex"; then
            info_2 "删除 Vertex 镜像..."
            docker rmi lswl/vertex:stable >/dev/null 2>&1 || true
            echo " 完成"
        fi
        
        # FileBrowser
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^filebrowser'; then
            info_2 "删除 FileBrowser 容器..."
            for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^filebrowser'); do
                docker stop "$c" >/dev/null 2>&1 || true
                docker rm "$c" >/dev/null 2>&1 || true
            done
            echo " 完成"
        fi
        
        if docker images 2>/dev/null | grep -q "filebrowser/filebrowser"; then
            info_2 "删除 FileBrowser 镜像..."
            docker rmi filebrowser/filebrowser:latest >/dev/null 2>&1 || true
            echo " 完成"
        fi
        
        # 清理未使用的 Docker 资源
        info_2 "清理未使用的 Docker 资源..."
        docker system prune -af --volumes >/dev/null 2>&1 || true
        echo " 完成"
        echo ""
    fi
    
    # 3. 删除 qBittorrent 二进制文件和进程
    info "清理 qBittorrent..."
    
    pkill -9 -f qbittorrent >/dev/null 2>&1 || true
    
    if [ -f /usr/bin/qbittorrent-nox ]; then
        rm -f /usr/bin/qbittorrent-nox
        info "✓ 已删除 qBittorrent 二进制文件"
    fi
    
    # 删除临时文件
    rm -f /tmp/qbittorrent-nox 2>/dev/null || true
    rm -f /tmp/qb_password_gen 2>/dev/null || true
    echo ""
    
    # 4. 清理用户数据目录
    info "清理用户数据..."
    
    # 使用检测到的用户列表
    if [ ${#detected_users[@]} -eq 0 ]; then
        # 如果没有检测到服务中的用户，扫描 /home 目录
        for user_home in /home/*; do
            if [ -d "$user_home/.config/qBittorrent" ] || [ -d "$user_home/qbittorrent" ]; then
                username=$(basename "$user_home")
                detected_users+=("$username")
            fi
        done
    fi
    
    for username in "${detected_users[@]}"; do
        user_home="/home/$username"
        
        # 清理 qBittorrent 配置
        if [ -d "$user_home/.config/qBittorrent" ]; then
            info_2 "删除 $username 的 qBittorrent 配置..."
            rm -rf "$user_home/.config/qBittorrent"
            echo " 完成"
        fi
        
        # 询问是否删除下载数据
        if [ -d "$user_home/qbittorrent" ]; then
            need_input "是否删除 $username 的下载数据? ($user_home/qbittorrent) [y/N]:"
            read -r confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                rm -rf "$user_home/qbittorrent"
                info "✓ 已删除下载数据"
            else
                warn "⊘ 保留下载数据"
            fi
        fi
        
        # 清理 FileBrowser 配置
        for fb_dir in "$user_home"/.filebrowser*; do
            if [ -d "$fb_dir" ]; then
                info_2 "删除 $username 的 FileBrowser 配置: $fb_dir"
                rm -rf "$fb_dir"
                echo " 完成"
            fi
        done
    done
    echo ""
    
    # 5. 清理 Vertex 数据（不询问，直接删除）
    for vertex_dir in /root/vertex*; do
        if [ -d "$vertex_dir" ]; then
            info_2 "删除 Vertex 数据: $vertex_dir"
            rm -rf "$vertex_dir"
            echo " 完成"
            echo ""
        fi
    done
    
    # 6. 恢复系统配置文件
    info "恢复系统配置..."
    
    # 恢复 sysctl 配置
    if [ -f /etc/sysctl.d/99-qbittorrent.conf ]; then
        info_2 "恢复 sysctl 配置..."
        rm -f /etc/sysctl.d/99-qbittorrent.conf
        sysctl --system >/dev/null 2>&1 || true
        echo " 完成"
    fi
    
    # 恢复 limits.conf
    if [ -f /etc/security/limits.conf ]; then
        if grep -q "## qBittorrent 文件打开限制" /etc/security/limits.conf 2>/dev/null; then
            info_2 "恢复 limits.conf..."
            cp /etc/security/limits.conf /etc/security/limits.conf.bak.$(date +%s)
            sed -i '/## qBittorrent 文件打开限制/,+2d' /etc/security/limits.conf
            echo " 完成"
        fi
    fi
    rm -f /etc/ptbox_optimized 2>/dev/null || true
    echo ""
    
    # 7. 卸载安装的软件包（不询问，直接卸载）
    info "卸载已安装的软件包..."
    wait_for_dpkg_lock
    
    # 卸载 Docker
    if command -v docker >/dev/null 2>&1; then
        info_2 "卸载 Docker..."
        systemctl stop docker >/dev/null 2>&1 || true
        systemctl disable docker >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get -y -qq purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get -y -qq autoremove >/dev/null 2>&1 || true
        rm -rf /var/lib/docker
        rm -rf /var/lib/containerd
        rm -f /etc/apt/sources.list.d/docker.list
        rm -f /etc/apt/keyrings/docker.gpg
        echo " 完成"
    fi
    
    # 卸载其他工具
    for pkg in jq unzip ethtool net-tools tuned sysstat psmisc apparmor apparmor-utils; do
        if dpkg -l | grep -qw "^ii.*$pkg" 2>/dev/null; then
            info_2 "卸载 $pkg..."
            DEBIAN_FRONTEND=noninteractive apt-get -y -qq purge $pkg >/dev/null 2>&1 || true
            echo " 完成"
        fi
    done
    
    # 清理残留依赖
    info_2 "清理残留依赖..."
    DEBIAN_FRONTEND=noninteractive apt-get -y -qq autoremove >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get -y -qq autoclean >/dev/null 2>&1 || true
    echo " 完成"
    echo ""
    
    # 8. 清理日志和临时文件
    info "清理日志和临时文件..."
    
    # 清理安装日志
    if [ -f /var/log/qb_install.log ]; then
        rm -f /var/log/qb_install.log
        info "✓ 已删除安装日志"
    fi
    
    # 清理临时文件
    rm -f /tmp/get-docker.sh 2>/dev/null || true
    rm -f /tmp/setting.json.tmp 2>/dev/null || true
    rm -f /tmp/vertex_data.zip 2>/dev/null || true
    
    # 清理 apt 缓存
    info_2 "清理 apt 缓存..."
    apt-get clean >/dev/null 2>&1 || true
    echo " 完成"
    echo ""
    
    # 9. 删除脚本创建的用户（自动检测）
    if [ ${#detected_users[@]} -gt 0 ]; then
        info "检测到以下用户: ${detected_users[*]}"
        need_input "是否删除这些用户? [y/N]:"
        read -r confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            for username in "${detected_users[@]}"; do
                if id -u "$username" >/dev/null 2>&1; then
                    info_2 "删除用户 $username..."
                    userdel -r "$username" >/dev/null 2>&1 || userdel "$username" >/dev/null 2>&1 || true
                    echo " 完成"
                fi
            done
        else
            warn "⊘ 保留用户"
        fi
        echo ""
    fi
    
    # 10. 卸载内核模块
    info "卸载内核模块..."
    if lsmod | grep -q tcp_bbr; then
        info_2 "卸载 tcp_bbr 模块..."
        rmmod tcp_bbr >/dev/null 2>&1 || true
        echo " 完成"
    fi
    echo ""
    
    seperator
    info "✓ 卸载完成!"
    echo ""
    warn "建议重启系统以确保所有更改生效"
    boring_text "  重启命令: reboot"
    seperator
    
    exit 0
}

# ===== 检查卸载参数 =====
if [[ "$1" == "--uninstall" ]]; then
    uninstall_all
fi


# ===== 参数解析 =====
custom_ports=0
while getopts "u:p:c:q:l:vfod:k:th" opt; do
    case ${opt} in
        u) username=${OPTARG} ;;
        p) password=${OPTARG} ;;
        c) 
            cache=${OPTARG}
            while ! [[ "$cache" =~ ^[0-9]+$ ]]; do
                warn "缓存大小必须是数字"
                need_input "请输入缓存大小 (MiB):"
                read cache
            done
            qb_cache=$cache
            ;;
        q) qb_ver="qBittorrent-${OPTARG}" ;;
        l) lib_ver="libtorrent-${OPTARG}" ;;
        v) vertex_install=1 ;;
        f) filebrowser_install=1 ;;
        d) vertex_data_url=${OPTARG} ;;
        k) vertex_data_pw=${OPTARG} ;;
        t) optimize_enabled=1 ;;
        o)
            custom_ports=1
            prompt_for_port "qBittorrent WebUI" qb_port
            prompt_for_port "qBittorrent 传入" qb_incoming_port
            
            if [[ -n "$vertex_install" ]]; then
                prompt_for_port "Vertex" vertex_port
            fi
            
            if [[ -n "$filebrowser_install" ]]; then
                prompt_for_port "FileBrowser" filebrowser_port
            fi
            ;;
        h)
            info "qBittorrent 4.3.9 + Vertex + FileBrowser 一键安装脚本"
            seperator
            info "使用方法:"
            boring_text "  bash <(wget -qO- 你的脚本地址) -u 用户名 -p 密码 -c 2048 -q 4.3.9 -l v1.2.20 -v -f"
            seperator
            info "参数说明:"
            boring_text "  -u : 用户名"
            boring_text "  -p : 密码"
            boring_text "  -c : qBittorrent 缓存大小 (MiB)"
            boring_text "  -q : qBittorrent 版本 (4.3.9)"
            boring_text "  -l : libtorrent 版本 (v1.2.20)"
            boring_text "  -v : 安装 Vertex"
            boring_text "  -f : 安装 FileBrowser"
            boring_text "  -d : Vertex data 目录 ZIP 下载链接 (可选)"
            boring_text "  -k : Vertex data ZIP 解压密码 (可选)"
            boring_text "  -o : 自定义端口"
            boring_text "  -t : 启用系统优化"
            boring_text "  -h : 显示帮助"
            seperator
            info "卸载方法:"
            boring_text "  bash <(wget -qO- https://raw.githubusercontent.com/vivibudong/PT-Seedbox/refs/heads/main/qb_fb_vertex_installer.sh) --uninstall"
            seperator
            exit 0
            ;;
        \?)
            fail_exit "无效参数,使用 -h 查看帮助"
            ;;
    esac
done

# ===== 环境检查 =====
info "检查安装环境"

if [ $(id -u) -ne 0 ]; then 
    fail_exit "此脚本需要 root 权限运行"
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
elif type lsb_release >/dev/null 2>&1; then
    OS=$(lsb_release -si)
    VER=$(lsb_release -sr)
elif [ -f /etc/lsb-release ]; then
    . /etc/lsb-release
    OS=$DISTRIB_ID
    VER=$DISTRIB_RELEASE
elif [ -f /etc/debian_version ]; then
    OS=Debian
    VER=$(cat /etc/debian_version)
else
    OS=$(uname -s)
    VER=$(uname -r)
fi

if [[ ! "$OS" =~ "Debian" ]] && [[ ! "$OS" =~ "Ubuntu" ]]; then
    fail "$OS $VER 不支持"
    info "仅支持 Debian 10+ 和 Ubuntu 20.04+"
    exit 1
fi

if [[ "$OS" =~ "Debian" ]]; then
    if [[ ! "$VER" =~ "10" ]] && [[ ! "$VER" =~ "11" ]] && [[ ! "$VER" =~ "12" ]] && [[ ! "$VER" =~ "13" ]]; then
        fail "$OS $VER 不支持"
        info "仅支持 Debian 10+"
        exit 1
    fi
fi

if [[ "$OS" =~ "Ubuntu" ]]; then
    if [[ ! "$VER" =~ "20" ]] && [[ ! "$VER" =~ "22" ]] && [[ ! "$VER" =~ "23" ]] && [[ ! "$VER" =~ "24" ]] && [[ ! "$VER" =~ "25" ]]; then
        fail "$OS $VER 不支持"
        info "仅支持 Ubuntu 20.04+"
        exit 1
    fi
fi

info "✓ 操作系统: $OS $VER"

# ===== 参数验证 =====
if [ -z "$username" ]; then
    warn "未指定用户名"
    need_input "请输入用户名:"
    read username
fi

if [ -z "$password" ]; then
    warn "未指定密码"
    need_input "请输入密码 (至少12位):"
    read password
fi

# 🆕 添加密码长度验证
while [ ${#password} -lt 12 ]; do
    fail "密码长度不足! 当前长度: ${#password} 位,至少 12 位"
    need_input "请重新输入密码 (至少12位):"
    read password
done
info "✓ 密码长度验证通过: ${#password} 位"

if [ -z "$qb_cache" ]; then
    warn "未指定缓存大小"
    need_input "请输入缓存大小 (MiB):"
    read cache
    while ! [[ "$cache" =~ ^[0-9]+$ ]]; do
        warn "缓存大小必须是数字"
        need_input "请输入缓存大小 (MiB):"
        read cache
    done
    qb_cache=$cache
fi

if [ "$custom_ports" = "1" ]; then
    if [[ -n "$vertex_install" ]] && [ -z "$vertex_port" ]; then
        prompt_for_port "Vertex" vertex_port
    fi
    if [[ -n "$filebrowser_install" ]] && [ -z "$filebrowser_port" ]; then
        prompt_for_port "FileBrowser" filebrowser_port
    fi
fi

qb_multi_instance=0
vertex_name="vertex"
vertex_data_dir="/root/vertex"
filebrowser_name="filebrowser"
OPTIM_MARKER="/etc/ptbox_optimized"

if [ -f /usr/bin/qbittorrent-nox ] || systemctl list-units --all 'qbittorrent-nox@*' --no-legend 2>/dev/null | grep -q .; then
    need_input "检测到已安装 qBittorrent,是否新增实例? [Y/n]:"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
        qb_multi_instance=1
    fi
fi

if [ "$qb_multi_instance" = "1" ]; then
    while [ -d "/home/$username/.config/qBittorrent" ] || systemctl list-units --all "qbittorrent-nox@$username.service" --no-legend 2>/dev/null | grep -q .; do
        warn "用户 $username 已存在 qBittorrent 配置"
        need_input "请输入新的用户名用于新增实例:"
        read username
    done
fi

filebrowser_data_dir="/home/$username/.filebrowser"

if [ -z "$qb_port" ]; then
    qb_port=$(pick_free_port)
    if [ -z "$qb_port" ]; then
        fail_exit "无法找到可用的 qBittorrent WebUI 端口"
    fi
    register_port "$qb_port"
    info "✓ qBittorrent WebUI 端口: $qb_port"
fi

if [ -z "$qb_incoming_port" ]; then
    qb_incoming_port=$(pick_free_port)
    if [ -z "$qb_incoming_port" ]; then
        fail_exit "无法找到可用的 qBittorrent 传入端口"
    fi
    register_port "$qb_incoming_port"
    info "✓ qBittorrent 传入端口: $qb_incoming_port"
fi

if [[ -n "$vertex_install" ]] && [ -z "$vertex_port" ]; then
    vertex_port=$(pick_free_port)
    if [ -z "$vertex_port" ]; then
        fail_exit "无法找到可用的 Vertex 端口"
    fi
    register_port "$vertex_port"
    info "✓ Vertex 端口: $vertex_port"
fi

if [[ -n "$filebrowser_install" ]] && [ -z "$filebrowser_port" ]; then
    filebrowser_port=$(pick_free_port)
    if [ -z "$filebrowser_port" ]; then
        fail_exit "无法找到可用的 FileBrowser 端口"
    fi
    register_port "$filebrowser_port"
    info "✓ FileBrowser 端口: $filebrowser_port"
fi

if [[ -n "$vertex_install" ]] && command -v docker >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$vertex_name"; then
        need_input "检测到 Vertex 已安装,是否新增实例? [Y/n]:"
        read -r confirm
        if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
            vertex_name=$(prompt_instance_name "vertex" "/root/")
            vertex_data_dir="/root/$vertex_name"
        fi
    fi
fi

if [[ -n "$filebrowser_install" ]] && command -v docker >/dev/null 2>&1; then
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$filebrowser_name"; then
        need_input "检测到 FileBrowser 已安装,是否新增实例? [Y/n]:"
        read -r confirm
        if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
            filebrowser_name=$(prompt_instance_name "filebrowser" "/home/$username/.")
            filebrowser_data_dir="/home/$username/.${filebrowser_name}"
        fi
    fi
fi

if ! id -u $username > /dev/null 2>&1; then
    useradd -m -s /bin/bash $username
    if [ $? -ne 0 ]; then
        fail_exit "用户创建失败"
    fi
    info "✓ 用户创建成功: $username"
else
    info "✓ 用户已存在: $username"
fi
chown -R $username:$username /home/$username

# ===== 系统更新 =====
info "开始系统更新和依赖安装"
if update; then
    info "✓ 系统更新完成"
else
    warn "✗ 系统更新失败,但继续安装..."
fi

seperator

# ===== 安装 qBittorrent =====
info "开始安装 qBittorrent 4.3.9"
echo -e "\n"

if install_qBittorrent_ $username $password $qb_cache $qb_port $qb_incoming_port $qb_multi_instance; then
    info "✓ qBittorrent 安装成功"
    qb_install_success=1
else
    fail "✗ qBittorrent 安装失败"
fi

seperator

# ===== 安装 Vertex =====
if [[ -n "$vertex_install" ]]; then
    info "开始安装 Vertex"
    echo -e "\n"
    
    if install_vertex_ $username $password $vertex_port $qb_port $vertex_name $vertex_data_dir; then
        info "✓ Vertex 安装成功"
        vertex_install_success=1
    else
        fail "✗ Vertex 安装失败"
    fi
    
    seperator
fi

# ===== 安装 FileBrowser =====
if [[ -n "$filebrowser_install" ]]; then
    info "开始安装 FileBrowser"
    echo -e "\n"
    
    if install_filebrowser_ $username $password $filebrowser_port $filebrowser_name $filebrowser_data_dir; then
        info "✓ FileBrowser 安装成功"
        filebrowser_install_success=1
    else
        fail "✗ FileBrowser 安装失败"
    fi
    
    seperator
fi

# ===== 系统优化 (简化输出) =====
if [[ -n "$optimize_enabled" ]]; then
    if [ -f "$OPTIM_MARKER" ] || [ -f /etc/sysctl.d/99-qbittorrent.conf ]; then
        info "检测到已优化,跳过系统优化"
        seperator
    else
        info "开始系统优化"
        echo -e "\n"

        echo -n "tuned..."
        if tuned_; then
            echo "✓"
        else
            echo "✗ (可忽略)"
        fi

        echo -n "txqueuelen..."
        if set_txqueuelen_; then
            echo "✓"
        else
            echo "✗ (可忽略)"
        fi

        echo -n "文件打开限制..."
        if set_file_open_limit_; then
            echo "✓"
        else
            echo "✗ (可忽略)"
        fi

        systemd-detect-virt > /dev/null 2>&1
        virt_result=$?
        if [ $virt_result -eq 0 ]; then
            warn "检测到虚拟化环境,跳过部分硬件优化"
        else
            echo -n "磁盘调度器..."
            if set_disk_scheduler_; then
                echo "✓"
            else
                echo "✗ (可忽略)"
            fi
            
            echo -n "Ring Buffer..."
            if set_ring_buffer_; then
                echo "✓"
            else
                echo "✗ (可忽略)"
            fi
        fi

        echo -n "初始拥塞窗口..."
        if set_initial_congestion_window_; then
            echo "✓"
        else
            echo "✗ (可忽略)"
        fi

        echo -n "内核参数 (BBR)..."
        if kernel_settings_; then
            echo "✓"
        else
            echo "✗ (BBR 不可用)"
        fi

        touch "$OPTIM_MARKER"

        seperator

        # ===== 创建开机启动脚本 =====
        info "配置开机启动脚本"
        cat > /root/.boot-script.sh << 'EOFBOOT'
#!/bin/bash
sleep 120s

INTERFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}')

if [ -n "$(which ifconfig 2>/dev/null)" ] && [ -n "$INTERFACE" ]; then
    ifconfig $INTERFACE txqueuelen 10000 2>/dev/null || true
fi

IPROUTE=$(ip -o -4 route show to default 2>/dev/null)
if [ -n "$IPROUTE" ]; then
    ip route change $IPROUTE initcwnd 25 initrwnd 25 2>/dev/null || true
fi

systemd-detect-virt > /dev/null 2>&1
if [ $? -ne 0 ]; then
    if [ -n "$(which ethtool 2>/dev/null)" ] && [ -n "$INTERFACE" ]; then
        ethtool -G $INTERFACE rx 1024 2>/dev/null || true
        ethtool -G $INTERFACE tx 2048 2>/dev/null || true
    fi
    
    for disk in $(lsblk -nd --output NAME 2>/dev/null | grep -v '^md'); do
        if [ -f /sys/block/$disk/queue/scheduler ]; then
            SCHEDULER=$(cat /sys/block/$disk/queue/scheduler 2>/dev/null)
            if [[ "$SCHEDULER" != *"none"* ]] || [[ "$SCHEDULER" =~ mq-deadline|kyber|bfq ]]; then
                DISKTYPE=$(cat /sys/block/$disk/queue/rotational 2>/dev/null || echo "1")
                if [ "$DISKTYPE" == "0" ]; then
                    if [[ "$SCHEDULER" =~ kyber ]]; then
                        echo kyber > /sys/block/$disk/queue/scheduler 2>/dev/null || true
                    elif [[ "$SCHEDULER" =~ mq-deadline ]]; then
                        echo mq-deadline > /sys/block/$disk/queue/scheduler 2>/dev/null || true
                    fi
                else
                    if [[ "$SCHEDULER" =~ mq-deadline ]]; then
                        echo mq-deadline > /sys/block/$disk/queue/scheduler 2>/dev/null || true
                    fi
                fi
            fi
        fi
    done
fi

modprobe tcp_bbr 2>/dev/null || true
EOFBOOT

        chmod +x /root/.boot-script.sh

        cat > /etc/systemd/system/boot-script.service << 'EOF'
[Unit]
Description=Boot optimization script
After=network.target

[Service]
Type=simple
ExecStart=/root/.boot-script.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload 2>/dev/null
        systemctl enable boot-script.service >/dev/null 2>&1
        info "✓ 开机启动脚本配置完成"

        seperator
    fi
else
    info "未启用系统优化,跳过"
    seperator
fi

# ===== 安装完成 (新格式输出) =====
info "安装完成!"
echo -e "\n"

publicip=$(curl -s --max-time 5 https://ipinfo.io/ip 2>/dev/null || echo "无法获取")

if [[ -n "$vertex_install_success" ]]; then
    vertex_container_ip=""
    vertex_bridge_gateway=""
    if command -v docker >/dev/null 2>&1; then
        vertex_container_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$vertex_name" 2>/dev/null)
        vertex_bridge_gateway=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
    fi
    echo "--------"
    info "🌐 Vertex"
    boring_text "管理地址: http://$publicip:$vertex_port"
    if [ -n "$vertex_container_ip" ]; then
        boring_text "Vertex容器内网地址: $vertex_container_ip:3000"
    fi
    if [ -n "$vertex_bridge_gateway" ]; then
        boring_text "如需通过内网连接qBit,请在下载器中使用: $vertex_bridge_gateway:$qb_port"
    fi
fi

if [[ -n "$qb_install_success" ]]; then
    echo "--------"
    info "🧩 qBittorrent"
    boring_text "管理地址: http://$publicip:$qb_port"
fi

if [[ -n "$filebrowser_install_success" ]]; then
    echo "--------"
    info "📁 FileBrowser"
    boring_text "管理地址: http://$publicip:$filebrowser_port"
fi

echo "--------"
if [[ -n "$qb_install_success" ]] || [[ -n "$vertex_install_success" ]] || [[ -n "$filebrowser_install_success" ]]; then
    info "🔐 账号信息"
    boring_text "用户名: $username"
    boring_text "密码: $password"
    echo "--------"
fi
echo -e "\n"

warn "建议重启系统以确保所有优化生效，如果无法打开网页，可能是防火墙没有放通端口"
boring_text "  重启命令: reboot"

seperator

exit 0
