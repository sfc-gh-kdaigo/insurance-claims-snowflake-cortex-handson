-- =========================================================
-- 損害保険 損害サービス（協定業務）向け Snowflake Cortex AI ハンズオン
--
-- setup.sql - 環境構築・データ投入
-- =========================================================
--
-- ⚠️ 本ハンズオンのデータは全て架空のデモ用データです。
--    実在の人物・企業・団体とは一切関係ありません。
--
-- 前提: git_setup.sql を実行済みであること
--
-- 本ファイルを実行すると以下が構築されます:
--   - 5層スキーマ（REPAIR_REFERENCE / RAW / STAGING / ANALYTICS / APP）
--   - 参照マスタ（車種・部品・指数・工賃単価）
--   - 保険金請求データ（案件5件・画像10件・工場5件）
--   - ステージ（事故車画像・約款PDF・見積書PDF）
--   - 部品指数統合 Dynamic Table
--
-- =========================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE INSURANCE_CLAIMS_WH;
USE DATABASE INSURANCE_CLAIMS_DB;

-- =========================================================
-- Step 1: クロスリージョン推論の有効化
-- =========================================================
-- 東京リージョンでは Vision 対応モデル（claude / pixtral）が未提供の場合があり、
-- これを設定しないと 01_ai_functions.ipynb の AI_COMPLETE が
-- 「unknown model」で失敗する。ハンズオン最大のつまずきポイント。
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';

-- =========================================================
-- Step 2: スキーマ構成
-- =========================================================
-- 5層構成:
--   REPAIR_REFERENCE : 外部ベンダーから購入する修理リファレンス（部品価格・標準作業指数）
--   RAW              : 自社の保険金請求データ（案件・画像・見積書）
--   STAGING          : 名寄せ・統合レイヤ
--   ANALYTICS        : ユースケース別の分析 Dynamic Tables
--   APP              : Semantic View / Cortex Search / Agent
CREATE SCHEMA IF NOT EXISTS REPAIR_REFERENCE
    COMMENT = '外部購入の修理リファレンス（部品定価・標準作業指数）';
CREATE SCHEMA IF NOT EXISTS RAW
    COMMENT = '保険金請求の自社業務データ';
CREATE SCHEMA IF NOT EXISTS STAGING
    COMMENT = '名寄せ・統合レイヤ';
CREATE SCHEMA IF NOT EXISTS ANALYTICS
    COMMENT = 'ユースケース別分析レイヤ';
CREATE SCHEMA IF NOT EXISTS APP
    COMMENT = 'Semantic View / Cortex Search / Agent';

-- =========================================================
-- Step 3: REPAIR_REFERENCE層 — 修理リファレンス（外部購入データ）
-- =========================================================
-- 損害保険会社は部品定価と標準作業指数のリファレンスデータを
-- 外部ベンダーから月次で受領し、見積の妥当性判断の基準値に使う。
USE SCHEMA REPAIR_REFERENCE;

-- ---------------------------------------------------------
-- Step 3-1: 車種マスタ
-- ---------------------------------------------------------
CREATE OR REPLACE TABLE VEHICLES (
    VEHICLE_ID              INT PRIMARY KEY,
    MAKER                   VARCHAR(50)  COMMENT 'メーカー名',
    MODEL_NAME              VARCHAR(100) COMMENT '車種名',
    MODEL_CODE              VARCHAR(20)  COMMENT '型式',
    GENERATION              VARCHAR(50)  COMMENT '世代',
    YEAR_FROM               INT          COMMENT '販売開始年',
    YEAR_TO                 INT          COMMENT '販売終了年（NULL=現行）',
    BODY_TYPE               VARCHAR(30)  COMMENT 'ボディタイプ',
    CLASSIFICATION_NUMBER   VARCHAR(10)  COMMENT '型式類別区分番号'
) COMMENT = '車種マスタ';

INSERT INTO VEHICLES VALUES
    (1, 'トヨタ', 'プリウス',      'ZVW60',   '5代目（60系）', 2023, NULL, 'セダン',   '0069-0001'),
    (2, 'トヨタ', 'アルファード',  'AGH40W',  '4代目（40系）', 2023, NULL, 'ミニバン', '0072-0003'),
    (3, '日産',   'ノート',        'E13',     '3代目（E13）',  2020, NULL, 'ハッチバック', '0055-0012'),
    (4, 'ホンダ', 'N-BOX',         'JF5',     '3代目（JF5）',  2023, NULL, '軽ワゴン', '0081-0002'),
    (5, 'トヨタ', 'ヤリスクロス',  'MXPB10',  '初代（10系）',  2020, NULL, 'SUV',      '0061-0007');

