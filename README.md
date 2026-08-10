<div align="center">
  <img src="images/9router.png" alt="9Router Dashboard" width="800" />

# 9Router - AI 编程路由器

通过一个 OpenAI 兼容端点连接多个 AI 提供商，并在账户、模型或配额不可用时自动回退。

[![npm](https://img.shields.io/npm/v/9router.svg)](https://www.npmjs.com/package/9router)
[![Downloads](https://img.shields.io/npm/dm/9router.svg)](https://www.npmjs.com/package/9router)
[![License](https://img.shields.io/npm/l/9router.svg)](LICENSE)

[快速开始](#快速开始) · [客户端接入](#客户端接入) · [部署](#部署) · [常用-api](#常用-api) · [故障排查](#故障排查)
</div>

## 核心功能

- **统一接口**：提供 OpenAI 兼容的 `/v1` API。
- **多提供商路由**：统一管理 OAuth、订阅账户和 API Key 提供商。
- **自动回退**：上游报错、限流或配额不足时切换到下一可用连接。
- **多账户管理**：同一提供商可添加多个账户并设置优先级。
- **配额与用量**：查看 Session 配额、Token 用量、请求日志和预估成本。
- **格式转换**：在 OpenAI、Anthropic、Gemini 等请求格式之间转换。
- **客户端兼容**：可供 Claude Code、Codex CLI、Cursor、Cline 等工具使用。

## 快速开始

### 安装与启动

需要 Node.js 20 或更高版本。

```bash
npm install -g 9router
9router
```

无浏览器服务器可使用：

```bash
9router --host 0.0.0.0 --port 20128 --no-browser
```

启动后访问：

- Dashboard：`http://localhost:20128/dashboard`
- API Base URL：`http://localhost:20128/v1`

1. 打开 Dashboard，在“提供商”中连接至少一个账户。
2. 在“端点与密钥”中创建 9Router API Key。
3. 在客户端中填写 API Base URL、API Key 和模型名称。

查看当前可用模型：

```bash
curl http://localhost:20128/v1/models \
  -H "Authorization: Bearer <YOUR_API_KEY>"
```

## 客户端接入

### Claude Code

设置 Anthropic 兼容地址和 9Router Key：

```bash
export ANTHROPIC_BASE_URL="http://localhost:20128/v1"
export ANTHROPIC_AUTH_TOKEN="<YOUR_API_KEY>"
claude
```

### Codex CLI

```bash
export OPENAI_BASE_URL="http://localhost:20128/v1"
export OPENAI_API_KEY="<YOUR_API_KEY>"
codex
```

### OpenAI 兼容客户端

```text
Provider: OpenAI Compatible
Base URL: http://localhost:20128/v1
API Key: <YOUR_API_KEY>
Model: 从 GET /v1/models 返回结果中选择
```

Cursor、Cline、Continue、Roo Code 等客户端均可使用此配置。

## 部署

### Ubuntu 直接部署

适用于直接管理云主机的场景。部署脚本会安装 systemd 服务和 `9router-update`，服务监听 `80` 端口，数据持久化在 `/root/.9router`。

前置条件：Ubuntu、Git、curl、flock，以及固定 Node.js 路径 `/opt/node-v24.15.0-npm/node/bin/node` 已存在；`80` 端口不能被其他程序占用。

先将仓库克隆到临时管理目录，再从仓库根目录执行首次安装：

```bash
git clone https://github.com/NikolaGareth/9router.git /tmp/9router-admin
cd /tmp/9router-admin
sudo bash deploy/linux/install.sh
```

日常更新直接执行：

```bash
sudo 9router-update
systemctl status 9router --no-pager
curl -I http://127.0.0.1/dashboard
journalctl -u 9router -n 100 --no-pager
```

`9router-update` 仅在成功退出后才会删除上一个临时部署目录 `/opt/9router.previous`。更新失败时会保留切换现场，不会输出可脱离锁执行的 `rm` 或 `mv` 恢复命令。

若脚本输出「人工联合恢复：`/run/9router-install-recover`」，请在确认现场后按该路径执行脚本；若输出「首次安装安全收尾：`/run/9router-install-cleanup`」，同样按输出路径执行收尾脚本。两类脚本都会校验锁和现场，不能用旧版手工恢复命令替代。相关恢复材料位于 `/run`，重启后会丢失；必须在重启前处理或保留现场并人工核对。

### systemd

先确认全局命令的绝对路径：

```bash
command -v 9router
command -v node
```

创建 `/etc/systemd/system/9router.service`，将 `ExecStart` 中的路径替换为上面命令的实际结果：

```ini
[Unit]
Description=9Router Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=NODE_ENV=production
Environment=DATA_DIR=/var/lib/9router
ExecStart=/absolute/path/to/node /absolute/path/to/9router --host 0.0.0.0 --port 20128 --no-browser
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

启用并检查服务：

```bash
sudo mkdir -p /var/lib/9router
sudo systemctl daemon-reload
sudo systemctl enable --now 9router
systemctl status 9router --no-pager
journalctl -u 9router -f
```

### Docker Compose

准备环境变量：

```bash
cp .env.example .env
```

至少修改以下值：

```dotenv
JWT_SECRET=replace-with-a-long-random-value
INITIAL_PASSWORD=replace-with-a-strong-password
API_KEY_SECRET=replace-with-an-api-key-secret
MACHINE_ID_SALT=replace-with-a-random-salt
DATA_DIR=/var/lib/9router
PORT=20128
BASE_URL=http://localhost:20128
NEXT_PUBLIC_BASE_URL=http://localhost:20128
```

启动：

```bash
docker compose up -d
docker compose ps
docker compose logs -f 9router
```

### 常用环境变量

部署时至少设置 `PORT`、`HOSTNAME`、`DATA_DIR`、`INITIAL_PASSWORD`、`JWT_SECRET`、`API_KEY_SECRET`、`MACHINE_ID_SALT`、`BASE_URL` 和 `NEXT_PUBLIC_BASE_URL`。如需上游代理，可设置 `HTTP_PROXY` 与 `HTTPS_PROXY`。完整说明见 [.env.example](.env.example)。

## 常用 API

```http
Authorization: Bearer <YOUR_API_KEY>
```

### 列出模型

```bash
curl http://localhost:20128/v1/models \
  -H "Authorization: Bearer <YOUR_API_KEY>"
```

### Chat Completions

```bash
curl http://localhost:20128/v1/chat/completions \
  -H "Authorization: Bearer <YOUR_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "provider/model-name",
    "messages": [
      {"role": "user", "content": "你好"}
    ],
    "stream": false
  }'
```

支持流式响应；将 `stream` 改为 `true` 即可。

## 故障排查

### 无法访问服务

```bash
systemctl status 9router --no-pager
ss -lntp | grep 20128
curl -I http://127.0.0.1:20128/dashboard
```

确认启动参数包含 `--host 0.0.0.0`，并检查服务器防火墙或安全组。

### 返回 401

- 确认使用的是 Dashboard 生成的有效 Key。
- 请求头格式必须是 `Authorization: Bearer <YOUR_API_KEY>`。
- 检查该 Key 是否已被停用。

### 上游模型不可用

- 在 Dashboard 检查提供商连接状态和剩余配额。
- 调用 `/v1/models` 确认模型名称存在。
- 查看服务日志中的鉴权、限流或网络错误。

```bash
journalctl -u 9router -n 200 --no-pager
docker compose logs --tail=200 9router
```

## 项目链接与许可证

- GitHub：[NikolaGareth/9router](https://github.com/NikolaGareth/9router)
- npm：[9router](https://www.npmjs.com/package/9router)
- 架构说明：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

本项目采用 MIT License，详见 [LICENSE](LICENSE)。
