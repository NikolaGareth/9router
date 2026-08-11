# 任务 4 报告：README 云主机直接部署说明

状态：DONE

## 修改

- 在 `README.md` 新增「Ubuntu 直接部署」小节。
- 说明首次部署前置条件、临时管理目录克隆方式与 `sudo bash deploy/linux/install.sh`。
- 补充 `sudo 9router-update`、状态、健康检查和日志命令。
- 将失败处理与当前脚本一致：按输出的 `/run/9router-install-recover` 或 `/run/9router-install-cleanup` 执行；明确 `/run` 材料必须在重启前处理，未保留旧版手工 `rm`/`mv` 恢复命令。

## 验证

- `git diff --check`：通过。
- `rg -n 'Ubuntu 直接部署|sudo bash deploy/linux/install\\.sh|sudo 9router-update|/opt/9router|journalctl -u 9router|/run/9router-install-(recover|cleanup)' README.md`：通过。
- `bash deploy/linux/test-9router-update.sh`：通过（退出码 0）。

## 提交

`1055a3e4 docs: 补充云主机直接部署与更新说明`

## 疑虑

无。

## 审查修正

- 提交 `94c9be73 docs: 明确恢复脚本需要 root 执行`：README 明确恢复或首次收尾时须以安装器实际输出路径为准，并用 `sudo <输出的/run 脚本路径>` 执行；示例仅使用当前实现的 `/run/9router-install-recover`。
- 复验：`git diff --check`、README 恢复命令 `rg` 断言、`bash deploy/linux/test-9router-update.sh` 均通过。

## 2026-08-11 认证边界补充

密码登录在未持久化密码且未配置 `INITIAL_PASSWORD` 时，对非 loopback 请求在签发 cookie 之前返回 503；首次部署随机密码只落 root-only 外部环境文件，终端不显示秘密。目标路由 ESLint 通过。
