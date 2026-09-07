-- =========================================================
-- 損害保険 損害サービス（協定業務）向け Snowflake Cortex AI ハンズオン
--
-- 03_cortex_agent.sql - Semantic View / Cortex Agent
-- =========================================================
--
-- 前提: git_setup.sql / setup.sql / src/01_ai_functions.ipynb
--       / src/02_cortex_search.sql を実行済み
--
-- やること:
--   ここまでに作った構造化データ（案件・不正スコア）と
--   非構造化データ（約款）を、1つのAIエージェントから横断的に扱えるようにする。
--
--   Semantic View  → 自然言語からSQLを生成（Cortex Analyst）
--   Cortex Search  → 約款の該当条文を検索
--   Cortex Agent   → 上記2つをツールとして使い分ける
--
-- 所要時間の目安: 構築5分＋対話20分
--
-- =========================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE INSURANCE_CLAIMS_WH;
USE DATABASE INSURANCE_CLAIMS_DB;
USE SCHEMA APP;

-- =========================================================
-- Step 1: 案件照会用の Semantic View
-- =========================================================
-- 「どの案件がどういう状態か」を自然言語で聞けるようにする。
-- SYNONYMS に業務で使われる言い回しを列挙するのがText-to-SQL精度の勘所。
CREATE OR REPLACE SEMANTIC VIEW SV_CLAIMS
    TABLES (
        claims AS RAW.CLM_CLAIMS
            PRIMARY KEY (CLAIM_ID)
            WITH SYNONYMS = ('案件', '事故案件', '請求案件', 'クレーム')
            COMMENT = '保険金請求案件',
        vehicles AS REPAIR_REFERENCE.VEHICLES
            PRIMARY KEY (VEHICLE_ID)
            WITH SYNONYMS = ('車両', '車種', 'クルマ')
            COMMENT = '車種マスタ',
        shops AS RAW.CLM_REPAIR_SHOPS
            PRIMARY KEY (SHOP_ID)
            WITH SYNONYMS = ('修理工場', '工場', '鈑金工場', '協定工場')
            COMMENT = '契約修理工場',
        risk AS ANALYTICS.DT_FRAUD_RISK_SCORE
            PRIMARY KEY (CLAIM_ID)
            WITH SYNONYMS = ('リスク', '不正スコア', 'リスク評価')
            COMMENT = '案件別の不正リスクスコア'
    )
    RELATIONSHIPS (
        claims_to_vehicles AS claims (VEHICLE_ID) REFERENCES vehicles (VEHICLE_ID),
        claims_to_shops    AS claims (REPAIR_SHOP_ID) REFERENCES shops (SHOP_ID),
        claims_to_risk     AS claims (CLAIM_ID) REFERENCES risk (CLAIM_ID)
    )
    FACTS (
        claims.ESTIMATED_TOTAL_YEN AS ESTIMATED_TOTAL_YEN
            WITH SYNONYMS = ('見積額', '見積金額', '修理費見積')
            COMMENT = '修理工場から提示された見積合計額（円）',
        risk.RISK_SCORE AS RISK_SCORE
            WITH SYNONYMS = ('リスクスコア', '不正スコア', '危険度')
            COMMENT = '不正リスクスコア（0〜100）',
        risk.CNT_PRICE_OVER AS CNT_PRICE_OVER
            WITH SYNONYMS = ('単価超過件数', '価格アラート件数')
            COMMENT = '部品単価が定価を15%超過した明細の件数',
        risk.CNT_INDEX_OVER AS CNT_INDEX_OVER
            WITH SYNONYMS = ('指数超過件数', '工賃アラート件数')
            COMMENT = '作業指数が標準を30%超過した明細の件数',
        risk.CNT_UNKNOWN_PART AS CNT_UNKNOWN_PART
            WITH SYNONYMS = ('マスタ未登録件数', '不明部品件数')
            COMMENT = '部品マスタに存在しない部品番号の件数',
        risk.CNT_NOT_IN_IMAGE AS CNT_NOT_IN_IMAGE
            WITH SYNONYMS = ('架空計上件数', '画像不整合件数')
            COMMENT = '画像で損傷が確認できない計上部品の件数'
    )
    DIMENSIONS (
        claims.CLAIM_ID AS CLAIM_ID
            WITH SYNONYMS = ('案件番号', '事故受付番号', '請求番号')
            COMMENT = '案件を一意に識別する番号',
        claims.INSURED_NAME AS INSURED_NAME
            WITH SYNONYMS = ('被保険者', '契約者名', 'お客様名')
            COMMENT = '被保険者の氏名',
        claims.ACCIDENT_DATE AS ACCIDENT_DATE
            WITH SYNONYMS = ('事故日', '事故発生日')
            COMMENT = '事故が発生した日',
        claims.ACCIDENT_TYPE AS ACCIDENT_TYPE
            WITH SYNONYMS = ('事故類型', '事故種別', '事故の種類')
            COMMENT = '追突・側面衝突・単独などの事故区分',
        claims.ACCIDENT_DESCRIPTION AS ACCIDENT_DESCRIPTION
            WITH SYNONYMS = ('事故状況', '事故内容')
            COMMENT = '事故状況の記述',
        claims.ADJUSTER_NAME AS ADJUSTER_NAME
            WITH SYNONYMS = ('アジャスター', '担当者', '担当アジャスター')
            COMMENT = '担当した技術アジャスター',
        claims.STATUS AS STATUS
            WITH SYNONYMS = ('ステータス', '状態', '進捗')
            COMMENT = '案件の処理状況',
        vehicles.MAKER AS MAKER
            WITH SYNONYMS = ('メーカー', '自動車メーカー', 'ブランド')
            COMMENT = '自動車メーカー名',
        vehicles.MODEL_NAME AS MODEL_NAME
            WITH SYNONYMS = ('車種名', '車名', 'モデル')
            COMMENT = '車種名',
        vehicles.MODEL_CODE AS MODEL_CODE
            WITH SYNONYMS = ('型式')
            COMMENT = '車両の型式',
        shops.SHOP_NAME AS SHOP_NAME
            WITH SYNONYMS = ('工場名', '修理工場名', '鈑金工場名')
            COMMENT = '修理工場の名称',
        shops.PREFECTURE AS PREFECTURE
            WITH SYNONYMS = ('都道府県', '県', 'エリア', '地域')
            COMMENT = '修理工場の所在都道府県',
        shops.CERTIFIED_LEVEL AS CERTIFIED_LEVEL
            WITH SYNONYMS = ('認定ランク', '工場ランク', '認定等級')
            COMMENT = '当社による工場の認定ランク（A/B）',
        risk.RISK_LEVEL AS RISK_LEVEL
            WITH SYNONYMS = ('リスク判定', '判定', '要精査区分')
            COMMENT = '要精査・要確認・問題なしの3区分'
    )
    METRICS (
        claims.CLAIM_COUNT AS COUNT(claims.CLAIM_ID)
            WITH SYNONYMS = ('案件数', '件数', '請求件数')
            COMMENT = '案件の件数',
        claims.TOTAL_ESTIMATED AS SUM(claims.ESTIMATED_TOTAL_YEN)
            WITH SYNONYMS = ('見積総額', '合計見積額')
            COMMENT = '見積額の合計（円）',
        claims.AVG_ESTIMATED AS AVG(claims.ESTIMATED_TOTAL_YEN)
            WITH SYNONYMS = ('平均見積額')
            COMMENT = '見積額の平均（円）',
        risk.AVG_RISK AS AVG(risk.RISK_SCORE)
            WITH SYNONYMS = ('平均リスクスコア')
            COMMENT = 'リスクスコアの平均',
        risk.MAX_RISK AS MAX(risk.RISK_SCORE)
            WITH SYNONYMS = ('最大リスクスコア')
            COMMENT = 'リスクスコアの最大値'
    )
    COMMENT = '保険金請求案件の照会用セマンティックビュー';

