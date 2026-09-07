-- =========================================================
-- 損害保険 損害サービス（協定業務）向け Snowflake Cortex AI ハンズオン
-- 〜事故車画像のAI分析と修理見積の不正検知シナリオ〜
--
-- git_setup.sql - GitHubリポジトリ連携
-- =========================================================
--
-- ⚠️ 本ハンズオンのデータは全て架空のデモ用データです。
--    実在の人物・企業・団体とは一切関係ありません。
--
-- 📁 実行順:
--    0. git_setup.sql              ← 本ファイル（GitHub連携）
--    1. setup.sql                  ← 環境構築・データ投入
--    2. src/01_ai_functions.ipynb  ← Cortex AI関数（画像分析・見積抽出・不正検知）
--    3. src/02_cortex_search.sql   ← Cortex Search（約款RAG）
--    4. src/03_cortex_agent.sql    ← Semantic View / Cortex Agent
--
-- =========================================================

USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------
-- Step 0-1: ウェアハウスとデータベースの作成
-- ---------------------------------------------------------
-- Git連携の時点でウェアハウスが必要になるため先に作成する
CREATE WAREHOUSE IF NOT EXISTS INSURANCE_CLAIMS_WH
    WAREHOUSE_SIZE = 'SMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = FALSE
    COMMENT = '損害サービスAIハンズオン用';

USE WAREHOUSE INSURANCE_CLAIMS_WH;

CREATE DATABASE IF NOT EXISTS INSURANCE_CLAIMS_DB;
USE DATABASE INSURANCE_CLAIMS_DB;

-- Git連携オブジェクトを置くスキーマ
CREATE SCHEMA IF NOT EXISTS INTEGRATIONS;
USE SCHEMA INTEGRATIONS;

-- ---------------------------------------------------------
-- Step 0-2: GitHubリポジトリと連携するためのAPI統合を作成
-- ---------------------------------------------------------
CREATE OR REPLACE API INTEGRATION git_api_integration
    API_PROVIDER = git_https_api
    API_ALLOWED_PREFIXES = ('https://github.com/sfc-gh-kdaigo/')
    ENABLED = TRUE;

-- ---------------------------------------------------------
-- Step 0-3: 損害サービス向けハンズオン用のGitHubリポジトリを登録
-- ---------------------------------------------------------
CREATE OR REPLACE GIT REPOSITORY insurance_claims_snowflake_cortex_handson
    API_INTEGRATION = git_api_integration
    ORIGIN = 'https://github.com/sfc-gh-kdaigo/insurance-claims-snowflake-cortex-handson.git';

-- ---------------------------------------------------------
-- Step 0-4: リポジトリの内容を取得
-- ---------------------------------------------------------
-- FETCH を忘れるとこの後の setup.sql の COPY FILES が空振りする
ALTER GIT REPOSITORY insurance_claims_snowflake_cortex_handson FETCH;

-- ---------------------------------------------------------
-- Step 0-5: 取得結果の確認
-- ---------------------------------------------------------
-- data/pdf と data/images 配下にファイルが見えていれば成功
LS @insurance_claims_snowflake_cortex_handson/branches/main/data/pdf/;
LS @insurance_claims_snowflake_cortex_handson/branches/main/data/images/claims/;
LS @insurance_claims_snowflake_cortex_handson/branches/main/data/images/reference/;

-- =========================================================
-- 次は setup.sql を実行してください
-- =========================================================
