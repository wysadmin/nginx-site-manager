#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 sudo 或 root 用户运行此脚本。"
  exit 1
fi

# 自动检测并安装环境依赖
check_dependencies() {
    local need_install=0
    if ! command -v nginx &> /dev/null || ! command -v certbot &> /dev/null; then
        need_install=1
    fi

    if [ "$need_install" -eq 1 ]; then
        echo "⏳ 检测到系统缺少 Nginx 或 Certbot，正在自动安装环境依赖..."
        if command -v apt-get &> /dev/null; then
            apt-get update -y
            apt-get install -y nginx certbot python3-certbot-nginx
        elif command -v dnf &> /dev/null; then
            dnf install -y epel-release
            dnf install -y nginx certbot python3-certbot-nginx
        elif command -v yum &> /dev/null; then
            yum install -y epel-release
            yum install -y nginx certbot python3-certbot-nginx
        else
            echo "❌ 未识别的系统包管理器，请手动安装 nginx 和 certbot 后再运行。"
            exit 1
        fi

        mkdir -p /etc/nginx/conf.d
        systemctl enable nginx
        systemctl start nginx
        echo "✅ 环境依赖安装并启动完成！"
    fi
}

# 配置默认拒绝直接通过服务器 IP 访问 80 端口
setup_default_deny() {
    local deny_conf="/etc/nginx/conf.d/00-default-deny.conf"
    if [ ! -f "$deny_conf" ]; then
        cat > "$deny_conf" << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
EOF
    fi
}

# 封禁外部直接访问后端端口（仅允许本地 127.0.0.1 Nginx 转发）
block_external_port() {
    local port=$1
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw deny "${port}/tcp" >/dev/null 2>&1
        echo "🛡️ 已通过 UFW 禁止外部直接访问 ${port} 端口"
    elif command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo "🛡️ 已通过 Firewalld 移除外部对 ${port} 端口的放行"
    elif command -v iptables &> /dev/null; then
        # 允许本机回环通信，拦截外部访问该端口
        iptables -C INPUT -i lo -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -i lo -p tcp --dport "${port}" -j ACCEPT
        iptables -C INPUT -p tcp --dport "${port}" -j DROP 2>/dev/null || \
            iptables -A INPUT -p tcp --dport "${port}" -j DROP
        if command -v ip6tables &> /dev/null; then
            ip6tables -C INPUT -i lo -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || \
                ip6tables -I INPUT -i lo -p tcp --dport "${port}" -j ACCEPT
            ip6tables -C INPUT -p tcp --dport "${port}" -j DROP 2>/dev/null || \
                ip6tables -A INPUT -p tcp --dport "${port}" -j DROP
        fi
        echo "🛡️ 已通过 iptables/ip6tables 禁止外部 IP:${port} 直接访问"
    fi
}

# 解除后端端口封禁（删除站点时调用）
unblock_external_port() {
    local port=$1
    [ -z "$port" ] && return
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw delete deny "${port}/tcp" >/dev/null 2>&1
    elif command -v iptables &> /dev/null; then
        iptables -D INPUT -p tcp --dport "${port}" -j DROP 2>/dev/null
        iptables -D INPUT -i lo -p tcp --dport "${port}" -j ACCEPT 2>/dev/null
        if command -v ip6tables &> /dev/null; then
            ip6tables -D INPUT -p tcp --dport "${port}" -j DROP 2>/dev/null
            ip6tables -D INPUT -i lo -p tcp --dport "${port}" -j ACCEPT 2>/dev/null
        fi
    fi
}

# 启动时执行环境检测
check_dependencies

