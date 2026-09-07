-- =========================================================
-- 損害保険 損害サービス（協定業務）向け Snowflake Cortex AI ハンズオン
--
-- 02_cortex_search.sql - 約款RAG（Cortex Search）
-- =========================================================
--
-- 前提: git_setup.sql / setup.sql / src/01_ai_functions.ipynb を実行済み
--
-- やること:
--   自動車保険の約款PDFを検索可能にし、
--   アジャスターが「この費用は約款上支払対象か」を即座に確認できるようにする。
--
--   約款PDF → AI_PARSE_DOCUMENT → チャンク分割 → Cortex Search Service
--
-- 所要時間の目安: 全体3〜5分程度
--
-- =========================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE INSURANCE_CLAIMS_WH;
USE DATABASE INSURANCE_CLAIMS_DB;
USE SCHEMA STAGING;

-- =========================================================
-- Step 1: 約款PDFをパースする
-- =========================================================
-- mode = LAYOUT を指定すると、見出し・表構造をMarkdown風に保った
-- テキストが得られる。条文の階層が残るため、後段のチャンク分割で
-- 文脈が切れにくくなる。
--
-- 注意: 約10ページの約款で20秒程度かかります。
CREATE OR REPLACE TABLE YAKKAN_PARSED AS
SELECT
    'auto_insurance_yakkan.pdf' AS FILE_NAME,
    AI_PARSE_DOCUMENT(
        TO_FILE('@RAW.DOCS_STAGE', 'auto_insurance_yakkan.pdf'),
        {'mode': 'LAYOUT'}
    ) AS PARSED;

-- 抽出できた文字数を確認
SELECT
    FILE_NAME,
    LENGTH(PARSED:content::STRING) AS TOTAL_CHARS
FROM YAKKAN_PARSED;

-- =========================================================
-- Step 2: チャンクに分割する
-- =========================================================
-- SPLIT_TEXT_RECURSIVE_CHARACTER は段落→行→単語の順に
-- 区切りを探すため、文の途中でぶつ切りになりにくい。
--
--   chunk_size = 800 : 条文1つ分がおおよそ収まる長さ
--   overlap    = 150 : 条文の境目に跨る記述を取りこぼさないための重複
CREATE OR REPLACE TABLE YAKKAN_CHUNKS AS
WITH chunked AS (
    SELECT
        p.FILE_NAME,
        c.INDEX + 1        AS CHUNK_NO,
        c.VALUE::STRING    AS CHUNK_TEXT
    FROM YAKKAN_PARSED p,
         LATERAL FLATTEN(input => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
             p.PARSED:content::STRING,
             'markdown',
             800,
             150
         )) c
)
SELECT
    FILE_NAME,
    CHUNK_NO,
    CHUNK_TEXT,
    -- チャンクの見出しをセクション名として拾う。
    -- 検索結果に「どの条文か」を添えて返せるようにするための属性。
    -- チャンクが章の切れ目から始まると先頭見出しが「第N章」になってしまうため、
    -- 条文（第N条）を優先して探し、無い場合に章見出しへフォールバックする。
    COALESCE(
        NULLIF(TRIM(REGEXP_SUBSTR(CHUNK_TEXT, '第[0-9０-９]+条（[^）]*）', 1, 1)), ''),
        NULLIF(TRIM(REGEXP_SUBSTR(CHUNK_TEXT, '^#{1,4}[ \t]*(.+)$', 1, 1, 'm', 1)), ''),
        '（見出しなし）'
    ) AS SECTION_TITLE,
    LENGTH(CHUNK_TEXT) AS CHUNK_LENGTH
FROM chunked
-- 目次断片や空行だけのチャンクは検索ノイズになるため除外する
WHERE LENGTH(TRIM(CHUNK_TEXT)) >= 100;

-- チャンク数と長さの分布を確認
SELECT
    COUNT(*)                    AS CHUNK_CNT,
    MIN(CHUNK_LENGTH)           AS MIN_LEN,
    ROUND(AVG(CHUNK_LENGTH))    AS AVG_LEN,
    MAX(CHUNK_LENGTH)           AS MAX_LEN
FROM YAKKAN_CHUNKS;

-- 中身をいくつか目で確認する
SELECT CHUNK_NO, SECTION_TITLE, LEFT(CHUNK_TEXT, 200) AS PREVIEW
FROM YAKKAN_CHUNKS
ORDER BY CHUNK_NO
LIMIT 10;

-- =========================================================
-- Step 3: Cortex Search Service を作成する
-- =========================================================
USE SCHEMA APP;

