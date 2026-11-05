# SWF脱却・フレームワーク依存除去 調査手順書

Spring Web Flow（SWF）および Spring Framework 等が提供する機能を Java 標準で実装し直すにあたり、修正方針と修正範囲を洗い出すための手順書です。調査には Codex CLI を使用し、トークン上限に達しないよう、対象を機械的に小さな単位へ分割してから調査します。

---

## 0. 全体の流れ

| フェーズ | 内容 | 主体 | 成果物 |
|---|---|---|---|
| 0. 棚卸し | スクリプトでファイル分類・依存検出・調査単位の作成 | スクリプト | `_inventory/*.csv`、`_units/*.txt`、チェックリスト |
| 1. パイロット | 小さな1単位で試行し、テンプレートと単位サイズを調整 | Codex＋人 | 調整済みの `TEMPLATE.md`・`$MaxLines` |
| 2. 共通基盤調査 | `common` レイヤを先に調査し、要約を作る | Codex | `results/common-*.md`、`common-summary.md` |
| 3. 単位別調査 | 残りのレイヤを単位ごとに調査 | Codex | `results/<単位ID>.md` |
| 4. 縦調査 | 代表フローを選び、flow定義を起点に関連ファイルを機械抽出して横断的に追う | スクリプト＋Codex＋人 | `results/vertical-<フロー名>.md` |
| 5. 集約 | 影響メモの突合、レイヤ別要約、方針案の作成 | スクリプト＋Codex＋人 | `summary/*.md`、`policy-draft.md` |

人が1ファイルずつ確認する作業は発生しません。人の作業は、分類ルールの調整、パイロット結果の確認、確信度「低」の項目の確認、最終的な方針判断に限られます。

---

## 1. 前提と準備

### 1.1 必要なもの
- PowerShell 5.1 以上（Windows 標準のもので可）
- JDK（`jdeps` コマンドが使えること。JDK 8 以降に同梱）
- ビルド済みの class ファイル（間接参照の解析に使用）
- Codex CLI

### 1.2 事前確認
- **社内規程**：Codex CLI はソースコードを外部の AI サービスへ送信します。顧客資産や社外秘コードを扱えるかどうか、事前に確認してください。
- **作業ブランチ**：調査用のブランチを切ってから始めると、Codex が誤ってソースを変更しても `git diff` で検知・破棄できます。

### 1.3 ディレクトリ構成（スクリプトが自動作成）

```
docs/survey/
├─ AGENTS.md 等の設定は リポジトリ直下（4章）
├─ TEMPLATE.md              … 調査結果のテンプレート（6章の内容を保存）
├─ survey-checklist.md      … 進捗管理（自動生成）
├─ _inventory/              … 棚卸し結果（自動生成）
│   ├─ inventory.csv            全ファイルの分類・行数・段階数
│   ├─ direct_refs.csv          キーワードによる直接参照
│   ├─ xml_class_refs.csv       XMLから参照されているクラス
│   ├─ reflection_refs.csv      リフレクション等の文字列参照
│   ├─ spring_dependents.csv    Springからの段階数（間接参照）
│   ├─ units.csv                調査単位の一覧
│   ├─ flow_stats.csv           フロー一覧と規模（代表フロー選定用、7章）
│   └─ cross_layer_impacts.csv  影響メモの集約結果（5章）
├─ _units/<単位ID>.txt      … 各調査単位の対象ファイル一覧
├─ _units/vertical-<フロー名>.txt / -hints.md … 縦調査の対象ファイルとヒント（7章）
├─ results/                 … Codex が書く調査結果
└─ summary/                 … 集約結果
```

---

## 2. 調査単位の考え方

### 2.1 区切り方：レイヤで機械分類し、パス順に行数上限まで詰めて区切る
1. **レイヤ**：パスやパッケージ名のパターンで分類します（flow / common / view / js / action / service / dao / config / other）。
2. **区切り**：レイヤごとにファイルをパス順に並べ、合計行数が上限（初期値 2,500 行）に達したところで区切ります。

例えば `action-001`、`action-002`、`view-001` のような単位ができます。パス順に詰めるため、同じフォルダ（パッケージ）のファイルは自然に同じ単位に入りやすくなります。

業務機能による分類は行いません。1つのクラスに複数の業務ロジックが混在している構成では、機能の境界をルール化すること自体に人手がかかるためです。機能ごとの視点は、7章の縦調査（flow定義からの機械抽出）で補います。

1ファイルだけで上限を超える巨大クラスは、単独の単位になり `OverLimit` が True になります。このようなクラスは、依頼文で「メソッド一覧を先に作成し、その後メソッド群ごとに分けて調査する」よう指示するか、上限を引き上げて個別に扱います。

行数上限はトークン量の目安です。Java は 1 行あたり約 10 トークン前後なので、2,500 行で 2.5 万トークン程度になります。Codex は読み込みに加えて推論と出力にもトークンを使うため、余裕を持たせた値にしています。パイロットの結果を見て調整してください。

### 2.2 共通基盤・ユーティリティは独立したレイヤとして最初に調査する
共通基盤（独自フレームワークの基底クラスなど）は、多くの単位から参照されます。各単位の調査でそれぞれ共通基盤を読ませると、同じソースを何度も読み込むことになり、トークンを浪費します。また、単位ごとに解釈がぶれる原因にもなります。

そこで、次の順に進めます。
1. `common` レイヤを最初に調査します。
2. その結果を `results/common-summary.md` に要約します。内容は、クラスごとの役割、使っている Spring/SWF の機能、業務側に提供している API です。
3. 以降の単位では、共通基盤のソースではなくこの要約だけを参照させます。

ユーティリティのうち Spring に依存していないもの（段階数が空欄のもの）は、調査対象から自動的に外れます。

### 2.3 レイヤを跨ぐ影響は「キー付きの影響メモ」で記録し、最後に機械的に突合する
各単位の調査で、他レイヤへの影響を記録してもらい最後にまとめる方法は有効です。ただし、自由記述のままだと集約時に対応付けができません。そのため、次の2点を必須にします。

- **影響メモは表形式で書かせる**：列は「影響先レイヤ」「キー種別」「キー値」「内容」「確信度」です（6章のテンプレート参照）。
- **キー種別を固定する**：フローID、ビューパス、クラス名、URL/イベント名、セッション属性名、Bean名、メッセージキーのいずれかとします。

こうしておくと、`collect-impacts.ps1` で全結果の影響メモを1つのCSVにまとめられます。キー値で並べれば、例えば flow 側の「ビュー order/confirm.jsp で `_eventId_submit` を送信」と、view 側の「confirm.jsp の submit ボタン」が並ぶので、両側からの記述が対応しているか、片側にしか書かれていないかがすぐに分かります。

この方法には弱点があります。各単位からは「見えていない側」を推測で書くことになり、漏れが生じます。この漏れは 4 章のフェーズ4（縦調査）で補います。

