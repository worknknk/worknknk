<#
  extract-flow-files.ps1
  代表フローの縦調査用に、flow定義を起点として関連ファイルを機械的に抽出する
  前提: survey-inventory.ps1 を実行済みであること（inventory.csv / jdeps_raw.txt を使用）
  共通定義は survey-settings.ps1、共通処理は survey-common.ps1（同じフォルダに置く）。UTF-8 (BOM付き) で保存すること

  使い方:
    フロー一覧と規模の統計を出す（代表フローの選定用）
      powershell -ExecutionPolicy Bypass -File .\extract-flow-files.ps1
    特定フローの関連ファイルを抽出する
      powershell -ExecutionPolicy Bypass -File .\extract-flow-files.ps1 -Flow 'project-a\src\main\webapp\WEB-INF\flows\order\order-flow.xml'
#>
param(
  [string]$Flow = '',     # 起点とするflow定義XML（$WorkRoot からの相対パス）
  [int]$JavaDepth = 1     # flowから呼ばれるクラスから、さらに何段先の自社クラスまで含めるか
)

. (Join-Path $PSScriptRoot 'survey-common.ps1')

$Flow = $Flow -replace '/', '\'

# プロジェクトごとのWebRoot（絶対パス）
$webRootOf = @{}
foreach ($p in $Projects) { if ($p.WebRoot) { $webRootOf[$p.Name] = Join-Path (Join-Path $RootTrim $p.Name) $p.WebRoot } }

$inv = @(Import-Csv (Join-Path $InvDir 'inventory.csv'))
$byPath = @{}; $byFqcn = @{}
foreach ($i in $inv) { $byPath[$i.Path] = $i; if ($i.Fqcn) { $byFqcn[$i.Fqcn] = $i } }

# ---------- flow ID とファイルの対応表（キーは「プロジェクト|flowID」） ----------
$flowFiles = @($inv | Where-Object { $_.Layer -eq 'flow' -and $_.Ext -eq '.xml' })
$flowById = @{}
foreach ($f in $flowFiles) {
  $ids = @(
    ([System.IO.Path]::GetFileNameWithoutExtension($f.Path) -replace '-flow$', '')
    (Split-Path (Split-Path $f.Path -Parent) -Leaf)
  )
  if ($f.Path -match '\\flows\\(.+)\\[^\\]+$') { $ids += ($Matches[1] -replace '\\', '/') }
  foreach ($id in $ids) {
    $key = $f.Project + '|' + $id
    if ($id -and -not $flowById.ContainsKey($key)) { $flowById[$key] = $f.Path }
  }
}

# ---------- モード1: フロー一覧と規模の統計 ----------
if (-not $Flow) {
  $stats = foreach ($f in $flowFiles) {
    $t = Read-Text $f.Path
    [pscustomobject]@{
      Project        = $f.Project
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
  foreach ($e in (Get-JdepsEdges $jdepsRaw)) {
    if ($e.To -match $AppRegex) {
      if (-not $fwd.ContainsKey($e.From)) { $fwd[$e.From] = New-Object System.Collections.Generic.HashSet[string] }
      [void]$fwd[$e.From].Add($e.To)
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
  if (-not $r -or $r -match '^((https?:)?//|<)') { return $null }
  if ($r.StartsWith('/')) {
    $wr = $webRootOf[$byPath[$baseRel].Project]
    if (-not $wr) { return $null }
    $cand = Join-Path $wr ($r.TrimStart('/') -replace '/', '\')
  }
  else { $cand = Join-Path (Split-Path (Join-Path $RootTrim $baseRel) -Parent) ($r -replace '/', '\') }
  $full = [System.IO.Path]::GetFullPath($cand)
  if (Test-Path -LiteralPath $full -PathType Leaf) { return Get-Rel $full }
  return $null
}

# view属性の値をJSPファイルに解決
function Resolve-View([string]$view, [string]$flowRel) {
  $flowDir = Split-Path (Join-Path $RootTrim $flowRel) -Parent
  $wr = $webRootOf[$byPath[$flowRel].Project]
  $v = $view.TrimStart('/') -replace '/', '\'
  foreach ($c in $ViewCandidates) {
    if ($c.Contains('{webRoot}') -and -not $wr) { continue }
    $p = $c.Replace('{flowDir}', $flowDir).Replace('{webRoot}', [string]$wr).Replace('{view}', $v)
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
  $proj = $byPath[$fr].Project
  foreach ($id in $refIds) {
    $key = "$proj|$id"
    $hit = if ($flowById.ContainsKey($key)) { $flowById[$key] }
           else { $flowById.Keys | Where-Object { $_ -like "*|$id" } | Select-Object -First 1 | ForEach-Object { $flowById[$_] } }
    if ($hit) { $flowQueue.Enqueue($hit) } else { $unresolved.Add("flow: $id ($fr)") }
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
$unitId = 'vertical-{0}-{1}' -f $byPath[$Flow].Project, $flowId
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
