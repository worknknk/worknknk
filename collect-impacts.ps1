<#
  collect-impacts.ps1
  各調査結果ファイルの「他レイヤへの影響」表を1つのCSVに集約する（集約フェーズ）
  共通定義は survey-settings.ps1、共通処理は survey-common.ps1（同じフォルダに置く）。UTF-8 (BOM付き) で保存すること
#>
. (Join-Path $PSScriptRoot 'survey-common.ps1')
$OutCsv = Join-Path $InvDir 'cross_layer_impacts.csv'

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
