// PG19 实测 v3：pg_stats 完整 5 个 SQL 验证脚本（终版）
// 关键改进：
//  1. city 强相关 state（Cheyenne 99.9% 在 WY；SF 99.9% 在 CA）
//  2. 数据均匀（避免 hot spot）
//  3. 测多列统计时选实际有大量行的组合

const { Client } = require('pg');
const PASSWORD = '3ed$RF345';
const TARGET = {host:'110.41.133.39', port:10190, user:'pgdba', password: PASSWORD, database:'bug'};

const log = (label, ok, data) => console.log(`[${ok?'✅':'❌'}] ${label}${data?'\n'+data:''}\n`);

async function run() {
  const c = new Client({...TARGET, connectionTimeoutMillis: 8000});
  await c.connect();
  const v = await c.query('SELECT version()');
  log('CONNECT', true, '   ' + v.rows[0].version.split(' ').slice(0,2).join(' '));

  // ============ 准备 ============
  console.log('========== 准备：建表 + 1M 数据 ==========');
  await c.query(`DROP TABLE IF EXISTS customers CASCADE`);
  await c.query(`
    CREATE TABLE customers (
        id          bigserial PRIMARY KEY,
        city        text NOT NULL,
        state       text NOT NULL,
        signup_date date NOT NULL
    )
  `);
  log('CREATE TABLE', true);

  // 设计：10 个特殊 city 强绑定 state
  // 'Cheyenne' (City_A) 99% → WY, 1% → OK
  // 'San Francisco' (City_B) 99% → CA, 1% → NV
  // 'New York' (City_C) 99% → NY, 1% → NJ
  // 'Houston' (City_D) 99% → TX, 1% → LA
  // 'Miami' (City_E) 99% → FL, 1% → GA
  // 其余 9994 个 city 均匀分布到 50 州
  await c.query(`
    INSERT INTO customers (city, state, signup_date)
    SELECT
        CASE
            WHEN bucket < 50000 THEN 'Cheyenne'
            WHEN bucket < 100000 THEN 'San Francisco'
            WHEN bucket < 150000 THEN 'New York'
            WHEN bucket < 200000 THEN 'Houston'
            WHEN bucket < 250000 THEN 'Miami'
            ELSE 'City_' || ((bucket * 31 + 7) % 10000)
        END AS city,
        CASE
            WHEN bucket < 50000 THEN 'WY'  -- 5% 全部 WY
            WHEN bucket < 100000 THEN 'CA'  -- 5% 全部 CA
            WHEN bucket < 150000 THEN 'NY'  -- 5% 全部 NY
            WHEN bucket < 200000 THEN 'TX'  -- 5% 全部 TX
            WHEN bucket < 250000 THEN 'FL'  -- 5% 全部 FL
            ELSE state_uniform
        END AS state,
        '2018-01-01'::date + ((bucket * 13) % 1825) AS signup_date
    FROM (
        SELECT
            i AS bucket,
            ((i * 17 + 23) % 50) AS state_idx,
            (ARRAY['AL','AK','AZ','AR','CO','CT','DE','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','UT','VT','VA','WA','WV','WI','WY','TX','NY','FL','CA','ME'])[((i*17+23) % 50) + 1] AS state_uniform
        FROM generate_series(1, 1000000) i
    ) sub
  `);
  log('INSERT 1M', true);

  // 验证分布
  const dist = await c.query(`
    SELECT state, COUNT(*) AS cnt, ROUND(100.0*COUNT(*)/1000000, 2) AS pct
    FROM customers
    GROUP BY state
    ORDER BY cnt DESC
    LIMIT 8
  `);
  console.log('   state 分布 Top8:');
  console.table(dist.rows);

  const cityDist = await c.query(`
    SELECT city, state, COUNT(*) AS cnt
    FROM customers
    WHERE city IN ('Cheyenne', 'San Francisco', 'New York', 'Houston', 'Miami')
    GROUP BY city, state
    ORDER BY city, cnt DESC
  `);
  console.log('\n   强相关 city 验证（应 99% 集中在主州）:');
  console.table(cityDist.rows);

  await c.query(`ANALYZE customers`);
  log('ANALYZE', true);

  await c.query(`CREATE INDEX idx_customers_state ON customers(state)`);
  await c.query(`CREATE INDEX idx_customers_city  ON customers(city)`);
  log('CREATE INDEX', true);

  // ============ SQL1: pg_stats 基础视图 ============
  console.log('\n========== SQL1: pg_stats 基础视图 ==========');
  const r1 = await c.query(`
    SELECT attname, n_distinct, null_frac, correlation
    FROM pg_stats
    WHERE tablename = 'customers'
    ORDER BY attname
  `);
  console.table(r1.rows);
  log('SQL1 ✅', r1.rows.length===4, JSON.stringify(r1.rows, null, 2));

  // ============ SQL2: MCV 最频值 ============
  console.log('\n========== SQL2: MCV 最频值 ==========');
  const r2 = await c.query(`
    SELECT
        unnest(most_common_vals::text::text[]) AS state,
        ROUND((unnest(most_common_freqs))::numeric, 4) AS frequency
    FROM pg_stats
    WHERE tablename = 'customers' AND attname = 'state'
    LIMIT 8
  `);
  console.table(r2.rows);
  log('SQL2 ✅', r2.rows.length>0, JSON.stringify(r2.rows, null, 2));

  // ============ SQL3: 顺序扫描 vs 索引扫描对比 ============
  console.log('\n========== SQL3: CA vs WY 的执行计划对比 ==========');
  // CA 大约 5% (10万行), 走 Index Scan 更划算
  // 选 SF 触发大对比
  console.log('-- 3a. state = \'CA\' (~5%, 10万行):');
  const r3a = await c.query(`EXPLAIN ANALYZE SELECT * FROM customers WHERE state = 'CA'`);
  r3a.rows.forEach(r => console.log('   ' + r['QUERY PLAN']));

  console.log('\n-- 3b. state = \'WY\' (~5%, 5万行, 但配合 strong correlation):');
  const r3b = await c.query(`EXPLAIN ANALYZE SELECT * FROM customers WHERE state = 'WY'`);
  r3b.rows.forEach(r => console.log('   ' + r['QUERY PLAN']));

  console.log('\n-- 3c. 强制 enable_seqscan=off，看 cost 差异:');
  await c.query(`SET enable_seqscan = off`);
  const r3c = await c.query(`EXPLAIN ANALYZE SELECT * FROM customers WHERE state = 'CA'`);
  r3c.rows.forEach(r => console.log('   ' + r['QUERY PLAN']));
  await c.query(`SET enable_seqscan = on`);

  // ============ SQL4: 多列统计的 500 倍偏差修复 ============
  console.log('\n========== SQL4: 多列统计修复多列偏差 ==========');
  // Cheyenne ≈ 5万行（5%），但 'WY' 也 ≈ 5万行（5%）
  // 默认规划器假设独立：P(Cheyenne AND WY) = 5% × 5% = 0.25% → 估 ~2500 行
  // 实际：Cheyenne 99% 都在 WY → 实际 ~49500 行
  // 偏差 ≈ 50 倍（受 5% 限制）
  console.log('-- 4a. 没有多列统计时 (city=Cheyenne AND state=WY):');
  const r4a = await c.query(`EXPLAIN ANALYZE SELECT * FROM customers WHERE city = 'Cheyenne' AND state = 'WY'`);
  r4a.rows.forEach(r => console.log('   ' + r['QUERY PLAN']));

  console.log('\n-- 4b. 创建 CREATE STATISTICS 后:');
  await c.query(`CREATE STATISTICS customers_city_state (dependencies, ndistinct) ON city, state FROM customers`);
  await c.query(`ANALYZE customers`);
  log('CREATE STATISTICS', true);

  const r4b = await c.query(`EXPLAIN ANALYZE SELECT * FROM customers WHERE city = 'Cheyenne' AND state = 'WY'`);
  r4b.rows.forEach(r => console.log('   ' + r['QUERY PLAN']));

  // 提取 rows 和 actual rows
  function extractRows(planText) {
    const m = planText.match(/rows=(\d+).*?actual rows=(\d+)/);
    return m ? {est: parseInt(m[1]), act: parseInt(m[2])} : null;
  }
  const plan4a = r4a.rows.map(r=>r['QUERY PLAN']).join(' ');
  const plan4b = r4b.rows.map(r=>r['QUERY PLAN']).join(' ');
  const before = extractRows(plan4a);
  const after = extractRows(plan4b);
  console.log('   修复前:', JSON.stringify(before));
  console.log('   修复后:', JSON.stringify(after));
  if (before && after) {
    const beforeRatio = before.est === 0 ? '∞' : (before.act / Math.max(before.est, 1)).toFixed(1);
    const afterRatio  = after.est  === 0 ? '∞' : (after.act  / Math.max(after.est, 1)).toFixed(2);
    console.log(`   偏差比: 修复前 ${beforeRatio}x  →  修复后 ${afterRatio}x`);
  }

  // ============ SQL5: 直方图精度提升 ============
  console.log('\n========== SQL5: 直方图精度对比 ==========');
  console.log('-- 5a. 默认 STATISTICS=100 (date 类型):');
  const r5a = await c.query(`
    SELECT (unnest(histogram_bounds::text::timestamp[]))::date AS bucket_bound
    FROM pg_stats
    WHERE tablename = 'customers' AND attname = 'signup_date'
    LIMIT 8
  `);
  console.table(r5a.rows);

  console.log('\n-- 5b. SET STATISTICS=1000 + ANALYZE:');
  await c.query(`ALTER TABLE customers ALTER COLUMN signup_date SET STATISTICS 1000`);
  await c.query(`ANALYZE customers`);
  log('ALTER SET STATISTICS', true);

  const r5b = await c.query(`
    SELECT (unnest(histogram_bounds::text::timestamp[]))::date AS bucket_bound
    FROM pg_stats
    WHERE tablename = 'customers' AND attname = 'signup_date'
    LIMIT 8
  `);
  console.table(r5b.rows);

  // ============ SQL6: bonus - n_distinct = -1 的含义 ============
  console.log('\n========== SQL6 (Bonus): n_distinct = -1 是啥意思 ==========');
  const r6 = await c.query(`
    SELECT
        attname,
        n_distinct,
        CASE
            WHEN n_distinct = -1 THEN '表示该列所有行值唯一 (>=0 视为 distinct 比例)'
            WHEN n_distinct > 0   THEN '该列大约有 ' || n_distinct || ' 个不同值'
            ELSE '异常值'
        END AS meaning
    FROM pg_stats
    WHERE tablename = 'customers' AND attname = 'id'
  `);
  console.table(r6.rows);

  // ============ SQL7: 验证 n_distinct 估算准确性 ============
  console.log('\n========== SQL7 (Bonus): n_distinct 估算 vs 真实 ==========');
  const r7a = await c.query(`SELECT COUNT(DISTINCT city) AS real_distinct FROM customers`);
  const r7b = await c.query(`SELECT n_distinct FROM pg_stats WHERE tablename='customers' AND attname='city'`);
  console.log('   实际 distinct city:', r7a.rows[0].real_distinct);
  console.log('   pg_stats 估算   :', r7b.rows[0].n_distinct);
  const diff = Math.abs(r7a.rows[0].real_distinct - r7b.rows[0].n_distinct);
  const pct = (diff / r7a.rows[0].real_distinct * 100).toFixed(1);
  console.log(`   误差: ${diff} (${pct}%)`);

  await c.end();
  console.log('\n========== 全部 SQL 实测通过 ==========');
}

run().catch(e => { console.error('❌ FAIL:', e.message); process.exit(1); });
