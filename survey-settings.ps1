<#
  survey-settings.ps1
  調査スクリプトの共通定義（環境・ルールに関する設定はすべてここに集約）
  survey-common.ps1 から読み込まれる。UTF-8 (BOM付き) で保存すること
#>

# =====================================================================
# 1. 環境
# =====================================================================
# 全プロジェクトを含む親フォルダ。Codex CLI もこのフォルダで起動する
$WorkRoot  = 'C:\work'
# 調査結果の出力先（全プロジェクト分を1か所に集約）
$SurveyDir = Join-Path $WorkRoot 'survey'

# 調査対象のプロジェクト名（$WorkRoot 直下のフォルダ名）。追加・削除はここだけで行う
$ProjectNames = @(
  'project-a'
  'project-b'
  'common-lib'
)

# 全プロジェクト共通の既定値（プロジェクト内の相対パス）
#   ClassesDir はjdeps専用（ファイル検索からは除外される）
#   WebRoot が存在しないプロジェクトは、自動的にWebプロジェクトでないものとして扱う
$DefaultJavaSrc    = 'src\main\java'
$DefaultClassesDir = 'target\classes'
$DefaultWebRoot    = 'src\main\webapp'

# 既定値と異なるプロジェクトだけ記述する（指定できるキー: JavaSrc / ClassesDir / WebRoot / Layer）
#   Layer を指定すると、そのプロジェクトの全ファイルをそのレイヤとして扱う（共通ライブラリは 'common'）
$ProjectOverrides = @{
  'common-lib' = @{ Layer = 'common' }
  # 'legacy-web' = @{ WebRoot = 'WebContent'; ClassesDir = 'build\classes' }
}

# 自社コードのパッケージ接頭辞（複数可）
$AppPackages = @('com.example.app', 'com.example.common')

# ソースが手元にない自社フレームワーク等のjar
$ExtraJars = @()

# 1調査単位あたりの行数上限（パイロット後に調整）
$MaxLines = 2500

# =====================================================================
# 2. 棚卸し（survey-inventory.ps1）
# =====================================================================
# 対象とする拡張子
$Extensions = '.java','.xml','.jsp','.jspf','.tag','.tld','.properties','.js'

# 検索から除外するフォルダ名（この名前のフォルダ配下には一切入らない）
$ExcludeDirNames = 'target','build','bin','.git','.svn','.settings','node_modules'

# 依存の有無にかかわらず必ず調査対象に含めるレイヤ
$AlwaysIncludeLayers = 'flow','view','js','config'

# レイヤ分類ルール：上から順に評価し、最初にマッチしたものを採用
#   評価対象はプロジェクト内の相対パス（先頭に \ を付けたもの）
#   基底クラスを共通基盤に含める場合は common を次のようにする:
#   '\\(common|util|utils|base|framework|core)\\|\\(Abstract|Base)[A-Z]\w*\.java$'
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
)

# 文字列でクラスを扱っている箇所として検出するパターン
$ReflectionPattern = 'Class\.forName|getBean\(|\.newInstance\(|loadClass\('

# =====================================================================
# 3. 縦調査（extract-flow-files.ps1）
# =====================================================================
# 抽出から除外するレイヤ（common-summary.md で代替）
$SkipLayers = @('common')

# view属性の値からJSPを探す候補（上から順に存在確認）
#   {flowDir}=flow定義のフォルダ、{webRoot}=そのプロジェクトのWebRoot、{view}=view属性の値
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
