#!/bin/bash
# Nginx 反向代理 & SSL 交互式管理工具
SCRIPT_VERSION="1.3.0"
SCRIPT_URL="https://raw.githubusercontent.com/wysadmin/nginx-site-manager/main/site.sh"
SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

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
    local i
    # 80/443 为网站对外端口，封禁会导致站点无法访问
    case "$port" in
        80|443)
            echo "⚠️ 端口 ${port} 是网站对外端口，已跳过封禁。"
            return
            ;;
    esac

    # 1) UFW：必须插到规则链最前面（ufw deny 默认追加在 allow 之后，会被放行规则覆盖）
    if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        for i in 1 2 3; do ufw delete deny "${port}/tcp" >/dev/null 2>&1 || break; done
        ufw insert 1 deny "${port}/tcp" >/dev/null 2>&1
        echo "🛡️ UFW：已在规则链首部禁止外部访问 ${port}/tcp"
    fi

    # 2) Firewalld：移除放行并显式添加 drop rich rule
    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1
        firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" port port=\"${port}\" protocol=\"tcp\" drop" >/dev/null 2>&1
        firewall-cmd --permanent --add-rich-rule="rule family=\"ipv6\" port port=\"${port}\" protocol=\"tcp\" drop" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo "🛡️ Firewalld：已移除 ${port}/tcp 的放行并添加 drop 规则"
    fi

    # 3) iptables/ip6tables：插入到 INPUT 链首部，避免被前置的 ACCEPT 规则提前放行
    if command -v iptables &> /dev/null; then
        for i in 1 2 3; do iptables -D INPUT -p tcp --dport "${port}" -j DROP 2>/dev/null || break; done
        iptables -I INPUT 1 -p tcp --dport "${port}" -j DROP 2>/dev/null
        for i in 1 2 3; do iptables -D INPUT -i lo -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || break; done
        iptables -I INPUT 1 -i lo -p tcp --dport "${port}" -j ACCEPT 2>/dev/null
        if command -v ip6tables &> /dev/null; then
            for i in 1 2 3; do ip6tables -D INPUT -p tcp --dport "${port}" -j DROP 2>/dev/null || break; done
            ip6tables -I INPUT 1 -p tcp --dport "${port}" -j DROP 2>/dev/null
            for i in 1 2 3; do ip6tables -D INPUT -i lo -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || break; done
            ip6tables -I INPUT 1 -i lo -p tcp --dport "${port}" -j ACCEPT 2>/dev/null
        fi
        echo "🛡️ iptables：已在 INPUT 链首部拦截 ${port}/tcp（本机回环放行）"

        # 4) Docker：容器端口经 nat/FORWARD 转发，不经过 INPUT，需在 DOCKER-USER 链拦截
        if iptables -S DOCKER-USER &> /dev/null; then
            for i in 1 2 3; do iptables -D DOCKER-USER -p tcp --dport "${port}" -j DROP 2>/dev/null || break; done
            iptables -I DOCKER-USER 1 -p tcp --dport "${port}" -j DROP 2>/dev/null
            for i in 1 2 3; do iptables -D DOCKER-USER -i lo -j RETURN 2>/dev/null || break; done
            iptables -I DOCKER-USER 1 -i lo -j RETURN 2>/dev/null
            echo "🛡️ Docker：已在 DOCKER-USER 链拦截 ${port}/tcp（放行本机回环）"
        fi
    fi

    # 5) 尽力持久化，避免重启后规则丢失
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save >/dev/null 2>&1 && echo "💾 规则已持久化（netfilter-persistent）"
    elif [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null && echo "💾 规则已保存到 /etc/iptables/rules.v4"
    fi

    # 6) 后置自检：看后端究竟监听在哪个地址
    local listen_addr=""
    if command -v ss &> /dev/null; then
        listen_addr=$(ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print $4; exit}')
    elif command -v netstat &> /dev/null; then
        listen_addr=$(netstat -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print $4; exit}')
    fi
    if printf '%s' "$listen_addr" | grep -qE '^(127\.|\[::1\]|::1)'; then
        echo "✅ 自检：后端仅监听本机地址（${listen_addr}），外部本就无法直连。"
    elif [ -n "$listen_addr" ]; then
        echo "⚠️ 自检：后端监听在 ${listen_addr}（对外地址），已交由防火墙拦截。"
        echo "💡 更彻底的做法是让服务改绑 127.0.0.1，或 Docker 映射写成 127.0.0.1:${port}:${port}。"
    fi
}
# 解除后端端口封禁（删除站点时调用）
unblock_external_port() {
    local port=$1
    local i
    [ -z "$port" ] && return
    if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        for i in 1 2 3; do ufw delete deny "${port}/tcp" >/dev/null 2>&1 || break; done
    fi
    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-rich-rule="rule family=\"ipv4\" port port=\"${port}\" protocol=\"tcp\" drop" >/dev/null 2>&1
        firewall-cmd --permanent --remove-rich-rule="rule family=\"ipv6\" port port=\"${port}\" protocol=\"tcp\" drop" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    if command -v iptables &> /dev/null; then
        for i in 1 2 3; do iptables -D INPUT -p tcp --dport "${port}" -j DROP 2>/dev/null || break; done
        for i in 1 2 3; do iptables -D INPUT -i lo -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || break; done
        if iptables -S DOCKER-USER &> /dev/null; then
            for i in 1 2 3; do iptables -D DOCKER-USER -p tcp --dport "${port}" -j DROP 2>/dev/null || break; done
            for i in 1 2 3; do iptables -D DOCKER-USER -i lo -j RETURN 2>/dev/null || break; done
        fi
        if command -v ip6tables &> /dev/null; then
            for i in 1 2 3; do ip6tables -D INPUT -p tcp --dport "${port}" -j DROP 2>/dev/null || break; done
            for i in 1 2 3; do ip6tables -D INPUT -i lo -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || break; done
        fi
    fi
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save >/dev/null 2>&1
    fi
}
# 列出当前对外封禁的端口
list_blocked_ports() {
    echo "------------------------------------------"
    echo "🔍 当前对外封禁的端口："
    local found=0
    local lines
    lines=$({
        if command -v ufw &> /dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw status 2>/dev/null | awk '/^[0-9]+\/tcp[[:space:]]+DENY/ {split($1,a,"/"); print a[1]"|UFW DENY"}'
        fi
        if command -v iptables &> /dev/null; then
            for chan in INPUT DOCKER-USER; do
                iptables -S "$chan" 2>/dev/null | awk -v c="$chan" '/-j DROP/ {for(i=1;i<=NF;i++) if($i=="--dport") print $(i+1)"|iptables "c}'
            done
        fi
    } | sort -u)
    if [ -n "$lines" ]; then
        echo "$lines" | while IFS='|' read -r p src; do
            [ -n "$p" ] && echo "  • 端口 ${p}  [${src}]"
        done
        found=1
    fi
    if [ "$found" -eq 0 ]; then
        echo "  (暂无封禁规则)"
    fi
    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "  ℹ️ Firewalld 模式通过移除放行 + drop 规则实现，当前放行端口："
        echo "     $(firewall-cmd --list-ports 2>/dev/null)"
    fi
    echo "------------------------------------------"
}
# 端口封禁排障诊断
diagnose_port_guard() {
    echo ""
    echo ">>> [端口封禁排障诊断]"
    echo "── 1. 当前监听的 TCP 端口 ──"
    if command -v ss &> /dev/null; then
        ss -lntp 2>/dev/null | head -n 30
    elif command -v netstat &> /dev/null; then
        netstat -lntp 2>/dev/null | head -n 30
    else
        echo "(缺少 ss/netstat，无法列出监听端口)"
    fi
    echo "── 2. Docker 端口映射（若存在）──"
    if command -v docker &> /dev/null; then
        docker ps --format 'table {{.Names}}\t{{.Ports}}' 2>/dev/null | head -n 20
    else
        echo "(未安装 Docker)"
    fi
    echo "── 3. UFW 规则（带序号，注意顺序）──"
    if command -v ufw &> /dev/null; then
        ufw status numbered 2>/dev/null | head -n 20
    else
        echo "(未安装 UFW)"
    fi
    echo "── 4. iptables INPUT 前 15 条 ──"
    if command -v iptables &> /dev/null; then
        iptables -S INPUT 2>/dev/null | head -n 15
    else
        echo "(未安装 iptables)"
    fi
    echo "── 5. iptables DOCKER-USER ──"
    if command -v iptables &> /dev/null; then
        iptables -S DOCKER-USER 2>/dev/null || echo "(无 DOCKER-USER 链)"
    fi
    echo "── 6. Firewalld 放行端口 ──"
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --list-ports 2>/dev/null || echo "(未运行)"
    else
        echo "(未安装 firewalld)"
    fi
    echo ""
    echo "💡 判断要点："
    echo "   1) 若端口由 Docker 映射（docker ps 中看到 0.0.0.0:端口->），必须走 DOCKER-USER 链或改绑 127.0.0.1；"
    echo "   2) 若 UFW 里 allow 规则序号在 deny 之前，deny 不生效；"
    echo "   3) 若 INPUT 前面已有 -A INPUT -j ACCEPT 之类规则，末尾的 DROP 不会命中；"
    echo "   4) 云厂商安全组只是额外一层，不影响本机防火墙是否生效。"
}
# 解析用户输入的端口（支持空格/逗号分隔的多个端口）
parse_ports() {
    echo "$1" | tr ',' ' ' | tr -s ' \t' '\n' | grep -E '^[0-9]+$'
}
# 对外端口封禁管理（独立功能）
port_guard_menu() {
    while true; do
        echo ""
        echo ">>> [对外端口封禁管理]"
        echo "  1. 封禁端口 (禁止外部直连，仅允许本机 Nginx 转发)"
        echo "  2. 解除端口封禁"
        echo "  3. 查看当前封禁列表"
        echo "  4. 排障诊断 (监听端口 + 防火墙规则)"
        echo "  0. 返回主菜单"
        read -p "请选择操作 [0-4]: " PCH
        case "$PCH" in
            1)
                echo ""
                list_blocked_ports
                read -p "请输入要封禁的端口 (多个用空格或逗号分隔，例如 8070 8090): " PORTS_IN
                local plist cnt
                plist=$(parse_ports "$PORTS_IN")
                if [ -z "$plist" ]; then
                    echo "❌ 未识别到有效端口号。"
                    continue
                fi
                cnt=0
                for p in $plist; do
                    block_external_port "$p"
                    cnt=$((cnt + 1))
                done
                echo "🎉 封禁流程执行完毕，共处理 ${cnt} 个端口。"
                echo "ℹ️ 说明：封禁只拦截外部直连，本机 127.0.0.1 转发不受影响。"
                ;;
            2)
                echo ""
                list_blocked_ports
                read -p "请输入要解除封禁的端口 (多个用空格或逗号分隔): " PORTS_OUT
                local olist
                olist=$(parse_ports "$PORTS_OUT")
                if [ -z "$olist" ]; then
                    echo "❌ 未识别到有效端口号。"
                    continue
                fi
                for p in $olist; do
                    unblock_external_port "$p"
                    echo "✅ 已解除端口 ${p} 的外部封禁"
                done
                echo "ℹ️ 若 Firewalld 模式下需重新放行，请自行执行: firewall-cmd --permanent --add-port=<端口>/tcp && firewall-cmd --reload"
                ;;
            3)
                echo ""
                list_blocked_ports
                ;;
            4)
                diagnose_port_guard
                ;;
            0)
                return
                ;;
            *)
                echo "❌ 无效选项，请输入 0 到 4 之间的数字。"
                ;;
        esac
    done
}
# 下载远程文件（curl 优先，其次 wget）
fetch_url() {
    local url=$1
    local dest=$2
    if command -v curl &> /dev/null; then
        curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$dest"
    elif command -v wget &> /dev/null; then
        wget -q -T 30 -O "$dest" "$url"
    else
        return 1
    fi
}
# 计算文件校验值（自适应可用工具）
file_checksum() {
    local f=$1
    if command -v md5sum &> /dev/null; then
        md5sum "$f" | awk '{print $1}'
    elif command -v sha256sum &> /dev/null; then
        sha256sum "$f" | awk '{print $1}'
    elif command -v cksum &> /dev/null; then
        cksum "$f" | awk '{print $1"-"$2}'
    else
        echo "unknown"
    fi
}
# 手动检测并更新脚本自身
check_update() {
    echo ""
    echo ">>> [检测脚本更新]"
    echo "ℹ️ 本地版本: v${SCRIPT_VERSION}"
    echo "ℹ️ 脚本路径: ${SELF_PATH}"
    echo "ℹ️ 更新源: ${SCRIPT_URL}"
    local tmp="/tmp/site.sh.remote.$$"
    echo "⏳ 正在拉取远端脚本..."
    if ! fetch_url "$SCRIPT_URL" "$tmp" || [ ! -s "$tmp" ]; then
        echo "❌ 下载失败，请检查网络连通性或域名解析后重试。"
        rm -f "$tmp"
        return
    fi
    sed -i 's/\r$//' "$tmp" 2>/dev/null
    if ! bash -n "$tmp" 2>/dev/null; then
        echo "❌ 远端脚本语法校验未通过，已放弃本次更新。"
        rm -f "$tmp"
        return
    fi
    local local_sum remote_sum
    local_sum=$(file_checksum "$SELF_PATH")
    remote_sum=$(file_checksum "$tmp")
    echo "ℹ️ 本地校验值: ${local_sum}"
    echo "ℹ️ 远端校验值: ${remote_sum}"
    if [ "$local_sum" = "$remote_sum" ]; then
        echo "✅ 当前已是最新版本，无需更新。"
        rm -f "$tmp"
        return
    fi
    echo "🔄 检测到远端脚本有变化，可更新。"
    local remote_ver
    remote_ver=$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)
    if [ -n "$remote_ver" ] && [ "$remote_ver" != "$SCRIPT_VERSION" ]; then
        local newest
        newest=$(printf '%s\n%s\n' "$SCRIPT_VERSION" "$remote_ver" | sort -V 2>/dev/null | tail -n1)
        if [ "$newest" = "$remote_ver" ]; then
            echo "🆕 远端版本 v${remote_ver} 高于本地 v${SCRIPT_VERSION}，建议更新。"
        else
            echo "⚠️ 远端版本 v${remote_ver} 低于本地 v${SCRIPT_VERSION}，说明远端是旧版/原版。"
            echo "⚠️ 继续更新会覆盖本地功能，请谨慎操作。"
        fi
    elif [ -n "$remote_ver" ]; then
        echo "ℹ️ 远端版本号同为 v${remote_ver}，但内容与本地不同（本地可能已被修改）。"
    fi
    read -p "是否立即更新到最新版本？(y/n): " UPDATE_CONFIRM
    if [[ "$UPDATE_CONFIRM" != "y" && "$UPDATE_CONFIRM" != "Y" ]]; then
        echo "已取消更新。"
        rm -f "$tmp"
        return
    fi
    local backup="${SELF_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    if [ -f "$SELF_PATH" ]; then
        cp -f "$SELF_PATH" "$backup" && echo "💾 已备份原脚本: ${backup}"
    fi
    # 先写入同目录临时文件并校验，再原子替换，避免破坏正在执行的脚本
    local newfile="${SELF_PATH}.new.$$"
    if cp -f "$tmp" "$newfile" && chmod 755 "$newfile" && bash -n "$newfile" 2>/dev/null && mv -f "$newfile" "$SELF_PATH"; then
        echo "✅ 更新完成，请重新运行: sudo ${SELF_PATH}"
        rm -f "$tmp"
        exit 0
    else
        echo "❌ 更新写入失败，正在回滚..."
        rm -f "$newfile"
        if [ -f "$backup" ]; then
            cp -f "$backup" "$SELF_PATH" && chmod 755 "$SELF_PATH" && echo "↩️ 已回滚到更新前版本。"
        fi
        rm -f "$tmp"
    fi
}
# 卸载本管理工具（可选清理其生成的站点配置与证书）
uninstall_self() {
    echo ""
    echo ">>> [卸载本管理工具]"
    echo "ℹ️ 脚本路径: ${SELF_PATH}"
    if [ ! -f "$SELF_PATH" ]; then
        echo "⚠️ 当前运行的不是已安装的脚本文件（可能通过管道执行），无法自动删除自身。"
        echo "ℹ️ 请手动删除你安装的脚本文件后退出。"
        return
    fi
    read -p "⚠️ 确认卸载本管理工具（删除脚本文件）吗？(y/n): " UN_CONFIRM
    if [[ "$UN_CONFIRM" != "y" && "$UN_CONFIRM" != "Y" ]]; then
        echo "已取消卸载。"
        return
    fi

    read -p "是否同时清理本工具生成过的 Nginx 站点配置与 SSL 证书？(y/n): " CLEAN_SITES
    if [[ "$CLEAN_SITES" == "y" || "$CLEAN_SITES" == "Y" ]]; then
        echo "⚠️ 将删除 /etc/nginx/conf.d 下由本工具生成的站点配置（含 00-default-deny.conf），并删除对应 Let's Encrypt 证书。"
        read -p "此操作不可恢复，请输入 DELETE 确认: " DANGER
        if [ "$DANGER" != "DELETE" ]; then
            echo "❌ 确认字符串不匹配，已跳过站点清理。"
        else
            local removed=0
            for f in /etc/nginx/conf.d/*.conf; do
                [ ! -e "$f" ] && continue
                local filename
                filename=$(basename "$f")
                # 仅处理本工具生成的配置：带标记，或形如 proxy_pass http://127.0.0.1:<port>
                if ! grep -q "managed-by-nginx-site-manager" "$f" 2>/dev/null; then
                    grep -q 'proxy_pass http://127\.0\.0\.1:[0-9]' "$f" || [ "$filename" == "00-default-deny.conf" ] || continue
                fi
                local d_port=""
                d_port=$(grep -oP 'proxy_pass http://127\.0\.0\.1:\K[0-9]+' "$f" 2>/dev/null | head -n 1)
                local d_domain
                d_domain=$(basename "$f" .conf)
                rm -f "$f"
                removed=$((removed + 1))
                echo "✅ 已删除站点配置: ${f}"
                [ -n "$d_port" ] && unblock_external_port "$d_port"
                if [ -d "/etc/letsencrypt/live/${d_domain}" ]; then
                    certbot delete --cert-name "$d_domain" --non-interactive >/dev/null 2>&1 \
                        && echo "✅ 已删除 SSL 证书: ${d_domain}"
                fi
            done
            echo "ℹ️ 共清理 ${removed} 个配置文件。"
            if command -v nginx &> /dev/null; then
                echo "⏳ 正在测试并重载 Nginx..."
                if nginx -t && systemctl reload nginx; then
                    echo "✅ Nginx 已成功重载。"
                else
                    echo "❌ Nginx 配置检查异常，请运行 nginx -t 手动排查。"
                fi
            fi
        fi
    fi

    echo "⏳ 正在删除脚本: ${SELF_PATH}"
    if rm -f "$SELF_PATH"; then
        echo "✅ 本管理工具已卸载。"
        echo "ℹ️ Nginx、Certbot 等系统软件未卸载，如需移除请自行执行包管理器卸载命令。"
        echo "ℹ️ 历史备份文件（*.bak.*）未删除，可手动清理。"
        exit 0
    else
        echo "❌ 删除失败，请手动执行: rm -f ${SELF_PATH}"
        return
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
    # managed-by-nginx-site-manager
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
    echo "      Nginx 反向代理 & SSL 管理工具  v${SCRIPT_VERSION}"
    echo "=========================================="
    echo "  1. 添加新站点 (反代 + 禁IP访问 + SSL)"
    echo "  2. 删除现有站点 (清理配置 + 证书)"
    echo "  3. 查看当前所有站点及状态"
    echo "  4. 对外端口封禁管理 (禁止/解除外部直连)"
    echo "  5. 检测脚本更新 (对比远端并升级)"
    echo "  9. 卸载本管理工具"
    echo "  0. 退出"
    echo "=========================================="
    read -p "请选择操作 [0-5/9]: " CHOICE
    case "$CHOICE" in
        1) add_site ;;
        2) del_site ;;
        3) list_sites ;;
        4) port_guard_menu ;;
        5) check_update ;;
        9) uninstall_self ;;
        0) echo "已退出。"; exit 0 ;;
        *) echo "❌ 无效选项，请输入 0-5 或 9。" ;;
    esac
done