---

## 3. フェーズ0：棚卸しスクリプト

### 3.1 実行手順
1. 下記スクリプトを `survey-inventory.ps1` として **UTF-8（BOM付き）** で保存します。PowerShell 5.1 では BOM がないと日本語が文字化けし、スクリプトが正しく動きません。
2. 冒頭の「設定」欄をプロジェクトに合わせて変更します。最低限、`$Root`、`$JavaSrc`、`$ClassesDir`、`$AppPackage` を設定してください。
3. プロジェクトをビルドし、class ファイルを用意します。
4. 次のコマンドで実行します。ファイル検索では `target`、`build`、`bin`、`.git` などのフォルダには一切入りません（`$ExcludeDirNames` で変更可）。`target\classes` は jdeps の解析にのみ使用します。

```powershell
powershell -ExecutionPolicy Bypass -File .\survey-inventory.ps1
```

**独自フレームワークが別 jar の場合**：`$ExtraJars` にその jar のパスを指定してください。指定しないと、「業務クラス → 独自FW → Spring」の経路が途中で切れ、間接参照を検出できません。

### 3.2 スクリプト

```powershell
<#
  survey-inventory.ps1
  SWF / Spring 依存の棚卸し（調査フェーズ0）
  - PowerShell 5.1 / 7 で動作
  - PowerShell 5.1 で日本語を正しく扱うため、このファイルは UTF-8 (BOM付き) で保存すること
  実行例: powershell -ExecutionPolicy Bypass -File .\survey-inventory.ps1
#>

# ===================== 設定（プロジェクトに合わせて変更） =====================
$Root       = 'C:\work\project'          # プロジェクトルート
$JavaSrc    = 'src\main\java'            # Javaソースルート（$Root からの相対パス）
$ClassesDir = 'target\classes'           # コンパイル済み class（$Root からの相対パス）※jdeps専用。ファイル検索からは除外される
$ExtraJars  = @()                        # 自社フレームワーク等のjar（ソースが別管理の場合） 例: @('C:\work\lib\myfw.jar')
$AppPackage = 'com.example.app'          # 自社コードのパッケージ接頭辞
$MaxLines   = 2500                       # 1調査単位あたりの行数上限（パイロット後に調整）
$Extensions = '.java','.xml','.jsp','.jspf','.tag','.tld','.properties','.js'
# 検索から除外するフォルダ名（この名前のフォルダ配下には一切入らない）
$ExcludeDirNames = 'target','build','bin','.git','.svn','.settings','node_modules'

# 依存の有無にかかわらず必ず調査対象に含めるレイヤ
$AlwaysIncludeLayers = 'flow','view','js','config'

# レイヤ分類ルール：上から順に評価し、最初にマッチしたものを採用（パスは先頭に \ を付けて評価）
$LayerRules = [ordered]@{
  'flow'    = '\\WEB-INF\\flows\\|-flow\.xml$'
  'common'  = '\\(common|util|utils|base|framework|core)\\'
  'view'    = '\.(jsp|jspf|tag|tld)$'
  'js'      = '\.js$'
  'action'  = '\\(action|actions|controller|web)\\'
  'service' = '\\(service|logic|biz)\\'
  'dao'     = '\\(dao|repository|mapper)\\'
  'config'  = '\.(xml|properties)$'
  'other'   = '.'
}

# 調査順序（小さいほど先に調査）
$LayerOrder = @{ common=1; config=2; flow=3; action=4; view=5; js=6; service=7; dao=8; other=9 }

# 直接参照として検出するキーワード（正規表現）
$Keywords = @(
  'springframework','webflow',
  'flowScope','conversationScope','flashScope','viewScope','flowExecutionUrl','flowExecutionKey','_eventId',
  '<form:','<spring:',
  '@Autowired','@Resource','@Transactional','@Controller','@Service','@Repository','@Component','@Value',
  'MessageSource','JdbcTemplate','DispatcherServlet','ContextLoaderListener','DelegatingFilterProxy'
) -join '|'
# ==============================================================================

$SurveyDir = Join-Path $Root 'docs\survey'
$InvDir    = Join-Path $SurveyDir '_inventory'
$UnitDir   = Join-Path $SurveyDir '_units'
$ResultDir = Join-Path $SurveyDir 'results'
foreach ($d in $InvDir, $UnitDir, $ResultDir) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$RootTrim = $Root.TrimEnd('\')
function Get-Rel([string]$p) { $p.Substring($RootTrim.Length + 1) }

# 除外フォルダには入らずにファイルを列挙する（target 等の巨大フォルダを走査しないため高速）
function Get-SourceFiles([string]$dir) {
  foreach ($item in Get-ChildItem -LiteralPath $dir) {
    if ($item.PSIsContainer) {
      if ($ExcludeDirNames -contains $item.Name) { continue }
      if ($item.FullName -eq $SurveyDir) { continue }
      Get-SourceFiles $item.FullName
    } elseif ($Extensions -contains $item.Extension) {
      $item
    }
  }
}

# ---------- Step 1: ファイル一覧とレイヤの機械分類 ----------
Write-Host 'Step 1: ファイル一覧を作成中...'
$files = @(Get-SourceFiles $RootTrim)

$javaPrefix = $JavaSrc.TrimEnd('\') + '\'
$inventory = @(foreach ($f in $files) {
  $rel = Get-Rel $f.FullName
  $relForMatch = '\' + $rel

  $layer = 'other'
  foreach ($k in $LayerRules.Keys) { if ($relForMatch -match $LayerRules[$k]) { $layer = $k; break } }

  $fqcn = ''
  if ($f.Extension -eq '.java' -and $rel.StartsWith($javaPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    $fqcn = ($rel.Substring($javaPrefix.Length) -replace '\.java$', '') -replace '\\', '.'
  }

  [pscustomobject]@{
    Path       = $rel
    Ext        = $f.Extension
    Layer      = $layer
    Dir        = (Split-Path $rel -Parent)
    Fqcn       = $fqcn
    Lines      = [System.IO.File]::ReadAllLines($f.FullName).Length
    DirectRefs = 0
    Depth      = $null
  }
})

# ---------- Step 2: キーワードによる直接参照の検出（リソースファイル含む） ----------
Write-Host 'Step 2: 直接参照を検索中...'
$direct = @($files | Select-String -Pattern $Keywords -AllMatches | ForEach-Object {
  foreach ($m in $_.Matches) {
    [pscustomobject]@{ Path = (Get-Rel $_.Path); Line = $_.LineNumber; Keyword = $m.Value; Text = $_.Line.Trim() }
  }
})
$direct | Export-Csv (Join-Path $InvDir 'direct_refs.csv') -Encoding UTF8 -NoTypeInformation

# ---------- Step 3: XMLからのクラス参照・リフレクションの検出 ----------
Write-Host 'Step 3: XML参照・リフレクションを検索中...'
$xmlRefs = @($files | Where-Object { $_.Extension -eq '.xml' } |
  Select-String -Pattern 'class="([^"]+)"|<(?:servlet|filter|listener)-class>\s*([^<\s]+)' -AllMatches |
  ForEach-Object {
    foreach ($m in $_.Matches) {
      $cls = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
      [pscustomobject]@{ Path = (Get-Rel $_.Path); Line = $_.LineNumber; Class = $cls }
    }
  })
$xmlRefs | Export-Csv (Join-Path $InvDir 'xml_class_refs.csv') -Encoding UTF8 -NoTypeInformation

$reflect = @($files | Where-Object { $_.Extension -eq '.java' } |
  Select-String -Pattern 'Class\.forName|getBean\(|\.newInstance\(|loadClass\(' |
  ForEach-Object { [pscustomobject]@{ Path = (Get-Rel $_.Path); Line = $_.LineNumber; Text = $_.Line.Trim() } })
$reflect | Export-Csv (Join-Path $InvDir 'reflection_refs.csv') -Encoding UTF8 -NoTypeInformation

# ---------- Step 4: jdeps による間接参照（段階数つき） ----------
Write-Host 'Step 4: jdeps で依存関係を解析中...'
$depth = @{}
$via   = @{}
$classesPath = Join-Path $Root $ClassesDir
if (-not (Test-Path $classesPath)) {
  Write-Warning "コンパイル済みクラスが見つかりません: $classesPath （ビルド後に再実行してください。間接参照の解析をスキップします）"
} else {
  $jdepsOut = Join-Path $InvDir 'jdeps_raw.txt'
  & jdeps -verbose:class $classesPath @ExtraJars | Out-File $jdepsOut -Encoding UTF8

  $deps = @(Get-Content $jdepsOut | ForEach-Object {
    if ($_ -match '^\s+(\S+)\s+->\s+(\S+)') {
      $from = $Matches[1] -replace '\$.*$', ''
      $to   = $Matches[2] -replace '\$.*$', ''
      if ($from -ne $to) { [pscustomobject]@{ From = $from; To = $to } }
    }
  })

  # 逆引き表（依存先 -> 依存元の一覧）
  $rev = @{}
  foreach ($d in $deps) {
    if (-not $rev.ContainsKey($d.To)) { $rev[$d.To] = New-Object System.Collections.Generic.List[string] }
    $rev[$d.To].Add($d.From)
  }

  $queue = New-Object System.Collections.Generic.Queue[string]
  # 起点1: Spring を直接参照するクラス
  foreach ($d in $deps) {
    if ($d.To -like 'org.springframework*' -and -not $depth.ContainsKey($d.From)) {
      $depth[$d.From] = 0; $via[$d.From] = $d.To; $queue.Enqueue($d.From)
    }
  }
  # 起点2: XMLでbean等として定義されている自社クラス（importなしでSpring管理下にあるもの）
  foreach ($x in $xmlRefs) {
    if ($x.Class -like "$AppPackage*" -and -not $depth.ContainsKey($x.Class)) {
      $depth[$x.Class] = 0; $via[$x.Class] = 'xml:' + $x.Path; $queue.Enqueue($x.Class)
    }
  }
  # 幅優先で依存元をたどり、Springからの段階数を記録
  while ($queue.Count -gt 0) {
    $c = $queue.Dequeue()
    if ($rev.ContainsKey($c)) {
      foreach ($p in $rev[$c]) {
        if (-not $depth.ContainsKey($p)) { $depth[$p] = $depth[$c] + 1; $via[$p] = $c; $queue.Enqueue($p) }
      }
    }
  }

  $depth.GetEnumerator() |
    ForEach-Object { [pscustomobject]@{ Class = $_.Key; Depth = $_.Value; Via = $via[$_.Key] } } |
    Sort-Object Depth, Class |
    Export-Csv (Join-Path $InvDir 'spring_dependents.csv') -Encoding UTF8 -NoTypeInformation
}

# ---------- Step 5: 一覧への反映と調査単位の作成 ----------
Write-Host 'Step 5: 調査単位を作成中...'
$directCount = @{}
foreach ($g in ($direct | Group-Object Path)) { $directCount[$g.Name] = $g.Count }

foreach ($i in $inventory) {
  if ($directCount.ContainsKey($i.Path)) { $i.DirectRefs = $directCount[$i.Path] }
  if ($i.Fqcn -and $depth.ContainsKey($i.Fqcn)) { $i.Depth = $depth[$i.Fqcn] }
  elseif ($i.DirectRefs -gt 0)                  { $i.Depth = 0 }
}
$inventory | Export-Csv (Join-Path $InvDir 'inventory.csv') -Encoding UTF8 -NoTypeInformation

$targets = @($inventory | Where-Object { $null -ne $_.Depth -or $AlwaysIncludeLayers -contains $_.Layer })

function New-Unit($layer, $seq, $unitFiles) {
  $depths = @($unitFiles | Where-Object { $null -ne $_.Depth } | ForEach-Object { [int]$_.Depth })
  $lines  = ($unitFiles | Measure-Object -Property Lines -Sum).Sum
  [pscustomobject]@{
    UnitId    = '{0}-{1:000}' -f $layer, $seq
    Order     = $LayerOrder[$layer]
    Layer     = $layer
    Files     = $unitFiles.Count
    FirstDir  = $unitFiles[0].Dir
    Dirs      = @($unitFiles | ForEach-Object { $_.Dir } | Sort-Object -Unique).Count
    Lines     = $lines
    MinDepth  = $(if ($depths.Count) { ($depths | Measure-Object -Minimum).Minimum } else { '' })
    OverLimit = ($lines -gt $MaxLines)
    PathList  = @($unitFiles | ForEach-Object { $_.Path })
  }
}

# レイヤごとにパス順で並べ、行数上限まで詰めて区切る（同じフォルダのファイルが同じ単位に入りやすい）
$units = New-Object System.Collections.Generic.List[object]
foreach ($g in ($targets | Group-Object Layer)) {
  $layer = $g.Name
  $seq = 1; $acc = 0
  $buf = New-Object System.Collections.Generic.List[object]
  foreach ($f in ($g.Group | Sort-Object Path)) {
    if ($acc + $f.Lines -gt $MaxLines -and $buf.Count -gt 0) {
      $units.Add((New-Unit $layer $seq $buf.ToArray()))
      $seq++; $acc = 0; $buf.Clear()
    }
    $buf.Add($f); $acc += $f.Lines
  }
  if ($buf.Count -gt 0) { $units.Add((New-Unit $layer $seq $buf.ToArray())) }
}
$units = @($units | Sort-Object Order, UnitId)

# 調査単位ごとの対象ファイル一覧（Codexに読ませる範囲）
foreach ($u in $units) { $u.PathList | Out-File (Join-Path $UnitDir ($u.UnitId + '.txt')) -Encoding UTF8 }

$units | Select-Object UnitId, Order, Layer, Files, Lines, MinDepth, OverLimit, Dirs, FirstDir |
  Export-Csv (Join-Path $InvDir 'units.csv') -Encoding UTF8 -NoTypeInformation

# 進捗管理用チェックリスト
$md = @('# 調査チェックリスト', '',
        '| 状態 | 調査単位 | レイヤ | ファイル数 | 行数 | 最小段階 | 先頭フォルダ | 結果ファイル |',
        '|---|---|---|---|---|---|---|---|')
foreach ($u in $units) {
  $md += ('| 未着手 | {0} | {1} | {2} | {3} | {4} | {5} | results/{0}.md |' -f $u.UnitId, $u.Layer, $u.Files, $u.Lines, $u.MinDepth, $u.FirstDir)
}
$md | Out-File (Join-Path $SurveyDir 'survey-checklist.md') -Encoding UTF8

Write-Host ('完了: 全ファイル {0} / 調査対象 {1} / 調査単位 {2}（上限超過 {3}）' -f `
  $inventory.Count, $targets.Count, $units.Count, @($units | Where-Object OverLimit).Count)
