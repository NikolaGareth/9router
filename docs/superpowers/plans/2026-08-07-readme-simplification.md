# README 精简实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将中文 README 精简为约 200 行，只保留项目简介、快速开始、核心功能、部署、常用 API 和简短故障排查。

**架构：** 根目录 `README.md` 是 GitHub 默认首页，`i18n/README.zh-CN.md` 是内容相同的中文源文件。先重写根目录文档，再复制正文到中文源文件并仅调整相对资源路径，最后用脚本验证行数、链接、图片和 Markdown 结构。

**技术栈：** Markdown、HTML 图片标签、Shell 校验命令、Git。

---

## 文件结构

- 修改：`README.md` — 面向 GitHub 首页的精简中文说明，本地资源路径以仓库根目录为基准。
- 修改：`i18n/README.zh-CN.md` — 与根目录文档正文一致，本地资源路径以 `i18n/` 为基准。

### 任务 1：重写根目录 README

**文件：**
- 修改：`README.md`

- [ ] **步骤 1：记录重写前基线**

运行：

```bash
wc -l README.md
rg -n '^#{1,3} ' README.md
```

预期：README 约 1285 行，并包含已确认要删除的定价、使用案例、长篇 FAQ、提供商教程、完整模型列表和高级说明章节。

- [ ] **步骤 2：按固定结构重写 README**

正文必须按以下顺序组织：

```markdown
# 9Router - AI 编程路由器

一句话说明统一接口、多提供商路由和自动回退。

## 核心功能
- OpenAI 兼容接口
- 多提供商和多账户
- 自动回退
- 配额追踪与请求日志
- Claude Code、Codex CLI 和通用客户端兼容

## 快速开始
包含 npm 全局安装、启动、Dashboard、API Base URL 和 API Key 获取方式。

## 客户端接入
包含 Claude Code、Codex CLI 和通用 OpenAI 客户端的最少配置示例。

## 部署
包含源码启动、systemd、Docker、必要环境变量和数据目录。

## 常用 API
包含 GET /v1/models、POST /v1/chat/completions 和 Bearer 鉴权示例。

## 故障排查
包含端口监听、服务日志、401、上游不可用四类检查。

## 项目链接与许可证
包含当前 GitHub 仓库、npm、架构文档和 LICENSE。
```

约束：

- 总行数为 180～230 行，必要时可放宽但不得超过 260 行。
- 不出现真实 Key、密码、Cookie、内网地址或个人信息。
- 不出现“永久免费”“不限量”“具体价格/额度”等时效性宣传。
- 所有命令使用当前默认端口 `20128`。
- 本地图片只保留 `images/9router.png`；如果该图片不利于压缩，可直接省略。

- [ ] **步骤 3：检查章节和删除项**

运行：

```bash
rg -n '^## ' README.md
rg -ni '视频教程|定价一览|使用案例|贡献者|Star 图表|完整模型|免费无限|永久免费' README.md
```

预期：第一条只显示计划中的章节；第二条无输出。

### 任务 2：同步中文源文件

**文件：**
- 修改：`i18n/README.zh-CN.md`

- [ ] **步骤 1：复制根目录正文**

运行：

```bash
cp README.md i18n/README.zh-CN.md
```

预期：两份文件暂时完全一致。

- [ ] **步骤 2：调整中文源文件的相对路径**

仅执行以下路径映射：

```text
images/9router.png        -> ../images/9router.png
docs/ARCHITECTURE.md      -> ../docs/ARCHITECTURE.md
LICENSE                   -> ../LICENSE
```

不得修改正文、代码示例或外部 URL。

- [ ] **步骤 3：验证两份文档只存在允许的路径差异**

运行：

```bash
diff -u README.md i18n/README.zh-CN.md
```

预期：差异只包含上述本地资源路径。

### 任务 3：验证文档质量

**文件：**
- 验证：`README.md`
- 验证：`i18n/README.zh-CN.md`

- [ ] **步骤 1：验证行数**

运行：

```bash
wc -l README.md i18n/README.zh-CN.md
```

预期：每个文件 180～230 行；不得超过 260 行。

- [ ] **步骤 2：验证本地链接和图片存在**

对每份文件提取 Markdown 相对链接和 HTML `src`，以该文件所在目录为基准检查目标文件。

预期：无 `missing` 输出。

- [ ] **步骤 3：验证 Markdown 与敏感内容**

运行：

```bash
git diff --check
rg -n 'sk-[A-Za-z0-9_-]{12,}|password\s*[:=]|auth_token|172\.24\.' README.md i18n/README.zh-CN.md
```

预期：两条命令均无输出。

- [ ] **步骤 4：人工检查关键命令**

确认以下内容均存在且只出现于对应章节：

```text
npm install -g 9router
http://localhost:20128/dashboard
http://localhost:20128/v1
Authorization: Bearer <YOUR_API_KEY>
systemctl status 9router
docker run
```

- [ ] **步骤 5：提交 README 精简结果**

运行：

```bash
git add README.md i18n/README.zh-CN.md
git commit -m "docs: 精简中文 README"
```

预期：提交只包含两份 README；设计和计划文档已经在独立提交中。
