#!/bin/bash
set -euo pipefail

# ===================== 配置项 =====================
# 远程二进制文件下载地址
DOWNLOAD_URL="https://github.com/houlaoge/aiw/releases/latest/download/aiw"
# 本地安装路径
INSTALL_PATH="/usr/local/bin/aiw"
# 服务名称
SERVICE_NAME="aiw"
# 服务描述
SERVICE_DESC="AI Web Service"
# 服务配置文件路径
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
# ==================================================

# 检查是否为root用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误：必须以root权限运行此脚本，请使用sudo执行"
        exit 1
    fi
}

# 检测80端口是否被nginx/apache占用（仅提示，不处理）
check_port_80_nginx_apache() {
    local port="$1"

    # 优先使用ss，无则用lsof（兼容不同系统）
    local process_info=""
    if command -v ss >/dev/null 2>&1; then
        # 用ss获取80端口占用的进程信息
        process_info=$(ss -tlnp | grep -E ":${port}\b" | grep -E "nginx|apache" || true)
    elif command -v lsof >/dev/null 2>&1; then
        # 用lsof获取80端口占用的进程信息
        process_info=$(lsof -i ":${port}" -P -n | grep -E "nginx|apache" || true)
    else
        echo "系统未安装ss/lsof，无法检测端口占用情况，请手动确认80端口是否被nginx/apache占用"
        return 0
    fi

    if [ -n "${process_info}" ]; then
        echo -e "\n警告：80端口被nginx/apache占用！"
        echo -e "\n请先手动停止nginx/apache服务后再执行此部署脚本，否则可能导致服务启动失败。"
        echo "1.停止nginx命令：systemctl stop nginx 或 service nginx stop"
        echo -e "2.停止apache命令：systemctl stop httpd 或 service apache2 stop\n\n"
        exit 1
    fi
}

# 下载二进制文件
download_binary() {
    # 使用curl下载，支持断点续传、超时控制，失败重试
    if ! curl -fSL --retry 3 --connect-timeout 10 \
        "${DOWNLOAD_URL}" -o "${INSTALL_PATH}.tmp"; then
        echo "安装包下载失败"
        exit 1
    fi

    # 替换原文件（先赋权再替换，避免权限问题）
    chmod 0755 "${INSTALL_PATH}.tmp"
    mv -f "${INSTALL_PATH}.tmp" "${INSTALL_PATH}"
}

# 创建/更新systemd服务配置
create_service_file() {
    # 生成服务配置内容
    cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=${SERVICE_DESC}
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_PATH} run
Restart=on-failure
RestartSec=3s
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF

    # 设置正确的文件权限（符合systemd标准）
    chmod 0644 "${SERVICE_FILE}"
}

# 重启并验证服务
restart_and_verify_service() {
    # 重新加载配置
    systemctl daemon-reload
    # 设置开机自启
    systemctl enable "${SERVICE_NAME}.service" > /dev/null 2>&1
    # 重启服务（无论是否已运行）
    systemctl stop "${SERVICE_NAME}.service"
    sleep 1
    systemctl start "${SERVICE_NAME}.service"

    # 验证服务是否启动成功（最多等待10秒）
    MAX_WAIT=10
    WAIT_COUNT=0
    while [ ${WAIT_COUNT} -lt ${MAX_WAIT} ]; do
        if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
            echo -e "================================================================================"
            # echo -e "\n${SERVICE_DESC} 下载完成"
            # 输出服务状态摘要
            # systemctl status "${SERVICE_NAME}.service" --no-pager | grep -E "Active|Main PID"
            return 0
        fi
        echo "等待服务启动中... (${WAIT_COUNT}/${MAX_WAIT}秒)"
        sleep 1
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done

    echo "服务启动超时！"
    systemctl status "${SERVICE_NAME}.service" --no-pager
    exit 1
}

# 等待服务端口就绪
wait_for_port_ready() {
    local start_time=$(date +"%Y-%m-%d %H:%M:%S")
    
    # 创建命名管道
    local pipe=$(mktemp -u)
    mkfifo "$pipe"
    
    # 启动 journalctl 并将其输出重定向到命名管道
    stdbuf -oL -eL journalctl -u "$SERVICE_NAME" -f --no-pager -o cat --since="$start_time" 2>/dev/null > "$pipe" &
    local journal_pid=$!
    
    # 从命名管道读取
    while IFS= read -r line; do
        echo "$line"
        
        if [[ "$line" == *"服务启动成功"* ]]; then
            kill "$journal_pid" 2>/dev/null
            rm -f "$pipe"
            return 0
        fi
    done < "$pipe"
    
    # 清理
    kill "$journal_pid" 2>/dev/null
    rm -f "$pipe"
    return 1
}

# 主执行流程
main() {
    echo "开始下载安装包..."
    echo "================================================================================"

    # 1. 检查root权限
    check_root

    # 2. 检测80端口是否被nginx/apache占用
    check_port_80_nginx_apache "80"

    # 3. 下载二进制文件
    download_binary

    # 4. 创建/更新服务配置
    create_service_file

    # 5. 重启并验证服务
    restart_and_verify_service

    # 6. 等待端口就绪
    wait_for_port_ready
    echo -e "\n输入命令 aiw 回车，打开服务管理工具\n\n"

}

# 执行主函数
main "$@"