```

### 3.3 実行後に人が確認すること（ここが一番重要）
分類ルールは汎用的な初期値なので、一度でプロジェクトに合うことはまずありません。次の観点で `inventory.csv` を Excel 等で開いて確認し、ルールを直して再実行します。

- `Layer` が `other` のファイルが多くないか。多い場合は `$LayerRules` を追加・修正します。`Dir` 列でフィルタすると、どのフォルダがどのレイヤに分類されたかを確認しやすくなります。
- 除外すべきフォルダ（生成物、バックアップ、旧版ソースなど）が含まれていないか。あれば `$ExcludeDirNames` に追加します。
- 共通 JSP（ヘッダー等）が `common` に入っているか。意図と違う場合はルールの順序を調整します。
- `units.csv` で `OverLimit` が True の単位がないか。これは単独ファイルが上限を超えるケースです。巨大クラスは個別に扱うか、上限を引き上げます。
- `spring_dependents.csv` で段階数が大きくなっている経路。`Via` 列をたどると、どの基底クラスを経由して依存が広がっているかが分かります。段階 1 以上のクラスが大量にある場合、共通基盤の置き換えだけで済む可能性があります。
- `reflection_refs.csv` の内容。文字列でクラス名を指定している箇所は、jdeps では検出できないため目視で確認します。

補足：Shift-JIS のファイルでは、CSV の `Text` 列の日本語が文字化けすることがあります。検出自体は英字キーワードで行っているため、結果には影響しません。PowerShell 7 で Excel から開く場合は、`-Encoding UTF8` を `-Encoding utf8BOM` に変えると文字化けしません。

---

## 4. Codex CLI の設定（AGENTS.md）

Codex CLI はリポジトリ直下の `AGENTS.md` を毎回読み込みます。ここに共通ルールを書いておくと、依頼文が短くなり、読み込み範囲も抑えられます。

```markdown
# AGENTS.md