-- ---------------------------------------------------------
-- Step 3-2: 部品マスタ
-- ---------------------------------------------------------
CREATE OR REPLACE TABLE PARTS (
    PART_ID          INT PRIMARY KEY,
    VEHICLE_ID       INT          COMMENT 'FK→VEHICLES',
    PART_NUMBER      VARCHAR(30)  COMMENT '純正部品番号',
    PART_NAME        VARCHAR(200) COMMENT '部品名称',
    PART_CATEGORY    VARCHAR(50)  COMMENT '大分類',
    PART_SUBCATEGORY VARCHAR(50)  COMMENT '中分類',
    PART_LOCATION    VARCHAR(30)  COMMENT '位置',
    MATERIAL         VARCHAR(30)  COMMENT '素材',
    LIST_PRICE_YEN   INT          COMMENT 'メーカー希望小売価格（税込）',
    SUPPLY_FORM      VARCHAR(50)  COMMENT '補給形態',
    IS_REPAIRABLE    BOOLEAN      COMMENT '板金修正可否'
) COMMENT = '部品マスタ（定価の基準値）';

INSERT INTO PARTS VALUES
    -- プリウス ZVW60
    (101, 1, 'TY-52119-47350', 'フロントバンパカバー',        '外装', 'バンパー',     'フロント', 'PP樹脂',  52800, '単品', TRUE),
    (102, 1, 'TY-53101-47120', 'ラジエータグリル',            '外装', 'グリル',       'フロント', 'PP樹脂',  28600, '単品', TRUE),
    (103, 1, 'TY-81110-47B00', '左ヘッドランプASSY',          '電装', 'ランプ',       'フロント', 'ASSY',   118800, '単品', FALSE),
    (104, 1, 'TY-81130-47B00', '右ヘッドランプASSY',          '電装', 'ランプ',       'フロント', 'ASSY',   118800, '単品', FALSE),
    (105, 1, 'TY-53801-47140', '左フロントフェンダ',          '外装', 'フェンダ',     'フロント', '鋼板',    34100, '単品', TRUE),
    (106, 1, 'TY-53802-47140', '右フロントフェンダ',          '外装', 'フェンダ',     'フロント', '鋼板',    34100, '単品', TRUE),
    (107, 1, 'TY-52159-47250', 'リヤバンパカバー',            '外装', 'バンパー',     'リヤ',     'PP樹脂',  48400, '単品', TRUE),
    -- アルファード AGH40W
    (201, 2, 'TY-52119-58180', 'フロントバンパカバー',        '外装', 'バンパー',     'フロント', 'PP樹脂',  79200, '単品', TRUE),
    (202, 2, 'TY-53111-58120', 'ラジエータグリル',            '外装', 'グリル',       'フロント', 'メッキ樹脂', 96800, '単品', FALSE),
    (203, 2, 'TY-52159-58150', 'リヤバンパカバー',            '外装', 'バンパー',     'リヤ',     'PP樹脂',  74800, '単品', TRUE),
    (204, 2, 'TY-81561-58090', '左リヤコンビランプ',          '電装', 'ランプ',       'リヤ',     'ASSY',    52800, '単品', FALSE),
    (205, 2, 'TY-81551-58090', '右リヤコンビランプ',          '電装', 'ランプ',       'リヤ',     'ASSY',    52800, '単品', FALSE),
    (206, 2, 'TY-67005-58120', 'バックドアパネル',            '外装', 'ドア',         'リヤ',     '鋼板',   132000, 'ASSY', TRUE),
    -- ノート E13
    (301, 3, 'NS-62022-6XR0A', 'フロントバンパフェイシア',    '外装', 'バンパー',     'フロント', 'PP樹脂',  46200, '単品', TRUE),
    (302, 3, 'NS-65100-6HH0A', 'ボンネットフード ASSY',       '外装', 'フード',       'フロント', 'アルミ',  89100, 'ASSY', TRUE),
    (303, 3, 'NS-26010-6HH0A', '右ヘッドランプASSY',          '電装', 'ランプ',       'フロント', 'ASSY',    68200, '単品', FALSE),
    (304, 3, 'NS-26060-6HH0A', '左ヘッドランプASSY',          '電装', 'ランプ',       'フロント', 'ASSY',    68200, '単品', FALSE),
    (305, 3, 'NS-63100-6XR0A', '左フロントフェンダ',          '外装', 'フェンダ',     'フロント', '鋼板',    29700, '単品', TRUE),
    (306, 3, 'NS-85022-6XR0A', 'リヤバンパフェイシア',        '外装', 'バンパー',     'リヤ',     'PP樹脂',  44000, '単品', TRUE),
    (307, 3, 'NS-26550-6HH0A', '右リヤコンビランプ',          '電装', 'ランプ',       'リヤ',     'ASSY',    34100, '単品', FALSE),
    -- N-BOX JF5
    (401, 4, 'HN-71101-TDE0-ZZ', 'フロントバンパフェイス',    '外装', 'バンパー',     'フロント', 'PP樹脂',  39600, '単品', TRUE),
    (402, 4, 'HN-67550-TDE0-000', '右スライドドアパネル ASSY', '外装', 'ドア',        'サイド',   '鋼板',    85000, 'ASSY', TRUE),
    (403, 4, 'HN-67510-TDE0-000', '左スライドドアパネル ASSY', '外装', 'ドア',        'サイド',   '鋼板',    85000, 'ASSY', TRUE),
    (404, 4, 'HN-33101-TDE0-000', '右ヘッドライトASSY',       '電装', 'ランプ',       'フロント', 'ASSY',    46200, '単品', FALSE),
    (405, 4, 'HN-60261-TDE0-ZZ', '左フロントフェンダ',        '外装', 'フェンダ',     'フロント', '鋼板',    26400, '単品', TRUE),
    (406, 4, 'HN-75701-TDE0-ZZ', 'リヤバンパフェイス',        '外装', 'バンパー',     'リヤ',     'PP樹脂',  37400, '単品', TRUE),
    (407, 4, 'HN-72150-TDE0-000', '右サイドシルガーニッシュ', '外装', 'ガーニッシュ', 'サイド',   'PP樹脂',  18700, '単品', TRUE),
    (408, 4, 'HN-68100-TDE0-ZZ', 'テールゲートパネル ASSY',   '外装', 'ドア',         'リヤ',     '鋼板',    98000, 'ASSY', TRUE),
    -- ヤリスクロス MXPB10
    (501, 5, 'TY-52119-52A20', 'フロントバンパカバー',        '外装', 'バンパー',     'フロント', 'PP樹脂',  44000, '単品', TRUE),
    (502, 5, 'TY-53801-52180', '左フロントフェンダ',          '外装', 'フェンダ',     'フロント', '鋼板',    28600, '単品', TRUE),
    (503, 5, 'TY-53802-52180', '右フロントフェンダ',          '外装', 'フェンダ',     'フロント', '鋼板',    28600, '単品', TRUE),
    (504, 5, 'TY-67001-52520', '左フロントドアパネル',        '外装', 'ドア',         'サイド',   '鋼板',    72600, 'ASSY', TRUE),
    (505, 5, 'TY-52159-52300', 'リヤバンパカバー',            '外装', 'バンパー',     'リヤ',     'PP樹脂',  41800, '単品', TRUE);

