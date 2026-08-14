# 多用户每日预算池

入口：`Endpoint & Key` → `Daily Budget Pool` → `Manage allocation`。

1. 在 `Total budget` 填每天允许的总成本。
2. 在 `Reserve` 填不分配给用户的冗余额度。
3. 勾选需要分配的 API Key。
4. 点击 `Equal split` 一键均分；也可以直接修改每个 Key 右侧的金额，自由分配。
5. 确认 `Assigned` 没有超过 `Available`，然后点击 `Save allocation`。

例如总预算 `$100`、预留 `$5`，可分配额度就是 `$95`。20 个用户均分时，每人每天 `$4.75`。

限额按亚洲/上海时区每天零点重置。达到限额后，新请求会返回 HTTP 429。这里使用的是模型定价和 token 用量计算出的估算成本；没有配置价格的模型无法准确计费，流式请求也可能在完成当前一次调用时轻微超额，所以建议保留少量冗余。
