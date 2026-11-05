<#
  survey-common.ps1
  調査スクリプト共通の処理（設定の読み込み、派生値、共通関数）
  各スクリプトの先頭で読み込む。通常は変更不要。UTF-8 (BOM付き) で保存すること
#>
. (Join-Path $PSScriptRoot 'survey-settings.ps1')

# ---------- 派生値 ----------
$RootTrim     = $WorkRoot.TrimEnd('\')
$AppRegex     = '^(' + (($AppPackages | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\.'
$KeywordRegex = $Keywords -join '|'
$InvDir       = Join-Path $SurveyDir '_inventory'
$UnitDir      = Join-Path $SurveyDir '_units'
$ResultDir    = Join-Path $SurveyDir 'results'

# ---------- プロジェクト設定の組み立て（名前の一覧＋既定値＋個別設定） ----------
$Projects = @(foreach ($name in $ProjectNames) {
  $cfg = @{ Name = $name; JavaSrc = $DefaultJavaSrc; ClassesDir = $DefaultClassesDir; WebRoot = $DefaultWebRoot; Layer = '' }
  if ($ProjectOverrides.ContainsKey($name)) {
    foreach ($k in $ProjectOverrides[$name].Keys) { $cfg[$k] = $ProjectOverrides[$name][$k] }
  }
  $projRoot = Join-Path $RootTrim $name
  if ($cfg.WebRoot -and -not (Test-Path (Join-Path $projRoot $cfg.WebRoot))) { $cfg.WebRoot = '' }
  $cfg
})

# ---------- 共通関数 ----------
# 絶対パス → $WorkRoot からの相対パス
function Get-Rel([string]$full) { $full.Substring($RootTrim.Length + 1) }

# $WorkRoot からの相対パスのファイルを文字列で読む
function Read-Text([string]$rel) { [System.IO.File]::ReadAllText((Join-Path $RootTrim $rel)) }

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

# jdeps -verbose:class の出力から、クラス間の依存（From -> To）を取り出す。内部クラスは外側のクラスにまとめる
function Get-JdepsEdges([string]$path) {
  foreach ($line in Get-Content $path) {
    if ($line -match '^\s+(\S+)\s+->\s+(\S+)') {
      $from = $Matches[1] -replace '\$.*$', ''
      $to   = $Matches[2] -replace '\$.*$', ''
      if ($from -ne $to) { [pscustomobject]@{ From = $from; To = $to } }
    }
  }
}