-- EMBEDDING_MODEL に voyage-multilingual-2 を指定するのが要点。
-- 既定の英語中心モデルでは日本語約款の検索精度が落ちる。
CREATE OR REPLACE CORTEX SEARCH SERVICE YAKKAN_SEARCH_SVC
    ON CHUNK_TEXT
    ATTRIBUTES SECTION_TITLE, CHUNK_NO
    WAREHOUSE = INSURANCE_CLAIMS_WH
    TARGET_LAG = '1 hour'
    EMBEDDING_MODEL = 'voyage-multilingual-2'
    COMMENT = '自動車保険約款の検索サービス'
AS
SELECT
    CHUNK_TEXT,
    SECTION_TITLE,
    CHUNK_NO
FROM STAGING.YAKKAN_CHUNKS;

-- 構築状況を確認（INDEXING が完了するまで検索できない）
SHOW CORTEX SEARCH SERVICES LIKE 'YAKKAN_SEARCH_SVC';

DESCRIBE CORTEX SEARCH SERVICE YAKKAN_SEARCH_SVC;

-- =========================================================
-- Step 4: 検索を試す
-- =========================================================
-- アジャスターが実務で確認したい5つの論点で検索する。

-- ---------------------------------------------------------
-- 4-1: 免責事由 — 「そもそも支払対象か」の最初の確認
-- ---------------------------------------------------------
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'INSURANCE_CLAIMS_DB.APP.YAKKAN_SEARCH_SVC',
        '{"query": "保険金が支払われない免責事由にはどのようなものがあるか",
          "columns": ["SECTION_TITLE", "CHUNK_TEXT"],
          "limit": 3}'
    )
)['results'] AS RESULTS;

-- ---------------------------------------------------------
-- 4-2: 支払限度額 — 高額見積を受けたときの上限確認
-- ---------------------------------------------------------
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'INSURANCE_CLAIMS_DB.APP.YAKKAN_SEARCH_SVC',
        '{"query": "車両保険の支払限度額はどのように決まるか",
          "columns": ["SECTION_TITLE", "CHUNK_TEXT"],
          "limit": 3}'
    )
)['results'] AS RESULTS;

-- ---------------------------------------------------------
-- 4-3: 修理費 — 修理費が時価額を超える場合の扱い（全損判定）
-- ---------------------------------------------------------
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'INSURANCE_CLAIMS_DB.APP.YAKKAN_SEARCH_SVC',
        '{"query": "修理費が車両の時価額を超える場合はどう取り扱われるか",
          "columns": ["SECTION_TITLE", "CHUNK_TEXT"],
          "limit": 3}'
    )
)['results'] AS RESULTS;

-- ---------------------------------------------------------
-- 4-4: 代車費用 — 被保険者から必ず聞かれる論点
-- ---------------------------------------------------------
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'INSURANCE_CLAIMS_DB.APP.YAKKAN_SEARCH_SVC',
        '{"query": "修理期間中の代車費用やレンタカー費用は支払対象になるか",
          "columns": ["SECTION_TITLE", "CHUNK_TEXT"],
          "limit": 3}'
    )
)['results'] AS RESULTS;

-- ---------------------------------------------------------
-- 4-5: 特約 — 適用可能な特約の確認
-- ---------------------------------------------------------
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'INSURANCE_CLAIMS_DB.APP.YAKKAN_SEARCH_SVC',
        '{"query": "車両保険に付帯できる特約の適用条件",
          "columns": ["SECTION_TITLE", "CHUNK_TEXT"],
          "limit": 3}'
    )
)['results'] AS RESULTS;

-- =========================================================
-- Step 5: 検索結果を読みやすく展開する
-- =========================================================
-- 実務では条文の引用元（セクション名）を必ず添える必要があるため、
-- 結果をフラット化して「引用付きの回答」を作れる形にしておく。
SELECT
    f.INDEX + 1                        AS RANK,
    f.VALUE:SECTION_TITLE::STRING      AS "条文",
    LEFT(f.VALUE:CHUNK_TEXT::STRING, 400) AS "該当箇所"
FROM TABLE(FLATTEN(
    input => PARSE_JSON(
        SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
            'INSURANCE_CLAIMS_DB.APP.YAKKAN_SEARCH_SVC',
            '{"query": "修理期間中の代車費用は支払対象になるか",
              "columns": ["SECTION_TITLE", "CHUNK_TEXT"],
              "limit": 5}'
        )
    )['results']
)) f
ORDER BY RANK;

-- =========================================================
-- 次は src/03_cortex_agent.sql を実行してください
-- =========================================================