## 現在のフェーズ：調査（コード変更禁止）
- ソースコード・設定ファイルを変更してはならない。
- 書き込んでよいのは docs/survey/results/ と docs/survey/summary/ 配下のみ。
- 依頼で指定された一覧ファイル（docs/survey/_units/<調査単位ID>.txt）に記載されたファイル以外は開かない。
  - 他のファイルの内容が必要と思われる場合は、開かずに「要確認事項」に記録する。
  - 例外として docs/survey/results/common-summary.md と docs/survey/TEMPLATE.md は参照してよい。
- 出力は docs/survey/TEMPLATE.md の形式に従い、日本語で記述する。
- ソースコードの引用は1箇所10行以内とし、ファイルパスと行番号で位置を示す。
- 推測を含む記述には確信度（高/中/低）を付ける。

## 背景
- Spring Web Flow（SWF）および Spring Framework 等の機能を、Java標準（Servlet API 等）での独自実装に置き換える。
- 置き換え対象の例：
  - フロー定義による画面遷移、view-state / action-state / subflow
  - flow / conversation / flash / view スコープ
  - スナップショットによるブラウザバック・二重送信制御、POST後リダイレクト
  - データバインディング、バリデーション、Spring フォームタグ
  - DI、トランザクション管理、AOP、MessageSource、JdbcTemplate
```

---

## 5. フェーズ1〜3：単位別の調査

### 5.1 実行の基本
- **1単位につき1セッション**にします。単位ごとに Codex を起動し直すと、前の単位の内容がコンテキストに残らず、トークンを節約できます。
- **書き込み可能な範囲を限定**して実行します。調査結果を書き出すため、完全な読み取り専用ではなく、作業ディレクトリ内のみ書き込み可のモードを使います。
- **毎回 `git status` を確認**し、`docs/survey` 以外に変更がないことを確かめます。
- 単位が終わったら、`survey-checklist.md` の状態を「完了」に更新します。

非対話で実行する場合の例です（オプション名はバージョンにより異なることがあるため、`codex --help` で確認してください）。

```powershell
codex exec --sandbox workspace-write "調査単位 action-001 を調査してください。（以下、5.3の依頼文）"
```

### 5.2 フェーズ1：パイロット
小さめの単位（例：ファイル数の少ない flow 単位）を1つ選んで試し、次の点を確認します。

- 指定したファイル以外を開いていないか（Codex の実行ログで確認）
- トークン上限に達せずに完了したか。余裕があるようなら `$MaxLines` を引き上げます。
- 出力の粒度は、集約に使える程度に揃っているか。足りない項目や不要な項目があれば `TEMPLATE.md` を修正します。
- 確信度「低」の記述が多すぎないか。多い場合は単位が小さすぎて文脈が足りない可能性があります。

### 5.3 依頼文テンプレート

**共通基盤（common レイヤ）用**

```
調査単位 {単位ID} を調査してください。
対象ファイル: docs/survey/_units/{単位ID}.txt に記載されたファイルのみ
出力先: docs/survey/results/{単位ID}.md（TEMPLATE.md の形式）

観点:
1. 各クラスの役割と、利用している Spring/SWF の機能
2. 業務クラスに提供している機能・API（継承されるメソッド、ユーティリティメソッド等）
3. Java標準で置き換える場合の方針案と難易度
4. 他レイヤへの影響（キー種別とキー値を必ず記載）

最後に、docs/survey/results/common-summary.md に、このクラス群の要約
（クラス名／役割／利用しているSpring機能／業務側に提供しているAPI）を1クラス3行以内で追記してください。
```

**通常の単位用**

```
調査単位 {単位ID} を調査してください。
対象ファイル: docs/survey/_units/{単位ID}.txt に記載されたファイルのみ
共通基盤の情報: docs/survey/results/common-summary.md を参照（共通基盤のソースは開かない）
出力先: docs/survey/results/{単位ID}.md（TEMPLATE.md の形式）

