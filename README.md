# Nginx 反向代理 & SSL 交互式管理工具

一键检测环境依赖、交互式配置 Nginx 反向代理（支持 WebSocket 及 100M 文件上传）并自动申请 Let's Encrypt HTTPS 证书。

## 一键安装并运行

```bash
sudo curl -fsSL https://raw.githubusercontent.com/wysadmin/nginx-site-manager/main/site.sh -o /usr/local/bin/site && sudo chmod 755 /usr/local/bin/site && sudo bash -n /usr/local/bin/site && sudo site

```

## 日常使用方法

安装完成后，在任意目录下执行：
```bash
sudo site
```
## 一键卸载

```bash
sudo rm -f /usr/local/bin/site


```

## 彻底清理（卸载脚本 + 清理所有网站配置、拦截规则与 SSL 证书）

```bash
# 1. 删除全局命令
sudo rm -f /usr/local/bin/site

# 2. 删除默认拒绝 IP 访问规则及通过本工具生成的站点配置
sudo rm -f /etc/nginx/conf.d/00-default-deny.conf
# （可选）如需清空 conf.d 下所有站点配置，请取消下一行的注释：
# sudo rm -f /etc/nginx/conf.d/*.conf

# 3. 重载 Nginx 使清理生效
sudo nginx -t && sudo systemctl reload nginx


```
## 功能列表
- **自动环境初始化**：自动检测并安装 `nginx` 和 `certbot`（兼容 Ubuntu/Debian 与 CentOS/Rocky/AlmaLinux）。
- **添加新站点**：输入域名和本地端口，自动生成反代配置（含 WebSocket 支持与大文件上传限制）并调用 Certbot 申请证书。
- **删除现有站点**：自动清理 Nginx 配置文件并删除对应的 SSL 证书。
- **查看站点状态**：列出当前所有反代域名、目标端口及 HTTPS 启用状态。
