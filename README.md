# nginx-site-manager
一键交互式配置 Nginx 反向代理（支持 WebSocket）并自动申请 Let's Encrypt HTTPS 证书
# Nginx 反向代理 & SSL 交互式管理工具

一键交互式配置 Nginx 反向代理（支持 WebSocket）并自动申请 Let's Encrypt HTTPS 证书。

## 一键安装

```bash
sudo curl -fsSL https://githubusercontent.com -o /usr/local/bin/site && sudo chmod +x /usr/local/bin/site
```

## 使用方法

在任意目录下执行：
```bash
sudo site
```

## 功能列表
- **添加新站点**：输入域名和本地端口，自动生成反代配置并调用 Certbot 申请证书。
- **删除现有站点**：自动清理 Nginx 配置文件并删除对应的 SSL 证书。
- **查看站点状态**：列出当前所有反代域名、目标端口及 HTTPS 状态。
