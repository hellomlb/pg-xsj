# Patroni 静默删除复制槽：一次数据迁移事故的技术拆解

> **来源**：[When Patroni Silently Deletes Your Replication Slots](https://stormatics.tech/blogs/when-patroni-silently-deletes-your-replication-slots) — semab tariq（Stormatics，2026-06-12）  
> **关键词**：Patroni、复制槽、逻辑复制、HA 切换、数据迁移  
> **风险等级**：⚠️ 高 — 静默数据丢失，PG 日志无任何记录

---

## 事故场景

**环境**：源端是 Patroni 管理的 3 节点 PG 集群，目标端是独立 PG 集群。通过**逻辑复制**做数据迁移，手动在发布端创建了 `publication` + `logical replication slot`。

**一切正常**：数据同步稳定运行，延迟很低。

**触发**：Patroni 管理的发布节点发生了一次重启（例行维护 / HA 切换）。

**结果**：逻辑复制槽消失了。目标端无法再同步数据。

**第一反应**：查 PG 日志 → 没有任何关于槽被删除的记录。

---

## 根因：Patroni 的复制槽清理逻辑

Patroni 在启动/重启 PG 时，会执行一次**复制槽一致性检查**。核心逻辑可以用一句话概括：

> **所有不被 Patroni 自身管理的复制槽，一律删除。**

伪代码还原：

```python
# Patroni 内部清理逻辑（简化）
managed_slots = get_dcs_replication_slots()  # 从 DCS 获取 Patroni 管理的槽

for slot in pg_get_all_replication_slots():
    if slot.name not in managed_slots:
        # 不被 Patroni 管理的槽 → 直接删除
        pg_drop_replication_slot(slot.name)
```

### 为什么 PG 日志里没有记录？

因为删除操作是 Patroni 通过 SQL 接口执行的 `pg_drop_replication_slot()`，不是 PG 自身的后台进程干的。PG 只在以下情况写日志相关记录：
- 流复制 WAL sender 异常断开
- `max_slot_wal_keep_size` 触发强制删除

**外部工具手动执行的管理命令，PG 不记录日志。** 这是排查时最让人抓狂的一点——你天然会去 PG 日志里找线索，但什么都没有。

---

## Patroni 这样设计的动机

从集群管理视角看，这个设计是合理甚至必要的：

| 风险 | Patroni 的考虑 |
|------|---------------|
| 未知槽阻止 WAL 清理 | 残留槽 → WAL 堆积 → 磁盘耗尽 → 集群宕机 |
| 集群完全控制 | Patroni 假设自己是复制槽的唯一管理者（流复制） |
| HA 一致性 | 故障转移后，所有节点必须对复制槽状态有一致视图 |

**问题在于**：这个假设在逻辑复制、CDC、数据迁移等场景下不成立。PG 生态越来越多样化，手动创建的槽是合理的运维操作——但 Patroni 不认这个。

---

## 修复方案

### 方案 1：`ignore_slots` 配置（Patroni 3.0+）

```yaml
# patroni.yaml
bootstrap:
  dcs:
    ignore_slots:
      - type: logical    # 忽略所有逻辑复制槽
      - name: my_cdc     # 或按名称忽略特定槽
```

加了这个配置后，Patroni 在清理时自动跳过匹配的槽。

### 方案 2：`patronictl` 显式注册

```bash
patronictl edit-config -s 'slots={mig_slot: {"type": "logical", "database": "mydb", "plugin": "pgoutput"}}'
```

把槽注册为 Patroni 管理的对象，让它"认识"这个槽。

### 方案 3：不使用 Patroni 管理逻辑复制（推荐）

对于长期运行的逻辑复制/CDC 管道，考虑：
- 使用专门的 CDC 工具（Debezium 等），它们有独立的槽管理
- 在非 Patroni 管理的独立实例上做发布端

---

## 排查清单

当 Patroni 集群上的逻辑复制突然中断时，按以下顺序排查：

| # | 检查项 | 命令/方法 |
|---|--------|----------|
| 1 | 槽是否还存在 | `SELECT * FROM pg_replication_slots;` |
| 2 | Patroni 是否重启过 | Patroni 日志 / `systemctl status patroni` |
| 3 | 检查 Patroni 配置 | `patronictl show-config` 确认 `ignore_slots` |
| 4 | DCS 中的槽列表 | `patronictl list -f json` 对比预期 |
| 5 | WAL 是否被回收 | `SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) FROM pg_replication_slots;` |

> **关键心态**：在 Patroni 集群上做逻辑复制，不要假设你手动创建的槽能"活过"下一次重启。必须显式告诉 Patroni。

---

## 与其他工具对比

| 工具 | 复制槽管理策略 | 手动槽安全性 |
|------|--------------|-------------|
| **Patroni** | 启发式清理，不认识的槽删除 | ❌ 危险 |
| **Stolon** | 通过 store 管理槽状态，不认识的不清理 | ⚠️ 不删除但不管理 |
| **pg_auto_failover** | 只管理自己的流复制槽 | ✅ 不干预用户槽 |
| **CloudNativePG (k8s)** | 声明式配置，显式定义所有槽 | ✅ 安全 |

---

## 核心教训

1. **永远显式配置**：在 Patroni 集群上创建的任何复制槽，必须在 Patroni 配置中显式声明——`ignore_slots` 或显式注册。没有"默认安全"这回事。

2. **排查时先确认 Patroni 行为**：Node 重启后逻辑复制中断，第一站不应该看 PG 日志，应该看 Patroni 日志和 DCS 状态。

3. **设计哲学冲突**：Patroni 把 HA 集群当作"封闭系统"，而逻辑复制需要"开放接口"。这两个设计哲学在槽管理上正面冲突——运维人员需要意识到这个张力。

---

> **扩展阅读**：PostgreSQL 17 引入的 `pg_replication_slot_advance()` 和逻辑复制槽故障转移支持，部分缓解了这个问题。但根本矛盾——"集群管理者对复制槽的完全控制"vs"运维人员对外部消费者的支持"——仍然需要行业达成共识的解决方案。