-- ---------------------------------------------------------
-- Step 3-3: 標準作業指数マスタ
-- ---------------------------------------------------------
-- 指数は業界標準の作業時間単位で 1.0 = 1時間。
-- 工賃 = 指数 × 指数対応単価（円/時間）で算出する。
CREATE OR REPLACE TABLE LABOR_INDEX (
    INDEX_ID          INT PRIMARY KEY,
    PART_ID           INT          COMMENT 'FK→PARTS',
    OPERATION_TYPE    VARCHAR(30)  COMMENT '作業区分（脱着/取替/板金/塗装）',
    INDEX_VALUE       FLOAT        COMMENT '指数（1.0=1時間）',
    PAINT_TYPE        VARCHAR(30)  COMMENT '塗膜種類（塗装時のみ）',
    PREREQUISITE_NOTE VARCHAR(500) COMMENT '前提条件'
) COMMENT = '標準作業指数マスタ（工賃の基準値）';

INSERT INTO LABOR_INDEX VALUES
    -- プリウス
    (1001, 101, '取替', 0.6, NULL,         'グリル脱着含む'),
    (1002, 101, '塗装', 2.4, 'メタリック', 'ぼかし込み'),
    (1003, 102, '取替', 0.3, NULL,         NULL),
    (1004, 103, '取替', 0.5, NULL,         'バンパー脱着別途'),
    (1005, 104, '取替', 0.5, NULL,         'バンパー脱着別途'),
    (1006, 105, '取替', 1.4, NULL,         NULL),
    (1007, 105, '板金', 3.8, NULL,         '中程度の凹み'),
    (1008, 105, '塗装', 2.2, 'メタリック', NULL),
    (1009, 106, '取替', 1.4, NULL,         NULL),
    (1010, 106, '板金', 3.8, NULL,         '中程度の凹み'),
    (1011, 107, '取替', 0.7, NULL,         NULL),
    (1012, 107, '塗装', 2.3, 'メタリック', NULL),
    -- アルファード
    (1101, 201, '取替', 0.9, NULL,         'グリル脱着含む'),
    (1102, 201, '塗装', 3.1, 'パール',     '3コートパール'),
    (1103, 202, '取替', 0.4, NULL,         NULL),
    (1104, 203, '取替', 0.9, NULL,         NULL),
    (1105, 203, '塗装', 3.0, 'パール',     '3コートパール'),
    (1106, 204, '取替', 0.4, NULL,         NULL),
    (1107, 205, '取替', 0.4, NULL,         NULL),
    (1108, 206, '取替', 2.8, NULL,         'ランプ・ガーニッシュ脱着含む'),
    (1109, 206, '板金', 5.2, NULL,         '中程度の凹み'),
    (1110, 206, '塗装', 3.4, 'パール',     '3コートパール'),
    -- ノート
    (1201, 301, '取替', 0.6, NULL,         NULL),
    (1202, 301, '塗装', 2.2, 'メタリック', NULL),
    (1203, 302, '取替', 0.8, NULL,         NULL),
    (1204, 302, '板金', 4.2, NULL,         'アルミ材・要専用工具'),
    (1205, 302, '塗装', 2.8, 'メタリック', NULL),
    (1206, 303, '取替', 0.5, NULL,         'バンパー脱着別途'),
    (1207, 304, '取替', 0.5, NULL,         'バンパー脱着別途'),
    (1208, 305, '取替', 1.3, NULL,         NULL),
    (1209, 305, '板金', 3.8, NULL,         '中程度の凹み'),
    (1210, 305, '塗装', 2.1, 'メタリック', NULL),
    (1211, 306, '取替', 0.6, NULL,         NULL),
    (1212, 307, '取替', 0.3, NULL,         NULL),
    -- N-BOX
    (1301, 401, '取替', 0.5, NULL,         NULL),
    (1302, 401, '塗装', 2.0, 'ソリッド',   NULL),
    (1303, 402, '取替', 2.5, NULL,         '内張り・レール脱着含む'),
    (1304, 402, '板金', 4.6, NULL,         '中程度の凹み'),
    (1305, 402, '塗装', 2.7, 'ソリッド',   NULL),
    (1306, 403, '取替', 2.5, NULL,         '内張り・レール脱着含む'),
    (1307, 405, '取替', 1.2, NULL,         NULL),
    (1308, 405, '板金', 3.4, NULL,         '中程度の凹み'),
    (1309, 407, '取替', 0.4, NULL,         NULL),
    (1310, 408, '取替', 2.6, NULL,         'ランプ・ガーニッシュ脱着含む'),
    (1311, 408, '板金', 4.4, NULL,         '中程度の凹み'),
    (1312, 408, '塗装', 2.9, 'ソリッド',   NULL),
    -- ヤリスクロス
    (1401, 501, '取替', 0.6, NULL,         NULL),
    (1402, 501, '塗装', 2.1, 'メタリック', NULL),
    (1403, 502, '取替', 1.3, NULL,         NULL),
    (1404, 502, '板金', 3.8, NULL,         '中程度の凹み'),
    (1405, 502, '塗装', 2.1, 'メタリック', NULL),
    (1406, 504, '取替', 2.2, NULL,         '内張り脱着含む'),
    (1407, 504, '板金', 4.1, NULL,         '中程度の凹み'),
    (1408, 505, '取替', 0.6, NULL,         NULL);