# 查看站点列表函数
list_sites() {
    echo "------------------------------------------"
    echo "📋 当前已配置的站点列表："
    local has_site=0
    for f in /etc/nginx/conf.d/*.conf; do
        [ ! -e "$f" ] && continue
        local filename=$(basename "$f")
        # 跳过默认拒绝规则文件
        [ "$filename" == "00-default-deny.conf" ] && continue
        has_site=1
        local domain=$(basename "$f" .conf)
        local port=$(grep -oP 'proxy_pass http://127\.0\.0\.1:\K[0-9]+' "$f" | head -n 1)
        local ssl_status="❌ 未配置 SSL"
        [ -d "/etc/letsencrypt/live/${domain}" ] && ssl_status="🔒 HTTPS 已启用"
        echo "  • ${domain}  -->  端口: ${port:-未知}  [${ssl_status}]"
    done
    [ "$has_site" -eq 0 ] && echo "  (暂无站点配置)"
    echo "------------------------------------------"
}

# 添加站点函数
add_site() {
    echo ""
    echo ">>> [添加新站点]"
    read -p "请输入域名 (例如 xiao1.542527.xyz): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo "❌ 域名不能为空。"
        return
    fi

    read -p "请输入后端服务本地端口 (例如 8070): " PORT
    if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
        echo "❌ 端口号必须是纯数字。"
        return
    fi

    CONF_FILE="/etc/nginx/conf.d/${DOMAIN}.conf"

    if [ -f "$CONF_FILE" ]; then
        read -p "⚠️ 配置文件 ${CONF_FILE} 已存在，是否覆盖？(y/n): " OVERWRITE
        if [[ "$OVERWRITE" != "y" && "$OVERWRITE" != "Y" ]]; then
            echo "已取消操作。"
            return
        fi
    fi

    # 确保默认拒绝直接 IP 访问生效
    setup_default_deny

    echo "⏳ 正在生成 Nginx 配置文件..."
    cat > "$CONF_FILE" << NGINX_EOF
server {
    listen 80;
    server_name ${DOMAIN};

    # 允许上传较大文件，避免默认 1MB 限制报错
    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # 支持 WebSocket
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX_EOF

    echo "⏳ 正在测试 Nginx 配置并重载..."
    if nginx -t && systemctl reload nginx; then
        echo "✅ Nginx 反向代理配置成功！"
    else
        echo "❌ Nginx 配置测试失败，正在回滚删除配置文件..."
        rm -f "$CONF_FILE"
        return
    fi

    read -p "是否禁止外部通过 IP:${PORT} 直接访问该端口？(推荐 y) [y/n]: " BLOCK_PORT
    if [[ "$BLOCK_PORT" == "y" || "$BLOCK_PORT" == "Y" || -z "$BLOCK_PORT" ]]; then
        block_external_port "$PORT"
    fi

    read -p "是否立即为 ${DOMAIN} 申请 Let's Encrypt HTTPS 证书？(y/n): " APPLY_SSL
    if [[ "$APPLY_SSL" == "y" || "$APPLY_SSL" == "Y" ]]; then
        echo "⏳ 正在调用 Certbot 申请证书..."
        certbot --nginx -d "$DOMAIN"
    else
        echo "ℹ️ 已跳过证书申请。后续可手动运行: certbot --nginx -d ${DOMAIN}"
    fi
    echo "🎉 添加流程执行完毕！"
}

# 删除站点函数
del_site() {
    echo ""
    echo ">>> [删除站点]"
    list_sites
    read -p "请输入要删除的域名: " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo "❌ 域名不能为空。"
        return
    fi

    CONF_FILE="/etc/nginx/conf.d/${DOMAIN}.conf"

    if [ ! -f "$CONF_FILE" ] && [ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
        echo "⚠️ 未找到域名 ${DOMAIN} 的 Nginx 配置文件或 SSL 证书。"
        return
    fi

    read -p "⚠️ 确定要彻底删除 ${DOMAIN} 的 Nginx 配置和 SSL 证书吗？(y/n): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "已取消操作。"
        return
    fi

    local OLD_PORT=""
    if [ -f "$CONF_FILE" ]; then
        OLD_PORT=$(grep -oP 'proxy_pass http://127\.0\.0\.1:\K[0-9]+' "$CONF_FILE" | head -n 1)
        rm -f "$CONF_FILE"
        echo "✅ 已删除 Nginx 配置文件: ${CONF_FILE}"
    fi

    if [ -n "$OLD_PORT" ]; then
        unblock_external_port "$OLD_PORT"
    fi

    if [ -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
        echo "⏳ 正在删除对应的 SSL 证书..."
        certbot delete --cert-name "$DOMAIN" --non-interactive
        echo "✅ 已删除 SSL 证书: ${DOMAIN}"
    fi

    echo "⏳ 正在测试并重载 Nginx..."
    if nginx -t && systemctl reload nginx; then
        echo "✅ Nginx 已成功重载！站点 ${DOMAIN} 已彻底清理。"
    else
        echo "❌ Nginx 配置检查异常，请运行 nginx -t 手动排查。"
    fi
}

# 主菜单循环
while true; do
    echo ""
    echo "=========================================="
    echo "      Nginx 反向代理 & SSL 管理工具"
    echo "=========================================="
    echo "  1. 添加新站点 (反代 + 禁IP访问 + SSL)"
    echo "  2. 删除现有站点 (清理配置 + 证书)"
    echo "  3. 查看当前所有站点及状态"
    echo "  0. 退出"
    echo "=========================================="
    read -p "请选择操作 [0-3]: " CHOICE

    case "$CHOICE" in
        1) add_site ;;
        2) del_site ;;
        3) list_sites ;;
        0) echo "已退出。"; exit 0 ;;
        *) echo "❌ 无效选项，请输入 0 到 3 之间的数字。" ;;
    esac
done
