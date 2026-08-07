# 9Router 云主机直接更新设计

## 目标

在云主机上直接运行 9Router，并通过手动执行一条命令，将生产服务更新到 GitHub `master` 分支的最新版本。更新过程不采用 Docker，不长期保留历史版本，业务中断控制在数秒内。

## 部署布局

- 正式目录：`/opt/9router`
- 临时构建目录：`/opt/9router-build`
- 持久化数据：`/root/.9router`
- systemd 服务：`9router.service`
- 手动更新命令：`sudo 9router-update`
- 代码来源：`https://github.com/NikolaGareth/9router.git` 的 `master`

持久化数据目录独立于代码目录，代码替换不得删除、覆盖或迁移 `/root/.9router`。

## 更新流程

1. 确认没有另一个更新进程正在运行。
2. 清理上次失败遗留的临时构建目录。
3. 将远端 `master` 的最新代码浅克隆到临时构建目录。
4. 使用项目锁文件执行 `npm ci`，随后执行 `npm run build`。
5. 构建成功后停止 `9router.service`。
6. 将构建完成的目录替换为 `/opt/9router`。
7. 启动 `9router.service`，等待本机 HTTP 健康检查通过。
8. 输出部署的 Git commit 和服务状态，清理临时文件。

依赖安装或构建失败发生在停服之前，因此不会影响当前运行实例。正式目录替换和服务重启期间允许约 2～5 秒中断。

## 运行方式

更新脚本按仓库 `Dockerfile` 的生产布局组装 `.runtime` 目录：以 Next.js standalone 产物为主体，并补齐 `custom-server.js`、`open-sse`、MITM 文件及生产运行所需模块。systemd 使用固定的 Node.js 绝对路径启动仓库的生产入口：

```text
/opt/node-v24.15.0-npm/node/bin/node /opt/9router/.runtime/custom-server.js
```

服务监听 `0.0.0.0:80`，工作目录为 `/opt/9router/.runtime`，失败时自动重启。环境变量由 systemd 配置提供，不写入 Git 仓库。该入口与仓库 `Dockerfile` 的 `CMD ["node", "custom-server.js"]` 保持一致，避免绕过自定义服务器中的真实客户端 IP 处理与后台令牌刷新逻辑。

## 失败处理

- 拉取、依赖安装或构建失败：终止更新，原服务继续运行。
- 停服后的目录替换失败：报告明确错误并停止，不删除持久化数据。
- 新服务启动或健康检查失败：保留日志并将命令返回为失败。由于需求明确不保留旧版本，本方案不自动回滚。
- 使用文件锁防止两个更新命令并发执行。

## 验证标准

- `systemctl is-active 9router` 返回 `active`。
- `curl http://127.0.0.1/dashboard` 返回可接受的成功或登录重定向响应。
- `/opt/9router` 的 Git commit 与远端 `master` 最新 commit 一致。
- `/root/.9router` 在更新前后保持存在，数据库与配置未被代码替换流程修改。
- 更新脚本退出码能准确反映成功或失败。

## 范围外事项

- Docker 或 Docker Compose 部署。
- 蓝绿部署、双实例或零停机切换。
- 定时自动更新。
- 长期保留旧版本及自动回滚。