-- ---------------------------------------------------------
-- Step 3-4: 工賃単価マスタ
-- ---------------------------------------------------------
CREATE OR REPLACE TABLE LABOR_RATES (
    REGION               VARCHAR(30) COMMENT '地域',
    PREFECTURE           VARCHAR(10) COMMENT '都道府県',
    OPERATION_TYPE       VARCHAR(30) COMMENT '作業区分',
    RATE_PER_INDEX       INT         COMMENT '指数対応単価（円/時間）',
    PAINT_MATERIAL_RATE  INT         COMMENT '塗装材料代単価',
    MATERIAL_COEFFICIENT FLOAT       COMMENT '材料代係数'
) COMMENT = '工賃単価マスタ（地域別）';

INSERT INTO LABOR_RATES VALUES
    ('関東', '埼玉県', '外板板金', 8800, 8000, 1.0),
    ('関東', '埼玉県', '塗装',     8800, 8000, 1.0),
    ('関東', '埼玉県', '取替脱着', 8800, 0,    1.0),
    ('関東', '東京都', '外板板金', 9600, 8800, 1.1),
    ('関東', '東京都', '塗装',     9600, 8800, 1.1),
    ('関東', '東京都', '取替脱着', 9600, 0,    1.1),
    ('関東', '千葉県', '外板板金', 8600, 7800, 1.0),
    ('関東', '千葉県', '塗装',     8600, 7800, 1.0),
    ('関東', '千葉県', '取替脱着', 8600, 0,    1.0),
    ('関東', '神奈川県', '外板板金', 9200, 8400, 1.05),
    ('関東', '神奈川県', '塗装',     9200, 8400, 1.05),
    ('関東', '神奈川県', '取替脱着', 9200, 0,    1.05);