観点:
1. 使用している Spring/SWF の機能（直接の利用、および共通基盤を経由した間接的な利用）
2. Java標準で置き換える場合の方針案と難易度
3. 他レイヤ・他単位への影響（キー種別とキー値を必ず記載）
4. 判断できなかった点
```

---

## 6. 調査結果テンプレート（TEMPLATE.md）

`docs/survey/TEMPLATE.md` として保存します。見出しの文言は集約スクリプトが参照するため、変更しないでください。

```markdown
# 調査結果：{単位ID}

## 概要
（この単位の役割を2〜3行で）

## 利用しているフレームワーク機能
| No | ファイル:行 | 機能分類 | 利用内容 | 直接/間接 |
|---|---|---|---|---|

機能分類は次から選ぶ：画面遷移 / スコープ管理 / 戻る・二重送信制御 / バインディング / バリデーション / タグライブラリ / DI / トランザクション / AOP / メッセージ / DBアクセス / 例外処理 / 設定 / その他

## 置き換え方針案
| No | 対象（上表のNo） | Java標準での代替案 | 共通基盤化の要否 | 難易度(高/中/低) |
|---|---|---|---|---|

## 他レイヤへの影響
| 影響ID | 影響先レイヤ | キー種別 | キー値 | 内容 | 確信度 |
|---|---|---|---|---|---|

キー種別は次から選ぶ：フローID / ビューパス / クラス名 / URL・イベント名 / セッション属性名 / Bean名 / メッセージキー
影響IDは「{単位ID}-X01」の形式で連番とする。

## 要確認事項
（指定範囲外のため確認できなかった点、判断に迷った点）
```

---

## 7. フェーズ4：代表フローの縦調査

単位別の調査はレイヤごとに区切っているため、SWF が暗黙的に提供している挙動や、レイヤを跨ぐ関係を見落としやすくなります。これを補うため、代表的なフローを選び、flow 定義を起点に関連ファイルを機械的に抽出して、横断的に追います。

### 7.1 抽出の考え方
flow 定義 XML には、そのフローが使う画面・クラス・サブフローがすべて名前で書かれています。そこで、flow 定義を起点に次の参照をたどれば、人がファイルを選ばなくても対象を抽出できます。

| 起点 | たどる参照 | 解決先 |
|---|---|---|
| flow定義 | `parent`、`subflow` | 親フロー・サブフローの定義（再帰的にたどる） |
| flow定義 | `view="..."` | JSP（flow と同じフォルダ、またはビューのフォルダ） |
| flow定義 | `expression` / `test` 内の `bean名.メソッド名` | Spring XML の bean 定義、またはアノテーションからクラスを特定 |
| flow定義 | `<var class="...">`、`<bean-import>` | フォーム等のクラス、flow 専用の bean 定義 |
| Javaクラス | jdeps の依存（自社クラスのみ） | service / dao 等。追跡段数は `-JavaDepth` で指定 |
| JSP | `include`、`jsp:include`、`<script src>` | インクルード JSP、JS ファイル |

共通レイヤのファイルは抽出から除外し、`common-summary.md` で代替します。

1つのクラスに複数の業務ロジックがある場合、クラス単位で抽出すると、このフローと関係のないコードまで含まれます。そのためスクリプトは、flow から実際に呼ばれている `bean.メソッド` の一覧を「ヒント」として出力します。Codex には、そのメソッドと呼び出し先だけを読むよう指示します。

### 7.2 手順
1. フロー一覧と規模を出力し、代表フローを選びます。

```powershell
powershell -ExecutionPolicy Bypass -File .\extract-flow-files.ps1
```

`_inventory/flow_stats.csv` には、フローごとに view-state、subflow、evaluate、transition の数が出力されます。次のようなフローを1〜2本選びます。
- subflow を含むもの
- view-state が多く、入力→確認→完了のような遷移があるもの
- ファイルアップロードなど特殊な処理を含むもの（これは名前から人が判断）

2. 選んだフローの関連ファイルを抽出します。

```powershell
powershell -ExecutionPolicy Bypass -File .\extract-flow-files.ps1 -Flow 'src\main\webapp\WEB-INF\flows\order\order-flow.xml'
```

3. 出力された `_units/vertical-<フロー名>-hints.md` を確認します。
- **合計行数**：上限を大きく超える場合は `-JavaDepth 0`（flow から直接呼ばれるクラスのみ）で再実行します。
- **解決できなかった参照**：view 名の規則が `$ViewCandidates` と合っていない場合や、bean 名を特定できなかった場合に出ます。件数が多ければ設定を直して再実行し、少数なら手作業で `.txt` に追記します。

### 7.3 スクリプト（extract-flow-files.ps1）
冒頭の設定欄は `survey-inventory.ps1` と揃えてください。`$ViewCandidates` は、プロジェクトのビュー解決の規則（ViewResolver の prefix/suffix 等）に合わせて調整します。

```powershell
<#
  extract-flow-files.ps1
  代表フローの縦調査用に、flow定義を起点として関連ファイルを機械的に抽出する
  前提: survey-inventory.ps1 を実行済みであること（inventory.csv / jdeps_raw.txt を使用）
  UTF-8 (BOM付き) で保存すること

  使い方:
    フロー一覧と規模の統計を出す（代表フローの選定用）
      powershell -ExecutionPolicy Bypass -File .\extract-flow-files.ps1
    特定フローの関連ファイルを抽出する
      powershell -ExecutionPolicy Bypass -File .\extract-flow-files.ps1 -Flow 'src\main\webapp\WEB-INF\flows\order\order-flow.xml'
#>
param(
  [string]$Flow = '',     # 起点とするflow定義XML（$Root からの相対パス）
  [int]$JavaDepth = 1     # flowから呼ばれるクラスから、さらに何段先の自社クラスまで含めるか
)

# ===================== 設定（survey-inventory.ps1 と揃える） =====================
$Root       = 'C:\work\project'
$WebRoot    = 'src\main\webapp'          # Webコンテンツのルート（$Root からの相対パス）
$AppPackage = 'com.example.app'
$MaxLines   = 2500
$SkipLayers = @('common')                # 抽出から除外するレイヤ（common-summary.md で代替）

# view属性の値からJSPを探す候補（上から順に存在確認）
#   {flowDir}=flow定義のフォルダ、{webRoot}=$WebRoot、{view}=view属性の値
$ViewCandidates = @(
  '{flowDir}\{view}.jsp'
  '{flowDir}\{view}'
  '{webRoot}\WEB-INF\views\{view}.jsp'
  '{webRoot}\WEB-INF\jsp\{view}.jsp'
  '{webRoot}\{view}'
)

