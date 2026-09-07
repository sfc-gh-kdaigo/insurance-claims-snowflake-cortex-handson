# 損害サービス（協定業務）AI高度化ハンズオン

自動車事故の**損害査定と修理見積の不正検知**を題材にした Snowflake Cortex AI ハンズオンです。

事故車の画像、修理工場から届く見積書PDF、部品定価・標準作業指数のリファレンスマスタ、
そして保険約款という**性質の異なる4種類のデータを1つのプラットフォーム上で突き合わせ**、
アジャスターが見るべき案件を機械的に浮かび上がらせるまでを体験します。

> データは全て架空のデモ用データです。実在の人物・企業・団体とは一切関係ありません。
> 同梱の約款PDFもハンズオン用に作成した架空の約款です。

---

## 業務背景

損害保険の**協定業務**とは、修理工場と修理内容・修理費用について合意するプロセスです。
これを担う技術アジャスターは慢性的に不足しており、1人が月100件以上の見積を目視で査定しています。

修理費の水増しや架空計上を見逃せば保険金の過払いが発生しますが、全件を人手で精査するのは現実的ではありません。

厄介なのは、**不正の手口ごとに検出に必要なデータが違う**という点です。

| 手口 | 検出に必要なもの |
|---|---|
| 部品単価の水増し | 見積明細 ＋ 部品定価マスタ |
| 作業指数の水増し | 見積明細 ＋ 標準作業指数マスタ |
| 架空計上（壊れていない部位の計上） | 見積明細 ＋ **事故車画像** |
| 型式違いの部品計上 | 見積明細 ＋ 型式別部品マスタ |

価格マスタとの突合だけでは架空計上は見抜けず、画像分析だけでは単価の妥当性は判断できません。
**画像・PDF・マスタを同じ場所で突き合わせられること**が、この検知を成立させています。

---

## 前提条件

| 項目 | 内容 |
|---|---|
| Snowflakeアカウント | トライアルアカウントで実施可能 |
| ロール | `ACCOUNTADMIN` |
| リージョン | どこでも可（クロスリージョン推論を `setup.sql` で有効化します） |
| 必要ツール | ブラウザのみ（SnowSQL / CLI は不要） |

ファイルは Git 連携経由で Snowflake に取り込むため、参加者側での `PUT` 作業は発生しません。

---

## 実行順

Snowsight のワークシートで上から順に実行してください。

| # | ファイル | 内容 | 実行時間 | 解説込みの目安 |
|---|---|---|---|---|
| 0 | `git_setup.sql` | GitHubリポジトリ連携 | 21秒 | 5分 |
| 1 | `setup.sql` | 環境構築・データ投入 | 46秒 | 10分 |
| 2 | `src/01_ai_functions.ipynb` | FILE型で画像確認 → AI関数で分析・不正検知 | 63秒 | 40分 |
| 3 | `src/02_cortex_search.sql` | 約款RAG構築 | 46秒 | 15分 |
| 4 | `src/03_cortex_agent.sql` | Semantic View / Agent構築 | 15秒 | 25分 |

実行時間は SMALL ウェアハウスでの実測値です（ゼロ状態から通しで約3分半）。
残りは解説と結果の読み解きに充てられます。

`src/01_ai_functions.ipynb` は Snowsight の
**Projects » Notebooks » Create » Notebook from repository** で
Gitリポジトリから直接取り込めます。取り込み後、ウェアハウスに `INSURANCE_CLAIMS_WH` を指定してください。

---

## 構築されるもの