-- =========================================================
-- Step 4: RAW層 — 保険金請求の自社業務データ
-- =========================================================
USE SCHEMA RAW;

-- ---------------------------------------------------------
-- Step 4-1: 契約修理工場マスタ
-- ---------------------------------------------------------
CREATE OR REPLACE TABLE CLM_REPAIR_SHOPS (
    SHOP_ID               VARCHAR(20) PRIMARY KEY,
    SHOP_NAME             VARCHAR(100) COMMENT '工場名',
    PREFECTURE            VARCHAR(10)  COMMENT '都道府県',
    CITY                  VARCHAR(50)  COMMENT '市区町村',
    CERTIFIED_LEVEL       VARCHAR(20)  COMMENT '認定ランク',
    CONTRACT_SINCE        DATE         COMMENT '契約開始日',
    HISTORICAL_ALERT_RATE FLOAT        COMMENT '過去アラート率'
) COMMENT = '契約修理工場マスタ';

INSERT INTO CLM_REPAIR_SHOPS VALUES
    ('SHP-001', '鈴木自動車鈑金',       '埼玉県', 'さいたま市大宮区', 'A', '2015-04-01', 0.03),
    ('SHP-002', '田中自動車鈑金',       '埼玉県', '川口市',           'B', '2018-07-01', 0.12),
    ('SHP-003', 'オートサービス関東',   '埼玉県', '所沢市',           'B', '2019-10-01', 0.15),
    ('SHP-004', '山本モータース',       '東京都', '足立区',           'A', '2012-04-01', 0.02),
    ('SHP-005', 'カーリペア大宮',       '埼玉県', 'さいたま市北区',   'A', '2016-09-01', 0.04);

-- ---------------------------------------------------------
-- Step 4-2: 保険金請求案件
-- ---------------------------------------------------------
CREATE OR REPLACE TABLE CLM_CLAIMS (
    CLAIM_ID             VARCHAR(20) PRIMARY KEY,
    POLICY_NUMBER        VARCHAR(20)  COMMENT '証券番号',
    INSURED_NAME         VARCHAR(100) COMMENT '被保険者名',
    VEHICLE_ID           INT          COMMENT 'FK→VEHICLES',
    REGISTRATION_NUMBER  VARCHAR(20)  COMMENT '登録番号',
    ACCIDENT_DATE        DATE         COMMENT '事故日',
    ACCIDENT_TYPE        VARCHAR(50)  COMMENT '事故類型',
    ACCIDENT_LOCATION    VARCHAR(200) COMMENT '事故場所',
    ACCIDENT_DESCRIPTION TEXT         COMMENT '事故状況',
    REPAIR_SHOP_ID       VARCHAR(20)  COMMENT 'FK→CLM_REPAIR_SHOPS',
    REPAIR_SHOP_NAME     VARCHAR(100) COMMENT '修理工場名',
    ADJUSTER_NAME        VARCHAR(50)  COMMENT '担当アジャスター',
    STATUS               VARCHAR(30)  COMMENT 'ステータス',
    RECEIVED_AT          TIMESTAMP_NTZ COMMENT '受付日時',
    ESTIMATED_TOTAL_YEN  INT          COMMENT '見積合計額'
) COMMENT = '保険金請求案件（架空データ）';