# 式の中でbean名として扱わない名前（SWFの予約語）
$Reserved = @('flowScope','viewScope','requestScope','flashScope','conversationScope','flowRequestContext',
  'flowExecutionContext','externalContext','requestParameters','currentEvent','messageContext',
  'resourceBundle','currentUser','flowExecutionUrl','currentState','this','null','true','false')
# ==============================================================================

$Flow        = $Flow -replace '/', '\'
$RootTrim    = $Root.TrimEnd('\')
$WebRootFull = Join-Path $RootTrim $WebRoot
$InvDir      = Join-Path $RootTrim 'docs\survey\_inventory'
$UnitDir     = Join-Path $RootTrim 'docs\survey\_units'

$inv = @(Import-Csv (Join-Path $InvDir 'inventory.csv'))
$byPath = @{}; $byFqcn = @{}
foreach ($i in $inv) { $byPath[$i.Path] = $i; if ($i.Fqcn) { $byFqcn[$i.Fqcn] = $i } }

function Get-Rel([string]$full) { $full.Substring($RootTrim.Length + 1) }
function Read-Text([string]$rel) { [System.IO.File]::ReadAllText((Join-Path $RootTrim $rel)) }

# ---------- flow ID とファイルの対応表 ----------
$flowFiles = @($inv | Where-Object { $_.Layer -eq 'flow' -and $_.Ext -eq '.xml' })
$flowById = @{}
foreach ($f in $flowFiles) {
  $ids = @(
    ([System.IO.Path]::GetFileNameWithoutExtension($f.Path) -replace '-flow$', '')
    (Split-Path (Split-Path $f.Path -Parent) -Leaf)
  )
  if ($f.Path -match '\\flows\\(.+)\\[^\\]+$') { $ids += ($Matches[1] -replace '\\', '/') }
  foreach ($id in $ids) { if ($id -and -not $flowById.ContainsKey($id)) { $flowById[$id] = $f.Path } }
}

# ---------- モード1: フロー一覧と規模の統計 ----------
if (-not $Flow) {
  $stats = foreach ($f in $flowFiles) {
    $t = Read-Text $f.Path
    [pscustomobject]@{
      Path           = $f.Path
      Lines          = [int]$f.Lines
      ViewStates     = [regex]::Matches($t, '<view-state\b').Count
      ActionStates   = [regex]::Matches($t, '<action-state\b').Count
      DecisionStates = [regex]::Matches($t, '<decision-state\b').Count
      SubflowStates  = [regex]::Matches($t, '<subflow-state\b').Count
      Evaluates      = [regex]::Matches($t, '<evaluate\b').Count
      Transitions    = [regex]::Matches($t, '<transition\b').Count
    }
  }
  $out = Join-Path $InvDir 'flow_stats.csv'
  $stats | Sort-Object SubflowStates, ViewStates, Transitions -Descending |
    Export-Csv $out -Encoding UTF8 -NoTypeInformation
  Write-Host "フロー一覧を出力しました: $out"
  return
}

if (-not $byPath.ContainsKey($Flow)) { Write-Error "inventory.csv に見つかりません: $Flow"; return }

# ---------- bean名 → クラス の対応表（XML定義＋アノテーション） ----------
$beanClass = @{}
foreach ($x in ($inv | Where-Object { $_.Ext -eq '.xml' })) {
  foreach ($m in [regex]::Matches((Read-Text $x.Path), '<bean\b([^>]*)>')) {
    $attr = $m.Groups[1].Value
    if ($attr -match '\bclass="([^"]+)"') {
      $cls = $Matches[1]
      if ($attr -match '\bid="([^"]+)"') { $beanClass[$Matches[1]] = $cls }
      if ($attr -match '\bname="([^"]+)"') { foreach ($n in ($Matches[1] -split '[,;\s]+')) { if ($n) { $beanClass[$n] = $cls } } }
    }
  }
}
foreach ($j in ($inv | Where-Object { $_.Ext -eq '.java' -and $_.Fqcn })) {
  if ((Read-Text $j.Path) -match '@(?:Component|Service|Controller|Repository)\b(?:\s*\(\s*(?:value\s*=\s*)?"([^"]+)")?') {
    if ($Matches[1]) { $name = $Matches[1] }
    else { $s = [System.IO.Path]::GetFileNameWithoutExtension($j.Path); $name = $s.Substring(0, 1).ToLower() + $s.Substring(1) }
    if (-not $beanClass.ContainsKey($name)) { $beanClass[$name] = $j.Fqcn }
  }
}

# ---------- jdeps の依存関係（自社クラスへの依存のみ） ----------
$fwd = @{}
$jdepsRaw = Join-Path $InvDir 'jdeps_raw.txt'
if (Test-Path $jdepsRaw) {
  foreach ($line in Get-Content $jdepsRaw) {
    if ($line -match '^\s+(\S+)\s+->\s+(\S+)') {
      $from = $Matches[1] -replace '\$.*$', ''
      $to   = $Matches[2] -replace '\$.*$', ''
      if ($from -ne $to -and $to -like "$AppPackage*") {
        if (-not $fwd.ContainsKey($from)) { $fwd[$from] = New-Object System.Collections.Generic.HashSet[string] }
        [void]$fwd[$from].Add($to)
      }
    }
  }
} else {
  Write-Warning 'jdeps_raw.txt がないため、Javaクラスの依存はたどりません'
}

# ---------- 抽出処理 ----------
$ic = [System.StringComparer]::OrdinalIgnoreCase
$selected    = New-Object 'System.Collections.Generic.HashSet[string]' $ic
$skipped     = New-Object 'System.Collections.Generic.HashSet[string]' $ic
$unresolved  = New-Object System.Collections.Generic.List[string]
$methodHints = New-Object System.Collections.Generic.List[string]
$events      = New-Object System.Collections.Generic.HashSet[string]
$flowsDone   = New-Object System.Collections.Generic.List[string]
$startClass  = New-Object System.Collections.Generic.HashSet[string]

# 抽出対象に追加（新規追加ならTrue。除外レイヤのファイルは記録のみ）
function Add-File([string]$rel) {
  if (-not $rel) { return $false }
  $item = $byPath[$rel]
  if ($item -and $SkipLayers -contains $item.Layer) { [void]$skipped.Add($rel); return $false }
  return $selected.Add($rel)
}

# JSP等に書かれたパスを実ファイルに解決
function Resolve-WebPath([string]$ref, [string]$baseRel) {
  $r = $ref -replace '\$\{[^}]*\}', '' -replace '<%=[^%]*%>', '' -replace '[?#].*$', ''
  if (-not $r -or $r -match '^(https?:)?//') { return $null }
  if ($r.StartsWith('/')) { $cand = Join-Path $WebRootFull ($r.TrimStart('/') -replace '/', '\') }
  else { $cand = Join-Path (Split-Path (Join-Path $RootTrim $baseRel) -Parent) ($r -replace '/', '\') }
  $full = [System.IO.Path]::GetFullPath($cand)
  if (Test-Path -LiteralPath $full -PathType Leaf) { return Get-Rel $full }
  return $null
}

# view属性の値をJSPファイルに解決
function Resolve-View([string]$view, [string]$flowRel) {
  $flowDir = Split-Path (Join-Path $RootTrim $flowRel) -Parent
  $v = $view.TrimStart('/') -replace '/', '\'
  foreach ($c in $ViewCandidates) {
    $p = $c.Replace('{flowDir}', $flowDir).Replace('{webRoot}', $WebRootFull).Replace('{view}', $v)
    if (Test-Path -LiteralPath $p -PathType Leaf) { return Get-Rel ([System.IO.Path]::GetFullPath($p)) }
  }
  return $null
}

# (1) flow定義：親フロー・サブフローもたどる
$jspQueue  = New-Object System.Collections.Generic.Queue[string]
$flowQueue = New-Object System.Collections.Generic.Queue[string]
$flowQueue.Enqueue($Flow)
while ($flowQueue.Count -gt 0) {
  $fr = $flowQueue.Dequeue()
  if ($flowsDone.Contains($fr)) { continue }
  $flowsDone.Add($fr)
  [void](Add-File $fr)
  $t = Read-Text $fr

  # フロー変数・入力パラメータ名（bean名と誤認しないよう除外リストへ）
  $localNames = @($Reserved)
  foreach ($m in [regex]::Matches($t, '<(?:var|input)\b[^>]*\bname="([^"]+)"')) { $localNames += $m.Groups[1].Value }

  # 親フロー・サブフロー
  $refIds = @()
  if ($t -match '<flow\b[^>]*\bparent="([^"]+)"') { $refIds += ($Matches[1] -split '\s*,\s*') }
  foreach ($m in [regex]::Matches($t, '\bsubflow="([^"]+)"')) { $refIds += $m.Groups[1].Value }
  foreach ($id in $refIds) {
    if ($flowById.ContainsKey($id)) { $flowQueue.Enqueue($flowById[$id]) } else { $unresolved.Add("flow: $id ($fr)") }
  }

  # flow専用のbean定義ファイル
  foreach ($m in [regex]::Matches($t, '<bean-import\s+resource="([^"]+)"')) {
    $r = Resolve-WebPath $m.Groups[1].Value $fr
    if ($r) { [void](Add-File $r) } else { $unresolved.Add("bean-import: $($m.Groups[1].Value) ($fr)") }
  }

  # 画面（view属性）
  foreach ($m in [regex]::Matches($t, '\bview="([^"]+)"')) {
    $v = $m.Groups[1].Value
    if ($v -match '^(externalRedirect|flowRedirect|contextRelative|serverRelative|https?):' -or $v -match '[#$]\{') { continue }
    $r = Resolve-View $v $fr
    if ($r) { if (Add-File $r) { $jspQueue.Enqueue($r) } } else { $unresolved.Add("view: $v ($fr)") }
  }

  # 呼び出しているbeanとメソッド
  foreach ($m in [regex]::Matches($t, '\b(?:expression|test|result)="[#$]?\{?\s*([A-Za-z_]\w*)\.(\w+)')) {
    $bean = $m.Groups[1].Value; $method = $m.Groups[2].Value
    if ($localNames -contains $bean) { continue }
    if ($beanClass.ContainsKey($bean)) {
      $cls = $beanClass[$bean]
      [void]$startClass.Add($cls)
      $hint = "$bean.$method -> $cls"
      if (-not $methodHints.Contains($hint)) { $methodHints.Add($hint) }
    } else { $unresolved.Add("bean: $bean.$method ($fr)") }
  }

  # フロー変数のクラス
  foreach ($m in [regex]::Matches($t, '<var\b[^>]*\bclass="([^"]+)"')) { [void]$startClass.Add($m.Groups[1].Value) }

  # 遷移イベント
  foreach ($m in [regex]::Matches($t, '<transition\b[^>]*\bon="([^"]+)"')) { [void]$events.Add($m.Groups[1].Value) }
}

# (2) Javaクラス：flowから呼ばれるクラスを起点に、jdepsで $JavaDepth 段先までたどる
$classDepth = @{}
$cq = New-Object System.Collections.Generic.Queue[string]
foreach ($c in $startClass) { $classDepth[$c] = 0; $cq.Enqueue($c) }
while ($cq.Count -gt 0) {
  $c = $cq.Dequeue()
  $item = $byFqcn[$c]
  if (-not $item) { $unresolved.Add("class: $c (ソースなし/jar内)"); continue }
  [void](Add-File $item.Path)
  if ($SkipLayers -contains $item.Layer) { continue }    # 共通レイヤの先はたどらない
  if ($classDepth[$c] -ge $JavaDepth) { continue }
  if ($fwd.ContainsKey($c)) {
    foreach ($n in $fwd[$c]) {
      if (-not $classDepth.ContainsKey($n)) { $classDepth[$n] = $classDepth[$c] + 1; $cq.Enqueue($n) }
    }
  }
}

# (3) JSP：インクルードと読み込んでいるJSをたどる
while ($jspQueue.Count -gt 0) {
  $jr = $jspQueue.Dequeue()
  $t = Read-Text $jr
  $refs = @()
  foreach ($m in [regex]::Matches($t, '<%@\s*include\s+file="([^"]+)"')) { $refs += $m.Groups[1].Value }
  foreach ($m in [regex]::Matches($t, '<jsp:include\s+page="([^"]+)"')) { $refs += $m.Groups[1].Value }
  foreach ($m in [regex]::Matches($t, '<script\b[^>]*\bsrc="([^"]+)"')) { $refs += $m.Groups[1].Value }
  foreach ($m in [regex]::Matches($t, 'value=[''"](/[^''"]+\.js)[''"]')) { $refs += $m.Groups[1].Value }
  foreach ($r0 in $refs) {
    $r = Resolve-WebPath $r0 $jr
    if ($r) {
      if ((Add-File $r) -and $r -match '\.(jsp|jspf)$') { $jspQueue.Enqueue($r) }
    } elseif ($r0 -notmatch '^((https?:)?//|<)') {   # <c:url ...> 形式は value= 側で拾うため除外
      $unresolved.Add("web: $r0 ($jr)")
    }
  }
}

# ---------- 出力 ----------
$flowId = [System.IO.Path]::GetFileNameWithoutExtension($Flow) -replace '-flow$', ''
$unitId = "vertical-$flowId"
$list = @($selected | Sort-Object)
$list | Out-File (Join-Path $UnitDir "$unitId.txt") -Encoding UTF8

$total = 0
foreach ($p in $list) { if ($byPath[$p]) { $total += [int]$byPath[$p].Lines } }

$h = @(
  "# 縦調査ヒント: $unitId", '',
  "- 起点: $Flow",
  ('- 抽出ファイル数: {0} / 合計行数: {1}（上限目安 {2}）' -f $list.Count, $total, $MaxLines),
  "- Java依存の追跡段数: $JavaDepth", '',
  '## 対象フロー（親・サブフロー含む）') + @($flowsDone | ForEach-Object { "- $_" }) + @(
  '', '## flowから呼ばれているメソッド（bean.method -> クラス）') + @($methodHints | ForEach-Object { "- $_" }) + @(
  '', '## 遷移イベント') + @($events | Sort-Object | ForEach-Object { "- $_" }) + @(
  '', '## 除外した共通レイヤのファイル（common-summary.md を参照）') + @($skipped | Sort-Object | ForEach-Object { "- $_" }) + @(
  '', '## 解決できなかった参照（人による確認が必要）') + @($unresolved | Sort-Object -Unique | ForEach-Object { "- $_" })
$h | Out-File (Join-Path $UnitDir "$unitId-hints.md") -Encoding UTF8

Write-Host ('抽出完了: {0}  ファイル {1} 件 / {2} 行 / 未解決 {3} 件' -f $unitId, $list.Count, $total, @($unresolved | Sort-Object -Unique).Count)
if ($total -gt $MaxLines) {
  Write-Warning '合計行数が上限目安を超えています。-JavaDepth 0 で再実行するか、hints のメソッドに絞って読むよう依頼してください。'
}
```

### 7.4 依頼文テンプレート

```
縦調査 vertical-{フロー名} を行ってください。
対象ファイル: docs/survey/_units/vertical-{フロー名}.txt に記載されたファイルのみ
ヒント: docs/survey/_units/vertical-{フロー名}-hints.md
共通基盤の情報: docs/survey/results/common-summary.md を参照（共通基盤のソースは開かない）
出力先: docs/survey/results/vertical-{フロー名}.md（TEMPLATE.md の形式）

読み方:
- Javaクラスは、ヒントに記載されたメソッドと、そこから呼ばれるメソッドのみを読むこと（クラス全体は読まない）
- flow定義の状態遷移の順に、画面→処理→次画面と追うこと

重点観点:
1. 画面遷移の全体像（状態・イベント・遷移先の一覧）
2. スコープ（flow/conversation/flash/view）に保持しているデータと、その生成・破棄のタイミング
3. ブラウザバック、二重送信、リロード時の挙動（SWF が暗黙的に制御している部分）
4. POST後のリダイレクトの有無、エラー時・例外時の遷移先
5. サブフローとのデータの受け渡し（input/output）
```

### 7.5 単位別調査との照合
縦調査の結果と、同じフローに関係する影響メモ（`cross_layer_impacts.csv`）を突き合わせ、影響メモの漏れ方の傾向をつかみます。漏れの多い観点があれば、他のフローについても縦調査を追加することを検討します。

---

## 8. フェーズ5：集約と方針決定

### 8.1 影響メモの機械集約
次のスクリプトを `collect-impacts.ps1` として UTF-8（BOM付き）で保存し、実行します。

```powershell
<#
  collect-impacts.ps1
  各調査結果ファイルの「他レイヤへの影響」表を1つのCSVに集約する（集約フェーズ）
  UTF-8 (BOM付き) で保存すること
#>
$Root      = 'C:\work\project'
$ResultDir = Join-Path $Root 'docs\survey\results'
$OutCsv    = Join-Path $Root 'docs\survey\_inventory\cross_layer_impacts.csv'

$rows = @(foreach ($f in Get-ChildItem $ResultDir -Filter *.md) {
  $in = $false
  foreach ($line in [System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8)) {
    if ($line -match '^##\s*他レイヤへの影響') { $in = $true; continue }
    if ($in -and $line -match '^##\s') { break }
    if ($in -and $line -match '^\|' -and $line -notmatch '^\|\s*:?-' -and $line -notmatch '影響ID') {
      $c = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
      [pscustomobject]@{
        SourceUnit = $f.BaseName; Id = $c[0]; TargetLayer = $c[1]
        KeyType = $c[2]; KeyValue = $c[3]; Detail = $c[4]; Confidence = $c[5]
      }
    }
  }
})

$rows | Sort-Object KeyType, KeyValue, SourceUnit |
  Export-Csv $OutCsv -Encoding UTF8 -NoTypeInformation
Write-Host ('影響メモ {0} 件を集約しました: {1}' -f $rows.Count, $OutCsv)
```

出力された `cross_layer_impacts.csv` を `KeyValue` で並べ、次の3点を確認します。
- 両側から記述があるキー：対応関係が確認できたもの
- 片側からしか記述がないキー：漏れの可能性があるもの。要確認とします。
- 確信度が「低」のもの：人が確認します。

### 8.2 段階的な集約（Codex）
結果ファイルをすべて一度に読ませると、トークン上限に達します。そこで、次の順に段階的に集約します。

1. **レイヤ別要約**：レイヤごとに `results/<レイヤ>-*.md` を読ませ、`summary/<レイヤ>.md` にまとめます。ファイル数が多い場合は、単位番号の範囲（例：action-001〜010）で分けます。

```
docs/survey/results/ のうち action-* で始まるファイルを読み、
docs/survey/summary/action.md にまとめてください。
- 機能分類ごとの件数と代表例
- 置き換え方針案のパターン（同種の対応はまとめる）
- 共通基盤化すべきと判断されたものの一覧
- 難易度「高」の項目の一覧
```

2. **方針案の作成**：`summary/*.md` と `cross_layer_impacts.csv` のみを入力にします。

```
docs/survey/summary/ 配下のファイルと docs/survey/_inventory/cross_layer_impacts.csv を読み、
docs/survey/policy-draft.md に修正方針案を作成してください。
- 新規に作る共通基盤（例：画面遷移制御、スコープ管理、二重送信制御、簡易DI、トランザクション境界、バリデーション）とその責務
- 画面・機能ごとに個別修正が必要な範囲
- 規模感（単位数・行数ベース）
- リスクと、事前に検証すべき事項
```

### 8.3 人が判断すること
- 共通基盤として作るものの範囲と設計方針（AI の案はたたき台として扱う）
- 確信度「低」の項目と、片側にしか記述のない影響メモの確認結果
- 縦調査で見つかった、SWF の暗黙的な挙動を新しい実装でどこまで再現するか

---

## 9. 注意点まとめ
- AI の出力には推測が含まれます。確信度「低」と「要確認事項」は、必ず人が確認してください。
- 指定範囲外のファイルを読んでいないか、ソースを変更していないかを、ログと `git status` で毎回確認してください。
- 分類ルールや単位サイズは、一度で決めようとせず、パイロットの結果を見て調整してください。
- 結果ファイルにソースを大量に転記させないでください。集約時のトークンを圧迫します。