-- =========================================================
-- Step 2: 不正検知分析用の Semantic View
-- =========================================================
-- 明細1行ごとのアラート内容を掘れるようにする。
-- 「どの明細がなぜ引っかかったか」を答えるためのビュー。
CREATE OR REPLACE SEMANTIC VIEW SV_FRAUD
    TABLES (
        anomaly AS ANALYTICS.DT_PRICE_ANOMALY
            WITH SYNONYMS = ('突合結果', 'アラート明細', '異常明細', 'チェック結果')
            COMMENT = '見積明細と参照マスタの突合結果',
        claims AS RAW.CLM_CLAIMS
            PRIMARY KEY (CLAIM_ID)
            WITH SYNONYMS = ('案件', '事故案件')
            COMMENT = '保険金請求案件',
        shops AS RAW.CLM_REPAIR_SHOPS
            PRIMARY KEY (SHOP_ID)
            WITH SYNONYMS = ('修理工場', '工場')
            COMMENT = '契約修理工場'
    )
    RELATIONSHIPS (
        anomaly_to_claims AS anomaly (CLAIM_ID) REFERENCES claims (CLAIM_ID),
        claims_to_shops   AS claims (REPAIR_SHOP_ID) REFERENCES shops (SHOP_ID)
    )
    FACTS (
        anomaly.UNIT_PRICE_YEN AS UNIT_PRICE_YEN
            WITH SYNONYMS = ('見積単価', '請求単価', '部品単価')
            COMMENT = '見積書に記載された部品単価（円）',
        anomaly.LIST_PRICE_YEN AS LIST_PRICE_YEN
            WITH SYNONYMS = ('定価', '希望小売価格', 'マスタ価格')
            COMMENT = '部品マスタの希望小売価格（円）',
        anomaly.PRICE_DIFF_PCT AS PRICE_DIFF_PCT
            WITH SYNONYMS = ('価格乖離率', '単価超過率')
            COMMENT = '定価に対する見積単価の超過率（%）',
        anomaly.LABOR_INDEX AS LABOR_INDEX
            WITH SYNONYMS = ('見積指数', '請求指数')
            COMMENT = '見積書に記載された作業指数',
        anomaly.REFERENCE_INDEX AS REFERENCE_INDEX
            WITH SYNONYMS = ('標準指数', 'マスタ指数', '基準指数')
            COMMENT = '標準作業指数マスタの指数',
        anomaly.INDEX_DIFF_PCT AS INDEX_DIFF_PCT
            WITH SYNONYMS = ('指数乖離率', '指数超過率')
            COMMENT = '標準指数に対する見積指数の超過率（%）'
    )
    DIMENSIONS (
        anomaly.CLAIM_ID AS CLAIM_ID
            WITH SYNONYMS = ('案件番号', '事故受付番号')
            COMMENT = '案件を一意に識別する番号',
        anomaly.LINE_NO AS LINE_NO
            WITH SYNONYMS = ('明細行番号', '行番号')
            COMMENT = '見積明細の行番号',
        anomaly.OPERATION_TYPE AS OPERATION_TYPE
            WITH SYNONYMS = ('作業区分', '区分', '作業種別')
            COMMENT = '部品・板金・塗装・材料などの区分',
        anomaly.PART_NUMBER AS PART_NUMBER
            WITH SYNONYMS = ('部品番号', '品番')
            COMMENT = '純正部品番号',
        anomaly.WORK_NAME AS WORK_NAME
            WITH SYNONYMS = ('作業名', '部品名', '明細名')
            COMMENT = '作業または部品の名称',
        anomaly.CHECK_RESULT AS CHECK_RESULT
            WITH SYNONYMS = ('チェック結果', 'アラート種別', '判定結果')
            COMMENT = 'OK / ALERT_PRICE_OVER / ALERT_INDEX_OVER / UNKNOWN_PART',
        claims.INSURED_NAME AS INSURED_NAME
            WITH SYNONYMS = ('被保険者', '契約者名')
            COMMENT = '被保険者の氏名',
        shops.SHOP_NAME AS SHOP_NAME
            WITH SYNONYMS = ('工場名', '修理工場名')
            COMMENT = '修理工場の名称',
        shops.PREFECTURE AS PREFECTURE
            WITH SYNONYMS = ('都道府県', 'エリア')
            COMMENT = '修理工場の所在都道府県'
    )
    METRICS (
        anomaly.LINE_COUNT AS COUNT(anomaly.LINE_NO)
            WITH SYNONYMS = ('明細件数', '行数')
            COMMENT = '明細の件数',
        anomaly.MAX_PRICE_DIFF AS MAX(anomaly.PRICE_DIFF_PCT)
            WITH SYNONYMS = ('最大価格乖離率')
            COMMENT = '価格乖離率の最大値（%）',
        anomaly.MAX_INDEX_DIFF AS MAX(anomaly.INDEX_DIFF_PCT)
            WITH SYNONYMS = ('最大指数乖離率')
            COMMENT = '指数乖離率の最大値（%）'
    )
    COMMENT = '見積明細の不正検知分析用セマンティックビュー';