INSERT INTO CLM_CLAIMS VALUES
    ('CLM-2024-0001', 'SI-A7821345', '中村 健太', 1, 'さいたま300あ1234', '2024-11-10',
     '単独（駐車場）', '埼玉県さいたま市大宮区桜木町1丁目',
     '駐車場で後退中に車止めポールに接触し、リヤバンパー左側を損傷したとの申告。工場からの提出画像は前方左側からの撮影。',
     'SHP-001', '鈴木自動車鈑金', '佐藤 一郎', 'AI分析済', '2024-11-11 09:15:00', 82500),

    ('CLM-2024-0002', 'SI-B3392871', '小林 由美', 2, '大宮500さ5678', '2024-11-14',
     '側面衝突', '埼玉県さいたま市北区宮原町3丁目',
     '交差点で左側面に衝突された。左リヤドアとセンターピラーが広範囲に変形。',
     'SHP-005', 'カーリペア大宮', '佐藤 一郎', 'AI分析済', '2024-11-15 10:30:00', 352000),

    ('CLM-2024-0003', 'SI-C5518902', '渡辺 誠',   3, '川口300か9012', '2024-11-18',
     '追突（加害）', '埼玉県川口市本町4丁目',
     '前方車両に追突。フロントバンパーとフロントフェンダー左側が損傷。',
     'SHP-002', '田中自動車鈑金', '高橋 次郎', 'AI分析済', '2024-11-19 14:20:00', 381898),

    ('CLM-2024-0004', 'SI-D7729183', '伊藤 香織', 4, '所沢580き3456', '2024-11-22',
     '追突（被害）', '埼玉県所沢市東町2丁目',
     '信号待ち停車中に後方から追突された。リヤバンパーとテールゲート下部が変形。',
     'SHP-003', 'オートサービス関東', '高橋 次郎', 'AI分析済', '2024-11-23 11:45:00', 156464),

    ('CLM-2024-0005', 'SI-E9910337', '山田 大輔', 5, 'さいたま301く7890', '2024-11-25',
     '単独（ガードレール）', '埼玉県さいたま市見沼区東大宮5丁目',
     'カーブでハンドル操作を誤りガードレールに接触。左前部から左側面にかけて擦過傷と凹み。',
     'SHP-003', 'オートサービス関東', '高橋 次郎', 'AI分析済', '2024-11-26 08:50:00', 301180);

-- ---------------------------------------------------------
-- Step 4-3: 事故画像メタデータ
-- ---------------------------------------------------------
-- IMAGE_PATH はステージ上の相対パス。ノートブックで TO_FILE() に渡して
-- セル内に画像をインライン表示する。
CREATE OR REPLACE TABLE CLM_IMAGES (
    IMAGE_ID    INT PRIMARY KEY,
    CLAIM_ID    VARCHAR(20)  COMMENT 'FK→CLM_CLAIMS',
    IMAGE_TYPE  VARCHAR(50)  COMMENT '画像種別（事故_/参考_）',
    IMAGE_PATH  VARCHAR(500) COMMENT 'ステージ相対パス',
    UPLOADED_AT TIMESTAMP_NTZ COMMENT 'アップロード日時'
) COMMENT = '事故画像メタデータ';

INSERT INTO CLM_IMAGES VALUES
    (1,  'CLM-2024-0001', '事故_全体', 'claims/CLM-2024-0001_accident.jpg',     '2024-11-11 09:16:00'),
    (2,  'CLM-2024-0001', '参考_新車', 'reference/CLM-2024-0001_reference.jpg', '2024-11-11 09:16:00'),
    (3,  'CLM-2024-0002', '事故_全体', 'claims/CLM-2024-0002_accident.jpg',     '2024-11-15 10:31:00'),
    (4,  'CLM-2024-0002', '参考_新車', 'reference/CLM-2024-0002_reference.jpg', '2024-11-15 10:31:00'),
    (5,  'CLM-2024-0003', '事故_全体', 'claims/CLM-2024-0003_accident.jpg',     '2024-11-19 14:21:00'),
    (6,  'CLM-2024-0003', '参考_新車', 'reference/CLM-2024-0003_reference.jpg', '2024-11-19 14:21:00'),
    (7,  'CLM-2024-0004', '事故_全体', 'claims/CLM-2024-0004_accident.jpg',     '2024-11-23 11:46:00'),
    (8,  'CLM-2024-0004', '参考_新車', 'reference/CLM-2024-0004_reference.jpg', '2024-11-23 11:46:00'),
    (9,  'CLM-2024-0005', '事故_全体', 'claims/CLM-2024-0005_accident.jpg',     '2024-11-26 08:51:00'),
    (10, 'CLM-2024-0005', '参考_新車', 'reference/CLM-2024-0005_reference.jpg', '2024-11-26 08:51:00');

