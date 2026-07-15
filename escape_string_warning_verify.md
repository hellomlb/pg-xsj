# escape_string_warning 跨版本实测验证

> 背景：Christophe Pettus 7/14 文章《All Your GUCs in a Row: escape_string_warning》。
> 老木要求：在 **PG 16 和 PG 19** 上实测该 GUC 的真实行为。
> 实测原则：不猜、拿数据说话。以下均为真实 SQL 执行输出。

## 结论速览

| 维度 | 结论 |
|------|------|
| GUC 默认值 | `on`（**16.11 + 18.4 双版本实测确认**；19 待补） |
| `standard_conforming_strings` 默认值 | `on`（16.11 + 18.4 双版本实测确认） |
| 触发 WARNING 的唯一条件 | `standard_conforming_strings = off` **且** 普通字符串字面量 `'...'` 中含反斜杠 `\` |
| 不触发的情况 | ① GUC 设为 `off`；② `standard_conforming_strings = on`（默认，此时 `\` 就是普通字符）；③ `E'...'` 显式转义串（明确声明，不报） |
| 安全意义 | SQL 注入防护 / 标准字符串兼容性的「哨兵」：应用若悄悄依赖非标准字符串转义（`standard_conforming_strings=off`），这个警告就是第一道警报 |
| 跨版本一致性 | **16.11 与 18.4 行为逐字节一致**（该 GUC 自 PG 8.1 起语义稳定，默认始终为 on） |

## PG 18.4 实测（本机 10180）✅

```text
PostgreSQL 18.4 on aarch64-apple-darwin25.5.0

--- 1) 默认值 ---
escape_string_warning    | on
standard_conforming_strings | on

--- 2) scs=off + 字面量含 \ + GUC=on => WARNING ---
WARNING:  nonstandard use of escape in a string literal
HINT:  Use the escape string syntax for escapes, e.g., E'\r\n'.
结果: a\x08        （\b 被当作退格转义符 0x08）

--- 3) 同场景但 GUC=off => 不警告 ---
结果: a\x08

--- 4) scs=on(默认) + 字面量含 \ => 不警告（\ 是普通字符）---
结果: a\b          （\b 原样保留，不做转义）

--- 5) E'...' 显式转义串 即使 scs=off 也不触发该警告 ---
结果: a\x08        （E 串里 \b 是合法转义，明确声明所以不报 warning）
```

## PG 16.11 实测（本机源码编译，`--prefix=/tmp/pg-install`，端口 11611）✅

```text
PostgreSQL 16.11 on aarch64-apple-darwin24.5.0

--- 1) 默认值 ---
escape_string_warning    | on
standard_conforming_strings | on

--- 2) scs=off + 字面量含 \ + GUC=on => WARNING ---
WARNING:  nonstandard use of escape in a string literal
HINT:  Use the escape string syntax for escapes, e.g., E'\r\n'.
结果: a\x08        （\b 被当作退格转义符 0x08）

--- 3) 同场景但 GUC=off => 不警告 ---
结果: a\x08

--- 4) scs=on(默认) + 字面量含 \ => 不警告（\ 是普通字符）---
结果: a\b          （\b 原样保留，不做转义）

--- 5) E'...' 显式转义串 即使 scs=off 也不触发该警告 ---
结果: a\x08        （E 串里 \b 是合法转义，明确声明所以不报 warning）
```

**白话解读**：这个 GUC 只在「字符串被当成「可能含转义」来解析、但写法又是模糊的普通引号」时才报警。它是给「从老版本（scs=off）迁移上来的应用」看的——这类应用里 `'O\'Brien'` 这种写法依赖 `\` 转义，一旦换成标准模式 `\` 就失效，warning 提前暴露隐患。巡检侧可把它做成「非标准字符串转义」检查项。

## PG 19beta1 实测 ❌ 当前环境不可用

- 本机源码目录（`/Users/menglb/Documents/PG源码/`）仅有 `postgresql-16.11 / 16.14 / 18.4`，**无 19beta1 源码**。
- 记忆中 `10190` 这个 19beta1 实例应位于远程 VM（gj-pgdb-02），当前所有外部连接均断开、不可达。
- **因此 19 这一项无法按老木要求完成实测**。需要老木提供 19beta1 的源码或可达实例后才能补验。

## 待补

- [x] PG 18.4 实测输出
- [x] PG 16.11 实测输出（本机源码编译 + initdb + 11611 启动，双版本语义一致已证实）
- [ ] PG 19beta1 实测（待老木提供资源）