-- =========================================================
-- Step 3: Semantic View の動作確認
-- =========================================================
-- Agentに渡す前に、素のSQLで引けることを確認しておく。
-- 複数テーブルのDIMENSIONSを並べる場合はFACTSではなくMETRICSを使う
-- （FACTSとDIMENSIONSを同時指定する場合は同一エンティティに限られる）。
SELECT * FROM SEMANTIC_VIEW(
    SV_CLAIMS
    DIMENSIONS claims.CLAIM_ID, claims.INSURED_NAME, vehicles.MODEL_NAME, risk.RISK_LEVEL
    METRICS    claims.TOTAL_ESTIMATED, risk.MAX_RISK
) ORDER BY MAX_RISK DESC;

-- 明細レベルのアラート内容を確認
SELECT * FROM SEMANTIC_VIEW(
    SV_FRAUD
    DIMENSIONS anomaly.CLAIM_ID, anomaly.WORK_NAME, anomaly.PART_NUMBER, anomaly.CHECK_RESULT
    METRICS    anomaly.MAX_PRICE_DIFF, anomaly.MAX_INDEX_DIFF
) WHERE CHECK_RESULT <> 'OK' ORDER BY CLAIM_ID;

-- 工場別の集計（メトリクスの動作確認）
SELECT * FROM SEMANTIC_VIEW(
    SV_CLAIMS
    DIMENSIONS shops.SHOP_NAME, shops.PREFECTURE
    METRICS    claims.CLAIM_COUNT, claims.TOTAL_ESTIMATED, risk.AVG_RISK
) ORDER BY AVG_RISK DESC NULLS LAST;