-- ---------------------------------------------------------
-- Step 4-4: 見積書PDFメタデータ
-- ---------------------------------------------------------
CREATE OR REPLACE TABLE CLM_ESTIMATES_RAW (
    ESTIMATE_ID  INT PRIMARY KEY,
    CLAIM_ID     VARCHAR(20)  COMMENT 'FK→CLM_CLAIMS',
    FILE_PATH    VARCHAR(500) COMMENT 'ステージ相対パス',
    RECEIVED_AT  TIMESTAMP_NTZ COMMENT '受領日時'
) COMMENT = '修理工場から受領した見積書PDF';

INSERT INTO CLM_ESTIMATES_RAW VALUES
    (1, 'CLM-2024-0003', 'estimate_CLM-2024-0003.pdf', '2024-11-19 15:00:00'),
    (2, 'CLM-2024-0004', 'estimate_CLM-2024-0004.pdf', '2024-11-23 12:30:00'),
    (3, 'CLM-2024-0005', 'estimate_CLM-2024-0005.pdf', '2024-11-26 09:30:00');

-- =========================================================
-- Step 5: ステージの作成
-- =========================================================
-- ENCRYPTION = SNOWFLAKE_SSE は必須。
-- サーバーサイド暗号化でないと TO_FILE() / AI_PARSE_DOCUMENT /
-- BUILD_SCOPED_FILE_URL がファイルを読めない。
CREATE OR REPLACE STAGE CLAIM_IMAGES_STAGE
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    COMMENT = '事故車画像・新車参考画像';

CREATE OR REPLACE STAGE DOCS_STAGE
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    COMMENT = '約款PDF・見積書PDF';

-- =========================================================
-- Step 6: Gitリポジトリからステージへファイルを配置
-- =========================================================
-- COPY FILES を使うことで参加者は PUT（SnowSQL/CLI）が不要になり、
-- Snowsight のワークシートだけでハンズオンを完結できる。
COPY FILES INTO @CLAIM_IMAGES_STAGE/claims/
    FROM @INTEGRATIONS.insurance_claims_snowflake_cortex_handson/branches/main/data/images/claims/;

COPY FILES INTO @CLAIM_IMAGES_STAGE/reference/
    FROM @INTEGRATIONS.insurance_claims_snowflake_cortex_handson/branches/main/data/images/reference/;

COPY FILES INTO @DOCS_STAGE/
    FROM @INTEGRATIONS.insurance_claims_snowflake_cortex_handson/branches/main/data/pdf/;

-- Directory Table を最新化（これを忘れると DIRECTORY() が空を返す）
ALTER STAGE CLAIM_IMAGES_STAGE REFRESH;
ALTER STAGE DOCS_STAGE REFRESH;

-- =========================================================
-- Step 7: STAGING層 — 部品指数統合 Dynamic Table
-- =========================================================
USE SCHEMA STAGING;

-- 部品ごとに作業区分別の指数を横持ちに変換する。
-- 見積明細と突合する際に「この部品の取替指数は何か」を
-- 1行1部品で引けるようにするのが目的。
CREATE OR REPLACE DYNAMIC TABLE PARTS_MASTER
    TARGET_LAG = '1 hour'
    WAREHOUSE = INSURANCE_CLAIMS_WH
    REFRESH_MODE = FULL
    COMMENT = '部品マスタ＋標準作業指数の統合（突合の基準側）'