```
INSURANCE_CLAIMS_DB
├── INTEGRATIONS      Git連携（API統合・Gitリポジトリ）
├── REPAIR_REFERENCE  修理リファレンス（外部購入データ相当）
│   ├── VEHICLES      車種マスタ            5件
│   ├── PARTS         部品マスタ           33件
│   ├── LABOR_INDEX   標準作業指数マスタ   54件
│   └── LABOR_RATES   工賃単価マスタ       12件
├── RAW               自社業務データ
│   ├── CLM_CLAIMS         保険金請求案件   5件
│   ├── CLM_IMAGES         事故画像メタ    10件
│   ├── CLM_REPAIR_SHOPS   契約修理工場     5件
│   ├── CLM_ESTIMATES_RAW  見積書PDFメタ    3件
│   ├── CLAIM_IMAGES_STAGE 事故車・参考画像（ステージ）
│   └── DOCS_STAGE         約款・見積書PDF（ステージ）
├── STAGING
│   ├── PARTS_MASTER       部品＋指数の統合（Dynamic Table）
│   ├── DAMAGE_ASSESSMENT  画像AI分析の生結果
│   ├── ESTIMATE_DETAILS   見積明細（AI_EXTRACT）
│   ├── YAKKAN_PARSED      約款パース結果
│   └── YAKKAN_CHUNKS      約款チャンク
├── ANALYTICS
│   ├── DT_DAMAGE_ASSESSMENT 損傷部位（1行1部位）
│   ├── DT_PRICE_ANOMALY     マスタ突合結果（Dynamic Table）
│   ├── DT_IMAGE_CONSISTENCY 画像整合チェック
│   ├── DT_FRAUD_RISK_SCORE  案件別リスクスコア（Dynamic Table）
│   └── DT_SHOP_PERFORMANCE  工場別実績（Dynamic Table）
└── APP
    ├── YAKKAN_SEARCH_SVC     約款検索（Cortex Search）
    ├── SV_CLAIMS             案件照会（Semantic View）
    ├── SV_FRAUD              不正分析（Semantic View）
    └── CLAIMS_ADJUSTER_AGENT 協定業務アシスタント（Cortex Agent）
```

---

## 学べる機能

| 機能 | どこで使うか |
|---|---|
| **FILE型 / `TO_FILE()`** | ステージ上の画像をノートブックのセル内に直接表示し、同じオブジェクトをそのままAIに渡す |
| `AI_COMPLETE`（Vision） | 事故車画像から損傷部位・程度・修理方法を判定 |
| `response_format` | 出力をOBJECT型に固定し、自由文のパースを不要にする |
| `AI_EXTRACT`（テーブル抽出） | 見積書PDFの明細表を1行1明細に構造化 |
| `AI_PARSE_DOCUMENT` | 約款PDFをレイアウト保持でテキスト化 |
| `SPLIT_TEXT_RECURSIVE_CHARACTER` | 約款を条文単位に近い形でチャンク化 |
| Cortex Search | 日本語約款のベクトル検索（`voyage-multilingual-2`） |
| Semantic View | 自然言語からのSQL生成（Cortex Analyst） |
| Cortex Agent | 構造化データと非構造化データを跨ぐオーケストレーション |
| Dynamic Tables | 突合ロジックを宣言的に定義 |

---

## 検出される3つの不正パターン

`src/01_ai_functions.ipynb` を実行すると、5件の案件が次のように判定されます。

| 案件 | 車種 | 判定 | スコア | 検出根拠 |
|---|---|---|---|---|
| CLM-2024-0003 | ノート E13 | 要精査 | 75 | 画像の損傷は「左」ヘッドランプだが「右」を計上／マスタ未登録の部品番号 |
| CLM-2024-0005 | ヤリスクロス | 要精査 | 55 | 左フロントフェンダ板金 指数9.5 vs 標準3.8（+150%） |
| CLM-2024-0004 | N-BOX JF5 | 要確認 | 25 | リヤバンパフェイス 46,800円 vs 定価 37,400円（+25%） |
| CLM-2024-0002 | アルファード | 問題なし | 0 | — |
| CLM-2024-0001 | プリウス | 問題なし | 0 | 提出画像に損傷が写っておらず申告内容と不一致（再撮影対象） |

判定のしきい値は次のとおりです。

| チェック | 条件 | 配点 |
|---|---|---|
| 画像整合 | 画像で損傷が確認できない部品の計上 | 30点/件 |
| 部品単価 | 見積単価 > 定価 × 1.15 | 25点/件 |
| 作業指数 | 見積指数 > 標準指数 × 1.30 | 25点/件 |
| 部品番号 | マスタに存在しない | 15点/件 |

---

## Agentへの想定質問

