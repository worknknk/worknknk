<#
  survey-inventory.ps1
  SWF / Spring 依存の棚卸し（調査フェーズ0）
  - 共通定義は survey-settings.ps1、共通処理は survey-common.ps1（同じフォルダに置く）
  - PowerShell 5.1 / 7 で動作。UTF-8 (BOM付き) で保存すること
  実行例: powershell -ExecutionPolicy Bypass -File .\survey-inventory.ps1
#>
. (Join-Path $PSScriptRoot 'survey-common.ps1')

foreach ($d in $InvDir, $UnitDir, $ResultDir) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# ---------- Step 1: ファイル一覧とレイヤの機械分類（全プロジェクト） ----------
Write-Host 'Step 1: ファイル一覧を作成中...'
$fileInfos = New-Object System.Collections.Generic.List[object]
$inventory = New-Object System.Collections.Generic.List[object]
foreach ($p in $Projects) {
  $projRoot = Join-Path $RootTrim $p.Name
  if (-not (Test-Path $projRoot)) { Write-Warning "プロジェクトが見つかりません: $projRoot"; continue }
  $javaPrefix = $p.Name + '\' + $p.JavaSrc.TrimEnd('\') + '\'
  Write-Host ('  {0}  Layer={1}  WebRoot={2}  ClassesDir={3}' -f $p.Name, $(if ($p.Layer) { $p.Layer } else { '(自動分類)' }), $(if ($p.WebRoot) { $p.WebRoot } else { '(なし)' }), $p.ClassesDir)

  foreach ($f in (Get-SourceFiles $projRoot)) {
    $fileInfos.Add($f)
    $rel = Get-Rel $f.FullName
    $relInProj = '\' + $rel.Substring($p.Name.Length + 1)

    if ($p.Layer) { $layer = $p.Layer }
    else {
      $layer = 'other'
      foreach ($k in $LayerRules.Keys) { if ($relInProj -match $LayerRules[$k]) { $layer = $k; break } }
    }

    $fqcn = ''
    if ($f.Extension -eq '.java' -and $rel.StartsWith($javaPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      $fqcn = ($rel.Substring($javaPrefix.Length) -replace '\.java$', '') -replace '\\', '.'
    }

    $inventory.Add([pscustomobject]@{
      Project    = $p.Name
      Path       = $rel
      Ext        = $f.Extension
      Layer      = $layer
      Dir        = (Split-Path $rel -Parent)
      Fqcn       = $fqcn
      Lines      = [System.IO.File]::ReadAllLines($f.FullName).Length
      DirectRefs = 0
      Depth      = $null
    })
  }
}
$files = $fileInfos.ToArray()

# ---------- Step 2: キーワードによる直接参照の検出（リソースファイル含む） ----------
Write-Host 'Step 2: 直接参照を検索中...'
$direct = @($files | Select-String -Pattern $KeywordRegex -AllMatches | ForEach-Object {
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
  Select-String -Pattern $ReflectionPattern |
  ForEach-Object { [pscustomobject]@{ Path = (Get-Rel $_.Path); Line = $_.LineNumber; Text = $_.Line.Trim() } })
$reflect | Export-Csv (Join-Path $InvDir 'reflection_refs.csv') -Encoding UTF8 -NoTypeInformation

# ---------- Step 4: jdeps による間接参照（全プロジェクトをまとめて解析、段階数つき） ----------
Write-Host 'Step 4: jdeps で依存関係を解析中...'
$depth = @{}
$via   = @{}
$classDirs = @()
foreach ($p in $Projects) {
  if (-not $p.ClassesDir) { continue }
  $cd = Join-Path (Join-Path $RootTrim $p.Name) $p.ClassesDir
  if (Test-Path $cd) { $classDirs += $cd } else { Write-Warning "コンパイル済みクラスが見つかりません: $cd （このプロジェクトの間接参照は解析されません）" }
}
if ($classDirs.Count -eq 0) {
  Write-Warning '解析できるクラスがないため、間接参照の解析をスキップします（ビルド後に再実行してください）'
} else {
  $jdepsOut = Join-Path $InvDir 'jdeps_raw.txt'
  & jdeps -verbose:class @classDirs @ExtraJars | Out-File $jdepsOut -Encoding UTF8

  $deps = @(Get-JdepsEdges $jdepsOut)

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
    if ($x.Class -match $AppRegex -and -not $depth.ContainsKey($x.Class)) {
      $depth[$x.Class] = 0; $via[$x.Class] = 'xml:' + $x.Path; $queue.Enqueue($x.Class)
    }
  }
  # 幅優先で依存元をたどり、Springからの段階数を記録（プロジェクトを跨ぐ依存もたどる）
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

function New-Unit($project, $layer, $seq, $unitFiles) {
  $depths = @($unitFiles | Where-Object { $null -ne $_.Depth } | ForEach-Object { [int]$_.Depth })
  $lines  = ($unitFiles | Measure-Object -Property Lines -Sum).Sum
  [pscustomobject]@{
    UnitId    = '{0}-{1}-{2:000}' -f $project, $layer, $seq
    Order     = $LayerOrder[$layer]
    Project   = $project
    Layer     = $layer
    Files     = $unitFiles.Count
    Lines     = $lines
    MinDepth  = $(if ($depths.Count) { ($depths | Measure-Object -Minimum).Minimum } else { '' })
    OverLimit = ($lines -gt $MaxLines)
    FirstDir  = $unitFiles[0].Dir
    Dirs      = @($unitFiles | ForEach-Object { $_.Dir } | Sort-Object -Unique).Count
    PathList  = @($unitFiles | ForEach-Object { $_.Path })
  }
}

# プロジェクト×レイヤごとにパス順で並べ、行数上限まで詰めて区切る
$units = New-Object System.Collections.Generic.List[object]
foreach ($g in ($targets | Group-Object Project, Layer)) {
  $project = $g.Group[0].Project
  $layer   = $g.Group[0].Layer
  $seq = 1; $acc = 0
  $buf = New-Object System.Collections.Generic.List[object]
  foreach ($f in ($g.Group | Sort-Object Path)) {
    if ($acc + $f.Lines -gt $MaxLines -and $buf.Count -gt 0) {
      $units.Add((New-Unit $project $layer $seq $buf.ToArray()))
      $seq++; $acc = 0; $buf.Clear()
    }
    $buf.Add($f); $acc += $f.Lines
  }
  if ($buf.Count -gt 0) { $units.Add((New-Unit $project $layer $seq $buf.ToArray())) }
}
# 全プロジェクトの共通基盤 → 設定 → flow … の順に並べる
$units = @($units | Sort-Object Order, UnitId)

# 調査単位ごとの対象ファイル一覧（Codexに読ませる範囲。パスは $WorkRoot からの相対）
foreach ($u in $units) { $u.PathList | Out-File (Join-Path $UnitDir ($u.UnitId + '.txt')) -Encoding UTF8 }

$units | Select-Object UnitId, Order, Project, Layer, Files, Lines, MinDepth, OverLimit, Dirs, FirstDir |
  Export-Csv (Join-Path $InvDir 'units.csv') -Encoding UTF8 -NoTypeInformation

# 進捗管理用チェックリスト
$md = @('# 調査チェックリスト', '',
        '| 状態 | 調査単位 | プロジェクト | レイヤ | ファイル数 | 行数 | 最小段階 | 先頭フォルダ | 結果ファイル |',
        '|---|---|---|---|---|---|---|---|---|')
foreach ($u in $units) {
  $md += ('| 未着手 | {0} | {1} | {2} | {3} | {4} | {5} | {6} | results/{0}.md |' -f `
    $u.UnitId, $u.Project, $u.Layer, $u.Files, $u.Lines, $u.MinDepth, $u.FirstDir)
}
$md | Out-File (Join-Path $SurveyDir 'survey-checklist.md') -Encoding UTF8

Write-Host ('完了: 全ファイル {0} / 調査対象 {1} / 調査単位 {2}（上限超過 {3}）' -f `
  $inventory.Count, $targets.Count, $units.Count, @($units | Where-Object OverLimit).Count)