AS
SELECT
    p.PART_ID,
    p.VEHICLE_ID,
    v.MAKER,
    v.MODEL_NAME,
    v.MODEL_CODE,
    p.PART_NUMBER,
    p.PART_NAME,
    p.PART_CATEGORY,
    p.PART_SUBCATEGORY,
    p.PART_LOCATION,
    p.MATERIAL,
    p.LIST_PRICE_YEN,
    p.IS_REPAIRABLE,
    MAX(IFF(li.OPERATION_TYPE = '脱着', li.INDEX_VALUE, NULL)) AS REMOVAL_INDEX,
    MAX(IFF(li.OPERATION_TYPE = '取替', li.INDEX_VALUE, NULL)) AS REPLACEMENT_INDEX,
    MAX(IFF(li.OPERATION_TYPE = '板金', li.INDEX_VALUE, NULL)) AS BODYWORK_INDEX,
    MAX(IFF(li.OPERATION_TYPE = '塗装' AND li.PAINT_TYPE = 'メタリック', li.INDEX_VALUE, NULL)) AS PAINT_INDEX_METALLIC,
    MAX(IFF(li.OPERATION_TYPE = '塗装' AND li.PAINT_TYPE = 'ソリッド',   li.INDEX_VALUE, NULL)) AS PAINT_INDEX_SOLID,
    MAX(IFF(li.OPERATION_TYPE = '塗装' AND li.PAINT_TYPE = 'パール',     li.INDEX_VALUE, NULL)) AS PAINT_INDEX_PEARL
FROM INSURANCE_CLAIMS_DB.REPAIR_REFERENCE.PARTS p
JOIN INSURANCE_CLAIMS_DB.REPAIR_REFERENCE.VEHICLES v
    ON p.VEHICLE_ID = v.VEHICLE_ID
LEFT JOIN INSURANCE_CLAIMS_DB.REPAIR_REFERENCE.LABOR_INDEX li
    ON p.PART_ID = li.PART_ID
GROUP BY ALL;

-- =========================================================
-- Step 8: 構築結果の確認
-- =========================================================
-- 期待値と一致していれば成功。
--   VEHICLES=5 / PARTS=33 / LABOR_INDEX=54 / LABOR_RATES=12
--   CLM_CLAIMS=5 / CLM_IMAGES=10 / CLM_REPAIR_SHOPS=5 / CLM_ESTIMATES_RAW=3
--   PARTS_MASTER=33
SELECT 'REPAIR_REFERENCE.VEHICLES'  AS OBJECT_NAME, COUNT(*) AS ROW_CNT, 5  AS EXPECTED FROM REPAIR_REFERENCE.VEHICLES
UNION ALL SELECT 'REPAIR_REFERENCE.PARTS',        COUNT(*), 33 FROM REPAIR_REFERENCE.PARTS
UNION ALL SELECT 'REPAIR_REFERENCE.LABOR_INDEX',  COUNT(*), 54 FROM REPAIR_REFERENCE.LABOR_INDEX
UNION ALL SELECT 'REPAIR_REFERENCE.LABOR_RATES',  COUNT(*), 12 FROM REPAIR_REFERENCE.LABOR_RATES
UNION ALL SELECT 'RAW.CLM_CLAIMS',                COUNT(*), 5  FROM RAW.CLM_CLAIMS
UNION ALL SELECT 'RAW.CLM_IMAGES',                COUNT(*), 10 FROM RAW.CLM_IMAGES
UNION ALL SELECT 'RAW.CLM_REPAIR_SHOPS',          COUNT(*), 5  FROM RAW.CLM_REPAIR_SHOPS
UNION ALL SELECT 'RAW.CLM_ESTIMATES_RAW',         COUNT(*), 3  FROM RAW.CLM_ESTIMATES_RAW
UNION ALL SELECT 'STAGING.PARTS_MASTER',          COUNT(*), 33 FROM STAGING.PARTS_MASTER
ORDER BY OBJECT_NAME;

-- ステージ上のファイル確認（画像10件 + PDF4件が見えていれば成功）
SELECT 'CLAIM_IMAGES_STAGE' AS STAGE_NAME, RELATIVE_PATH, ROUND(SIZE/1024) AS SIZE_KB
FROM DIRECTORY(@RAW.CLAIM_IMAGES_STAGE)
UNION ALL
SELECT 'DOCS_STAGE', RELATIVE_PATH, ROUND(SIZE/1024)
FROM DIRECTORY(@RAW.DOCS_STAGE)
ORDER BY STAGE_NAME, RELATIVE_PATH;

-- =========================================================
-- 次は src/01_ai_functions.ipynb を実行してください
-- =========================================================
