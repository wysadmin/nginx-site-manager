🔍 当前对外封禁的端口：
  • 端口 8888  [iptables DOCKER-USER]
  • 端口 8888  [iptables INPUT]
------------------------------------------
请输入要封禁的端口 (多个用空格或逗号分隔，例如 8070 8090): 8070
🛡️ iptables：已在 INPUT 链首部拦截 8070/tcp（本机回环放行）
🛡️ Docker：已在 DOCKER-USER 链拦截 8070/tcp（放行本机回环）
💾 规则已保存到 /etc/iptables/rules.v4
⚠️ 自检：后端监听在 0.0.0.0:8070（对外地址），已交由防火墙拦截。
💡 更彻底的做法是让服务改绑 127.0.0.1，或 Docker 映射写成 127.0.0.1:8070:8070。
🎉 封禁流程执行完毕，共处理 1 个端口。
ℹ️ 说明：封禁只拦截外部直连，本机 127.0.0.1 转发不受影响。

>>> [对外端口封禁管理]
  1. 封禁端口 (禁止外部直连，仅允许本机 Nginx 转发)
  2. 解除端口封禁
  3. 查看当前封禁列表
  4. 排障诊断 (监听端口 + 防火墙规则)
  0. 返回主菜单
请选择操作 [0-4]: 4

>>> [端口封禁排障诊断]
── 1. 当前监听的 TCP 端口 ──
State  Recv-Q Send-Q Local Address:Port  Peer Address:PortProcess                                                                                  
LISTEN 0      4096         0.0.0.0:8070       0.0.0.0:*    users:(("docker-proxy",pid=1724,fd=8))                                                  
LISTEN 0      511          0.0.0.0:443        0.0.0.0:*    users:(("nginx",pid=339223,fd=14),("nginx",pid=339222,fd=14),("nginx",pid=307611,fd=14))
LISTEN 0      511          0.0.0.0:80         0.0.0.0:*    users:(("nginx",pid=339223,fd=5),("nginx",pid=339222,fd=5),("nginx",pid=307611,fd=5))   
LISTEN 0      128          0.0.0.0:1123       0.0.0.0:*    users:(("sshd",pid=753,fd=3))                                                           
LISTEN 0      4096       127.0.0.1:43447      0.0.0.0:*    users:(("v2ray",pid=734,fd=3))                                                          
LISTEN 0      4096         0.0.0.0:8888       0.0.0.0:*    users:(("docker-proxy",pid=1671,fd=8))                                                  
LISTEN 0      4096      127.0.0.54:53         0.0.0.0:*    users:(("systemd-resolve",pid=574,fd=17))                                               
LISTEN 0      4096   127.0.0.53%lo:53         0.0.0.0:*    users:(("systemd-resolve",pid=574,fd=15))                                               
LISTEN 0      4096               *:26991            *:*    users:(("v2ray",pid=734,fd=6))                                                          
LISTEN 0      4096            [::]:8070          [::]:*    users:(("docker-proxy",pid=1731,fd=8))                                                  
LISTEN 0      511             [::]:443           [::]:*    users:(("nginx",pid=339223,fd=13),("nginx",pid=339222,fd=13),("nginx",pid=307611,fd=13))
LISTEN 0      511             [::]:80            [::]:*    users:(("nginx",pid=339223,fd=6),("nginx",pid=339222,fd=6),("nginx",pid=307611,fd=6))   
LISTEN 0      128             [::]:1123          [::]:*    users:(("sshd",pid=753,fd=4))                                                           
LISTEN 0      4096            [::]:8888          [::]:*    users:(("docker-proxy",pid=1682,fd=8))                                                  
── 2. Docker 端口映射（若存在）──
NAMES            PORTS
kejilion-panel   0.0.0.0:8070->8080/tcp, [::]:8070->8080/tcp
molilotto        0.0.0.0:8888->8888/tcp, [::]:8888->8888/tcp
── 3. UFW 规则（带序号，注意顺序）──
(未安装 UFW)
── 4. iptables INPUT 前 15 条 ──
-P INPUT ACCEPT
-A INPUT -i lo -p tcp -m tcp --dport 8070 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 8070 -j DROP
-A INPUT -i lo -p tcp -m tcp --dport 8888 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 8888 -j DROP
── 5. iptables DOCKER-USER ──
-N DOCKER-USER
-A DOCKER-USER -i lo -j RETURN
-A DOCKER-USER -p tcp -m tcp --dport 8070 -j DROP
-A DOCKER-USER -p tcp -m tcp --dport 8888 -j DROP
-A DOCKER-USER -d 172.18.0.2/32 -m state --state RELATED,ESTABLISHED -j ACCEPT
-A DOCKER-USER -s 127.0.0.0/8 -d 172.18.0.2/32 -p udp -j ACCEPT
-A DOCKER-USER -s 165.1.76.226/32 -d 172.18.0.2/32 -p udp -j ACCEPT
-A DOCKER-USER -d 172.18.0.2/32 -p udp -j DROP
-A DOCKER-USER -s 127.0.0.0/8 -d 172.18.0.2/32 -p tcp -j ACCEPT
-A DOCKER-USER -s 165.1.76.226/32 -d 172.18.0.2/32 -p tcp -j ACCEPT
-A DOCKER-USER -d 172.18.0.2/32 -p tcp -j DROP
-A DOCKER-USER -d 172.19.0.2/32 -m state --state RELATED,ESTABLISHED -j ACCEPT
-A DOCKER-USER -s 127.0.0.0/8 -d 172.19.0.2/32 -p udp -j ACCEPT
-A DOCKER-USER -s 165.1.76.226/32 -d 172.19.0.2/32 -p udp -j ACCEPT
-A DOCKER-USER -d 172.19.0.2/32 -p udp -j DROP
-A DOCKER-USER -s 127.0.0.0/8 -d 172.19.0.2/32 -p tcp -j ACCEPT
-A DOCKER-USER -s 165.1.76.226/32 -d 172.19.0.2/32 -p tcp -j ACCEPT
-A DOCKER-USER -d 172.19.0.2/32 -p tcp -j DROP
-A DOCKER-USER -d 172.20.0.2/32 -m state --state RELATED,ESTABLISHED -j ACCEPT
-A DOCKER-USER -s 127.0.0.0/8 -d 172.20.0.2/32 -p udp -j ACCEPT
-A DOCKER-USER -s 165.1.76.226/32 -d 172.20.0.2/32 -p udp -j ACCEPT
-A DOCKER-USER -d 172.20.0.2/32 -p udp -j DROP
-A DOCKER-USER -s 127.0.0.0/8 -d 172.20.0.2/32 -p tcp -j ACCEPT
-A DOCKER-USER -s 165.1.76.226/32 -d 172.20.0.2/32 -p tcp -j ACCEPT
-A DOCKER-USER -d 172.20.0.2/32 -p tcp -j DROP
── 6. Firewalld 放行端口 ──
(未安装 firewalld)
