# 不买服务器：GitHub Issues 信箱模式

这个模式不用阿里云、不用域名、不用公网服务器。GitHub 私有仓库充当任务信箱：

- iPhone/Watch 写入 GitHub issue 或 comment，可以用 CodexRemote app，也可以用 GitHub Mobile/Shortcuts。
- 家里 Mac 轮询这个 private repo。
- 家里 Mac 把任务转给本机 Codex。
- Codex 完成后，家里 Mac 评论回同一个 issue。
- 通知借 GitHub Mobile 的 push 或邮件。

它比公网 Relay 便宜省心，但不是实时服务器：通常会有几秒到几十秒延迟；自家 CodexRemote app 的 APNs 通知也不会在这个模式里使用。

## 准备 GitHub

1. 新建一个 private repo，例如 `codex-remote`。不要用 public repo 放真实任务内容。
2. 在 repo 里建一个 label：`codex-remote`。
3. 再建一个完成 label：`codex-done`。连接器会在 Codex 完成后给 issue 加这个 label。
4. 创建 fine-grained personal access token，只给这个 repo 的 Issues 读写权限。
5. 推荐用第二个 GitHub 小号或 bot 账号创建 token，并把它加为 private repo collaborator。这样 bot 评论完成结果时，GitHub Mobile 更容易给你的主账号发通知；如果用主账号自己的 token 评论/mention/assign 自己，通知可能不会稳定弹出。

GitHub 官方文档：

- Issues REST API: https://docs.github.com/en/rest/issues/issues
- Issue Comments REST API: https://docs.github.com/en/rest/issues/comments
- Fine-grained tokens: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens

## 家里 Mac 配置

创建配置文件：

```bash
cp outputs/home-mac-bridge/home-mac.env.example ~/.codex-remote-home-mac.env
nano ~/.codex-remote-home-mac.env
```

GitHub 模式最少需要：

```bash
CODEX_REMOTE_BACKEND=github
GITHUB_OWNER=你的用户名或组织名
GITHUB_REPO=codex-remote
GITHUB_TASK_LABEL=codex-remote
GITHUB_DONE_LABEL=codex-done
GITHUB_NOTIFY_USERNAME=你的主账号用户名
GITHUB_NOTIFY_ASSIGNEES=你的主账号用户名
```

如果家里 Mac 已经安装并登录 GitHub CLI，可以不写 `GITHUB_TOKEN`，连接器会临时调用 `gh auth token`。如果你不用 GitHub CLI，再写：

```bash
GITHUB_TOKEN=github_pat_你的token
```

连接器默认拒绝 public repo，避免任务内容泄露。只有你明确接受公开任务内容时，才设置：

```bash
GITHUB_ALLOW_PUBLIC_REPO=1
```

先做一次预检：

```bash
CODEX_REMOTE_ENV_FILE=~/.codex-remote-home-mac.env \
  outputs/home-mac-bridge/doctor-github-inbox.sh
```

它会检查 GitHub 登录/token、repo 是否 private、Issues 是否开启、`codex-remote` 和 `codex-done` label 是否存在、通知 assignee 是否存在，以及这台 Mac 上能否找到 Codex Desktop CLI。缺 label 时可以让它创建：

```bash
CODEX_REMOTE_ENV_FILE=~/.codex-remote-home-mac.env \
  outputs/home-mac-bridge/doctor-github-inbox.sh --create-label
```

手动试跑：

```bash
set -a
source ~/.codex-remote-home-mac.env
set +a
outputs/home-mac-bridge/start-home-mac-github.sh
```

真实端到端验证：

```bash
CODEX_REMOTE_ENV_FILE=~/.codex-remote-home-mac.env \
  outputs/smoke-github-inbox-real.sh
```

这个脚本会创建一个临时 label 和测试 issue，只让临时连接器处理这一个测试任务；等 Codex 完成评论后自动关闭测试 issue 并删除临时 label。

通知可靠性验证：

1. iPhone 上安装 GitHub Mobile，登录你的主账号。
2. 在 GitHub Mobile 里确认这个 private repo 的通知没有被静音。
3. 家里 Mac 的 token 最好来自 bot/小号，`GITHUB_NOTIFY_USERNAME` 和 `GITHUB_NOTIFY_ASSIGNEES` 填你的主账号。
4. 如果设置了 `GITHUB_NOTIFY_ASSIGNEES`，主账号必须是这个 private repo 的 collaborator，否则 GitHub 不允许把完成 issue assign 给主账号。
5. 锁屏 iPhone 或戴上 Watch，运行上面的真实端到端验证。
6. 看到 GitHub Mobile 的完成评论/mention/assign 通知后，这条无服务器通知链路才算真的打通。

如果 `doctor` 提示 token actor 和 notify target 是同一个账号，任务执行仍然可用，但“离家及时收到完成通知”不够可靠；换成 bot/小号 token 后再测一次。