-- =========================================================
-- Step 4: Cortex Agent の作成
-- =========================================================
-- 3つのツールを持たせる。
--   案件照会 : SV_CLAIMS へのText-to-SQL
--   不正分析 : SV_FRAUD へのText-to-SQL
--   約款検索 : YAKKAN_SEARCH_SVC へのRAG
--
-- 注意: CREATE AGENT は FROM SPECIFICATION を使う。
CREATE OR REPLACE AGENT CLAIMS_ADJUSTER_AGENT
WITH PROFILE = '{"display_name": "協定業務アシスタント"}'
    COMMENT = '損害サービスの協定業務を支援するAIエージェント'
FROM SPECIFICATION $$
models:
  orchestration: auto

instructions:
  response: |
    あなたは損害保険会社の損害サービス部門を支援するアシスタントです。
    技術アジャスターが協定業務を進めるうえで必要な判断材料を提供します。

    回答のルール:
    - 金額は円単位でカンマ区切りで表記してください（例: 156,464円）。
    - 約款を引用する場合は、必ず条文番号（第N条）を併記してください。
    - リスクスコアが高い案件を示すときは、なぜ高いのか（単価超過・指数超過・
      マスタ未登録・画像不整合のどれか）を必ず根拠として示してください。
    - 数値を答えるときは、集計対象の件数も添えてください。
    - 断定できない場合は、確認が必要な点を明示してください。
    - 回答は日本語で、簡潔に構造化して記述してください。

  orchestration: |
    質問の性質に応じてツールを選択してください。

    - 案件の件数・金額・ステータス・車種・工場・リスクスコアに関する質問は
      「案件照会」を使ってください。
    - どの明細がなぜアラートになったか、単価や指数の乖離に関する質問は
      「不正分析」を使ってください。
    - 支払対象か否か、免責、支払限度額、代車、特約などの
      契約条件に関する質問は「約款検索」を使ってください。
    - 「この案件で代車費用は支払対象か」のように案件情報と約款の
      両方が必要な質問では、両方のツールを使って回答を組み立ててください。

  sample_questions:
    - question: リスクスコアが最も高い案件はどれですか。その理由も教えてください。
    - question: CLM-2024-0004 の見積で価格乖離がある明細を教えてください。
    - question: 修理期間中の代車費用は約款上支払対象になりますか。
    - question: 修理工場別のリスクスコア平均をランキングで教えてください。
    - question: 要精査と判定された案件の見積総額はいくらですか。

