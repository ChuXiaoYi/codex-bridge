# 阿里云 Relay 部署说明

阿里云国内主机可以做 Codex Remote Relay，但中国大陆地域一般需要域名完成 ICP 备案，再用 HTTPS 对外服务。没有备案时，建议优先选择阿里云香港、新加坡、日本等非中国大陆地域，部署会简单很多。

官方参考：

- 阿里云 ICP 备案流程: https://help.aliyun.com/zh/icp-filing/basic-icp-service/user-guide/icp-filing-application-overview
- 阿里云网站备案要求: https://www.alibabacloud.com/help/zh/icp-filing/basic-icp-service/product-overview/icp-filing-requirements-for-a-regular-website
- Apple APNs Provider API: https://developer.apple.com/documentation/usernotifications/establishing-a-connection-to-apns

## 推荐选择

- 有已备案域名: 可以用阿里云中国大陆 ECS 或轻量应用服务器。
- 没有备案: 推荐阿里云香港或新加坡 ECS，先把远程办公链路跑通。
- 只想试验: 可以临时用非大陆地域公网 IP 加自签/HTTP 测试命令行，但 iPhone/watchOS 真机建议最终走正式域名 HTTPS。

## 安全组

公网入站只放这些端口：

- `80/tcp`: Caddy/Certbot 首次签发或续期证书。
- `443/tcp`: iPhone、Watch、Home Mac 访问 Relay。
- `22/tcp`: SSH 管理，建议只允许你的常用 IP。

不要把 `8788/tcp` 直接开放到公网。Relay 容器只绑定在服务器本机 `127.0.0.1:8788`，由 HTTPS 反代转发。

出站需要允许：

- `443/tcp`: 访问 Apple APNs、系统包源、证书服务。

## 服务器准备

以下示例以 Ubuntu/Debian 为例：

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin caddy
sudo systemctl enable --now docker caddy
```

上传或 git clone 这个目录到服务器，例如：

```bash
mkdir -p ~/codex-remote
scp -r outputs/relay user@你的服务器:~/codex-remote/relay
```

## 配置 Relay

```bash
cd ~/codex-remote/relay
cp .env.example .env
nano .env
```

至少改这两个值：

```bash
RELAY_CLIENT_TOKEN=一串很长的随机字符串-给iPhone和Watch
RELAY_BRIDGE_TOKEN=另一串很长的随机字符串-给家里Mac
```

生成随机 token 的例子：

```bash
openssl rand -base64 48
```

如果配置 APNs，把 `.p8` 放到 `secrets/`，并在 `.env` 里设置：

```bash
APNS_KEY_DIR=./secrets
APNS_KEY_PATH=/run/secrets/codex-remote/AuthKey_ABC123DEFG.p8
APNS_KEY_ID=ABC123DEFG
APNS_TEAM_ID=YOURTEAMID
APNS_TOPIC=com.chuxiaoyi.CodexRemote
APNS_ENV=sandbox
```

## 启动 Relay

```bash
docker compose up -d --build
docker compose ps
curl http://127.0.0.1:8788/health
```

## 配置 HTTPS 域名

把域名 DNS A 记录指向服务器公网 IP。然后配置 Caddy：

```bash
sudo cp Caddyfile.example /etc/caddy/Caddyfile
sudo nano /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

把 `relay.example.com` 改成你的域名。验证：

```bash
curl https://你的域名/health
curl -H "authorization: Bearer 你的-client-token" \
  https://你的域名/threads?limit=1
```

## 家里 Mac 连接

家里 Mac 的 `~/.codex-remote-home-mac.env` 写：

```bash
RELAY_URL=https://你的域名
RELAY_BRIDGE_TOKEN=你的-bridge-token
```

然后安装开机自启：

```bash
outputs/home-mac-bridge/install-launch-agent.sh
```

## iPhone 和 Watch

iPhone 和 Watch app 填：

- Relay URL: `https://你的域名`
- Client token: `.env` 里的 `RELAY_CLIENT_TOKEN`

## 运维命令

看 Relay 日志：

```bash
docker compose logs -f
```

重启 Relay：

```bash
docker compose restart
```

更新后重建：

```bash
docker compose up -d --build
```

健康检查：

```bash
curl https://你的域名/health
```