总诊断：

```bash
CODEX_REMOTE_ENV_FILE=~/.codex-remote-home-mac.env \
  outputs/doctor-remote-office.sh
```

离家前硬验收：

```bash
CODEX_REMOTE_ENV_FILE=~/.codex-remote-home-mac.env \
  outputs/doctor-remote-office.sh --ready
```

`--ready` 会通过已安装的 Home Mac 自启服务跑真实 GitHub 端到端烟测，构建 iPhone/watchOS target，并把所有 warning 当失败。它应该没有 `WARN` 再出门；如果提示 Home Mac 服务没装或没运行，说明这台 Mac 还不会自动盯信箱；如果提示 token actor 和通知目标相同，说明手机完成通知还不够可靠。

安装开机自启：

```bash
outputs/home-mac-bridge/install-launch-agent.sh
```

看状态：

```bash
outputs/home-mac-bridge/status-launch-agent.sh
```

## iPhone 使用

### CodexRemote app

1. 打开 CodexRemote。
2. Backend 选 `GitHub`。
3. 填 `Owner`、`Repo`、`Label` 和 GitHub token。
4. `Done Label` 默认是 `codex-done`，带这个 label 的完成 issue 默认不会出现在任务列表里；打开 `Show Done` 可以回看。
5. 点 `Sync Settings to Watch`，把这套配置发到 Apple Watch。
6. `Send Task` 会创建 GitHub issue。
7. 打开 issue 后会加载最近评论，包括 Codex 的完成摘要。
8. 输入新指令，`Comment` 会追加 GitHub comment。

### GitHub Mobile

装 GitHub Mobile，登录你的主账号。

发新任务：

1. 在 private repo 里创建 issue。
2. 标题随便写，比如 `让 Codex 修改 README`。
3. 加 label：`codex-remote`。
4. issue body 写任务内容。

追加指令：

1. 打开同一个 issue。
2. 直接评论你的新指令。
3. 家里 Mac 会把评论转给同一个 Codex thread。

查看结果：

- 连接器会在 issue 里评论 `Started Codex thread ...`。
- Codex 完成后会评论完成摘要，并给 issue 加 `codex-done` label。
- CodexRemote iPhone/Watch 打开 issue 详情页时会显示最近评论，可以直接看完成摘要。
- CodexRemote iPhone/Watch 默认隐藏带 `codex-done` 的 open issue，让列表只显示待处理任务；需要回看时打开 `Show Done`。
- 在任意 issue 评论 `/codex list`，连接器会回复最近 Codex threads。

## Apple Watch 语音发任务

### CodexRemote Watch app

1. 先在 iPhone app 填好 GitHub 配置并点 `Sync Settings to Watch`。
2. 如果 Watch 还没收到，打开 iPhone app 后在 Watch 点 `Request iPhone Settings`。
3. 在 `Task` 输入框用系统语音输入。
4. `Send to Codex` 会创建 GitHub issue。
5. 打开 issue 后继续用语音输入，`Comment` 会追加 GitHub comment。

### Apple Shortcuts

可以用 Apple Shortcuts，不需要自己写 watchOS 网络代码。做一个快捷指令：

1. `Dictate Text` 或 `Ask for Input`。
2. `Get Contents of URL`。
3. URL:

```text
https://api.github.com/repos/GITHUB_OWNER/GITHUB_REPO/issues
```

4. Method: `POST`
5. Headers:

```text
Accept: application/vnd.github+json
Authorization: Bearer GITHUB_TOKEN
X-GitHub-Api-Version: 2022-11-28
Content-Type: application/json
```

6. Request body:

```json
{
  "title": "Watch Codex task",
  "body": "这里放语音转文字结果",
  "labels": ["codex-remote"]
}
```

把这个快捷指令添加到 Apple Watch，之后抬腕运行，语音转文字就会生成 GitHub issue，家里 Mac 会轮询执行。

## 命令行测试

创建任务 issue：

```bash
curl -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/issues \
  -d '{"title":"Codex test","body":"Reply exactly: GITHUB_RELAY_OK","labels":["codex-remote"]}'
```

追加指令：

```bash
curl -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/issues/ISSUE_NUMBER/comments \
  -d '{"body":"Continue with this extra instruction"}'
```

## 取舍

- 优点：不买服务器、不备案、不配 HTTPS、不暴露家里端口。
- 优点：GitHub Mobile 自带通知、评论和历史记录。
- 缺点：不是实时链路，轮询有延迟。
- 缺点：如果连接器用你自己的 token 评论，GitHub 可能不推送自己的评论；推荐 bot/小号 token + `GITHUB_NOTIFY_USERNAME` + `GITHUB_NOTIFY_ASSIGNEES`。
- 缺点：自家 CodexRemote iPhone/watchOS app 的 APNs 通知不参与这个模式；CodexRemote app 负责读写 GitHub，通知主要靠 GitHub Mobile。