tools:
  - tool_spec:
      name: 案件照会
      type: cortex_analyst_text_to_sql
      description: |
        保険金請求案件の照会に使います。案件番号・被保険者・車種・事故類型・
        修理工場・見積額・リスクスコア・リスク判定で絞り込みや集計ができます。
  - tool_spec:
      name: 不正分析
      type: cortex_analyst_text_to_sql
      description: |
        見積明細レベルの不正検知分析に使います。部品番号・作業区分ごとの
        見積単価と定価の比較、見積指数と標準指数の比較、
        チェック結果（単価超過・指数超過・マスタ未登録）の内訳がわかります。
  - tool_spec:
      name: 約款検索
      type: cortex_search
      description: |
        自動車保険約款の検索に使います。免責事由、支払限度額、修理費の認定、
        代車費用特約、修理費用保証特約などの契約条件を条文単位で確認できます。

tool_resources:
  案件照会:
    semantic_view: INSURANCE_CLAIMS_DB.APP.SV_CLAIMS
    execution_environment:
      type: warehouse
      warehouse: INSURANCE_CLAIMS_WH
  不正分析:
    semantic_view: INSURANCE_CLAIMS_DB.APP.SV_FRAUD
    execution_environment:
      type: warehouse
      warehouse: INSURANCE_CLAIMS_WH
  約款検索:
    name: INSURANCE_CLAIMS_DB.APP.YAKKAN_SEARCH_SVC
    id_column: CHUNK_NO
    title_column: SECTION_TITLE
    max_results: 5
$$;

-- =========================================================
-- Step 5: 作成結果の確認
-- =========================================================
SHOW AGENTS LIKE 'CLAIMS_ADJUSTER_AGENT';

DESCRIBE AGENT CLAIMS_ADJUSTER_AGENT;

-- =========================================================
-- Step 6: Snowflake Intelligence で対話する
-- =========================================================
-- Snowsight の左メニュー「AI & ML」→「Snowflake Intelligence」から
-- 「協定業務アシスタント」を選んで、以下を順に試してください。
--
--   1. リスクスコアが最も高い案件はどれですか。その理由も教えてください。
--      → 案件照会ツールが使われ、CLM-2024-0003 が返るはず
--
--   2. CLM-2024-0004 の見積で価格乖離がある明細を教えてください。
--      → 不正分析ツールが使われ、リヤバンパフェイスの+25%が返るはず
--
--   3. 修理期間中の代車費用は約款上支払対象になりますか。
--      → 約款検索ツールが使われ、第18条（代車費用特約）が引用されるはず
--
--   4. 修理工場別のリスクスコア平均をランキングで教えてください。
--      → 案件照会ツールで工場別集計
--
--   5. CLM-2024-0005 は要精査ですが、この案件で代車費用を支払えますか。
--      → 案件照会と約款検索の両方を使う。Agentのオーケストレーションの山場。
--
-- =========================================================
-- 権限付与（他ロールにも使わせる場合）
-- =========================================================
-- GRANT USAGE ON AGENT CLAIMS_ADJUSTER_AGENT TO ROLE <ロール名>;
-- GRANT USAGE ON SEMANTIC VIEW SV_CLAIMS TO ROLE <ロール名>;
-- GRANT USAGE ON SEMANTIC VIEW SV_FRAUD  TO ROLE <ロール名>;
-- GRANT USAGE ON CORTEX SEARCH SERVICE YAKKAN_SEARCH_SVC TO ROLE <ロール名>;

-- =========================================================
-- ハンズオン完了
-- =========================================================
