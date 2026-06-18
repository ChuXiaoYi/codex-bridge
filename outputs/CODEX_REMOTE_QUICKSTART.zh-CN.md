# Codex 远程办公 Quickstart

这个目录里现在有两条路线：

- 不买服务器路线：GitHub Issues 当任务信箱，适合先用起来。
- 公网 Relay 路线：自己部署 HTTPS Relay，体验更实时，也支持自家 APNs 推送。

这个目录里现在有这些东西：

- Home Mac Bridge: 家里 Mac 上运行，连接本机 Codex Desktop。
- Relay: 放在公网 HTTPS 服务器上，iPhone/Watch 和家里 Mac 都连它。
- CodexRemote App: iPhone + Apple Watch 客户端，用来发任务、追加指令、收完成通知。

## 不买服务器路线

看 `outputs/GITHUB_NO_SERVER.zh-CN.md`。

核心做法：

1. 建一个 GitHub private repo 和 `codex-remote` label。
2. 创建只允许 Issues 读写的 fine-grained token。
3. 家里 Mac 设置 `CODEX_REMOTE_BACKEND=github`、`GITHUB_TOKEN`、`GITHUB_OWNER`、`GITHUB_REPO`。
4. 先跑 `outputs/home-mac-bridge/doctor-github-inbox.sh` 预检，确认 repo 是 private、Issues 和 label 都可用。
5. 用 `outputs/home-mac-bridge/install-launch-agent.sh` 开机自启。
6. iPhone 上在 CodexRemote 里选择 GitHub backend，填 owner/repo/label/token 后点 `Sync Settings to Watch`。
7. Watch app 可以直接收 iPhone 同步的配置；没收到时点 `Request iPhone Settings`，然后用系统语音输入发任务。
8. 也可以不用自家 app，直接用 GitHub Mobile/Shortcuts。

这个模式不需要买服务器，但系统通知靠 GitHub Mobile，不是自家 APNs。

## 本地试跑

开一个本地 Relay：

```bash
RELAY_CLIENT_TOKEN=client-dev \
RELAY_BRIDGE_TOKEN=bridge-dev \
outputs/relay/start-relay.sh
```

再开家里 Mac 连接器：

```bash
RELAY_URL=http://127.0.0.1:8788 \
RELAY_BRIDGE_TOKEN=bridge-dev \
outputs/home-mac-bridge/start-home-mac.sh
```

测试手机侧 API：

```bash
curl -H 'authorization: Bearer client-dev' \
  'http://127.0.0.1:8788/threads?limit=5'
```

## 真正远程使用

### 公网 Relay 路线

1. 把 Relay 部署到一个公网 HTTPS 主机。没有外网主机时，可以用阿里云；中国大陆地域通常需要域名 ICP 备案，没有备案建议优先用阿里云香港/新加坡。详细步骤见 `outputs/relay/ALIYUN_DEPLOY.zh-CN.md`。
2. Relay 设置 `RELAY_CLIENT_TOKEN` 和 `RELAY_BRIDGE_TOKEN`，两个值都换成足够长的随机字符串。
3. 如果要系统推送通知，Relay 还需要 `APNS_KEY_PATH`、`APNS_KEY_ID`、`APNS_TEAM_ID`、`APNS_TOPIC`、`APNS_ENV`。
4. 家里 Mac 先创建配置：

```bash
cp outputs/home-mac-bridge/home-mac.env.example ~/.codex-remote-home-mac.env
nano ~/.codex-remote-home-mac.env
```

把里面的 `RELAY_URL` 和 `RELAY_BRIDGE_TOKEN` 改成真实值。然后安装开机自启：

```bash
outputs/home-mac-bridge/install-launch-agent.sh
```

5. 用 Xcode 打开 `outputs/apps/CodexRemote/CodexRemote.xcodeproj`，配置你的 Apple Developer Team 和 Bundle ID，真机运行 iPhone app 和 Watch app。
6. iPhone app 里填 Relay URL 和 Client token，点 `Enable Completion Alerts`，再点 `Connect Events`。
7. Watch app 里填同一个 Relay URL 和 Client token，可以刷新线程、打开线程追加指令，也可以用系统输入框语音转文字后点 `Send to Codex` 发新任务。

## 验证清单

- iPhone `Refresh` 能看到家里 Mac 上的 Codex threads。
- iPhone `Send Task` 能创建新 Codex 任务。
- iPhone thread 详情页 `Send / Steer` 能对空闲线程续跑，对活跃线程追加指令。
- Watch 能刷新线程列表、打开线程详情并追加指令。
- Watch 语音输入后能发送新任务或给已有线程追加指令。
- iPhone `Sync Settings to Watch` 后，Watch 不需要手输 owner/repo/token 就能使用同一套 GitHub 或 Relay 配置。
- Codex 完成时，Relay `/events` 里出现 `notification_ready` 或 `notification_sent`。
- 配好 APNs 并用真机签名安装后，iPhone/Watch 能收到系统完成通知。
- 家里 Mac 重启或重新登录后，`outputs/home-mac-bridge/status-launch-agent.sh` 显示服务已加载。

## 当前边界

- 本机已经验证了 Bridge、Relay、命令转发、事件转发、通知事件、iPhone build、watchOS build。
- 真正 APNs 推送必须使用你的 Apple Developer Team、APNs key、真机和匹配 Bundle ID 才能验证。
- Relay 当前使用内存队列，适合个人原型；长期公网运行建议加持久化、限流和日志轮转。
- Codex 审批请求、手动输入请求会作为事件出现，但还没有做成手机上的交互式审批。

## 常用命令

看家里 Mac 服务状态：

```bash
outputs/home-mac-bridge/status-launch-agent.sh
```

卸载家里 Mac 开机自启：

```bash
outputs/home-mac-bridge/uninstall-launch-agent.sh
```

本地端到端烟测：

```bash
outputs/smoke-local-end-to-end.sh
```