`src/03_cortex_agent.sql` の実行後、Snowsight の
**AI & ML » Snowflake Intelligence** から「協定業務アシスタント」を選んで試してください。

1. **リスクスコアが最も高い案件はどれですか。その理由も教えてください。**
   → 案件照会ツール。CLM-2024-0003 が返ります。
2. **CLM-2024-0004 の見積で価格乖離がある明細を教えてください。**
   → 不正分析ツール。リヤバンパフェイスの +25% が返ります。
3. **修理期間中の代車費用は約款上支払対象になりますか。**
   → 約款検索ツール。第18条（代車費用特約）が引用されます。
4. **修理工場別のリスクスコア平均をランキングで教えてください。**
   → 案件照会ツールで工場別集計。
5. **CLM-2024-0005 は要精査ですが、この案件で代車費用を支払えますか。**
   → 案件照会と約款検索の両方を使います。オーケストレーションの山場です。

---

## トラブルシュート

### `COPY FILES` でファイルがコピーされない
`git_setup.sql` の `ALTER GIT REPOSITORY ... FETCH` が実行されているか確認してください。
FETCH していないとリポジトリステージが空のままです。

### ステージにファイルが見えない / `DIRECTORY()` が空
`ALTER STAGE <ステージ名> REFRESH;` を実行してください。
Directory Table は自動更新されません。

### `TO_FILE()` で画像が表示されない
- ステージが `ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')` で作られているか確認してください。
  クライアントサイド暗号化のステージでは FILE 型が読めません。
- 結果グリッドではなくワークシートで実行していないか確認してください。
  サムネイル表示はノートブックおよびワークシートの結果グリッドで機能します。
- `BUILD_SCOPED_FILE_URL()` はURL文字列を返すだけで画像は表示されません。`TO_FILE()` を使ってください。

### `AI_COMPLETE` が "Model is unavailable" で失敗する
Vision対応モデルが自リージョンで提供されていない可能性があります。
`setup.sql` の以下が実行されているか確認してください。

```sql
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';
```

それでも失敗する場合、ノートブック内の `claude-sonnet-4-5` を
`pixtral-large` / `claude-4-sonnet` / `llama4-maverick` のいずれかに変更してください。

### `PROMPT()` で「引数1は定数である必要があります」エラー
`PROMPT()` の第1引数にカラムを連結できません。
`PROMPT('... {0} ... {1}', col1, col2)` のようにプレースホルダで渡してください。

### 日本語のカラム別名で構文エラーになる
`AS 見積額` のように日本語の別名を使う場合はダブルクォートで囲んでください（`AS "見積額"`）。

### `AI_EXTRACT` の抽出値が隣の列にずれる
`column_ordering` に**文書に現れる全列を、現れる順に**列挙してください。
`No.` のような連番列を省略したり、途中の列で打ち切ると値がずれます。

### 部品番号がマスタと結合できない
抽出時に数字の `0` が英字 `O` と誤読されることがあります。
ノートブックでは `REPLACE(UPPER(...), 'O', '0')` で正規化しています。

### `SEMANTIC_VIEW()` で "must come from the same entity" エラー
`FACTS` と `DIMENSIONS` を同時に指定する場合、同一エンティティに限られます。
複数テーブルの `DIMENSIONS` を並べるときは `FACTS` ではなく `METRICS` を使ってください。

---

## 後片付け

```sql
USE ROLE ACCOUNTADMIN;
DROP DATABASE IF EXISTS INSURANCE_CLAIMS_DB;
DROP WAREHOUSE IF EXISTS INSURANCE_CLAIMS_WH;
```

---

## データの再生成

同梱のPDFは以下のスクリプトで生成しています（ハンズオンの実行には不要です）。

- 約款PDF: `workspace/data/generate_yakkan.py`
- 見積書PDF: `workspace/data/generate_estimates_html.py`

いずれもヘッドレスChromeでHTMLから印刷しています。
`fpdf2` で日本語フォントを埋め込むと Identity-H の CIDサブセットになり、
`AI_PARSE_DOCUMENT` / `AI_EXTRACT` がテキストを読み取れず文字化けするためです。
