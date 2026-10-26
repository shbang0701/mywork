<#
.SYNOPSIS
    Office를 띄우지 않고 .NET만으로 xlsx · docx · pptx 시험 파일을 만든다.

.DESCRIPTION
    - 가짜 한국어 데이터를 XML로 쓰고 .NET ZipArchive로 Open XML 파일을 만든다.
    - Office · 외부 라이브러리 없이 생성한다. Office 2016 열기와 업무 PC DRM 적용 여부 시험용이다.
    - 기존 출력 폴더에 날짜가 붙은 새 파일을 저장한다. 폴더가 없거나 같은 이름이 있으면 실패한다.
    - DRM 적용 여부를 판정하거나 기존 문서를 읽는 기능은 없다.

.PARAMETER Type
    만들 형식: xlsx, docx, pptx, all. 기본은 all (세 파일).

.PARAMETER OutFolder
    이미 있는 출력 폴더. 기본은 Windows의 내 문서 폴더. 없는 폴더는 만들지 않는다.

.PARAMETER Open
    만든 파일을 기본 프로그램으로 연다. 생략하면 Office를 띄우지 않는다.

.EXAMPLE
    .\New-OfficeTestFile.ps1
    내 문서에 날짜가 붙은 시험 파일 세 개를 만든다.

.EXAMPLE
    .\New-OfficeTestFile.ps1 -Type xlsx -OutFolder 'D:\시험' -Open
    이미 있는 D:\시험 폴더에 Excel 시험 파일을 만들고 기본 프로그램으로 연다.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('xlsx', 'docx', 'pptx', 'all')][string]$Type = 'all', # 만들 형식 (기본: 세 파일 모두)
    [string]$OutFolder = [Environment]::GetFolderPath('MyDocuments'), # 결과를 저장할 기존 폴더 (기본: 내 문서)
    [switch]$Open # 만든 파일을 기본 프로그램으로 열기
)

# ===== 설정 (여기만 고친다) =====
$Config = @{
    OutputName = 'WorkTool-office-test' # 뒤에 yyyyMMdd-HHmmss와 확장자가 붙는다
    Creator    = 'WorkTool'
    Font       = '맑은 고딕'
    SheetName  = '시험'
    Headers    = @('날짜', '종류', '시작', '끝', '메모')
    ColumnWidths = @(14, 12, 10, 10, 28)
    ExcelRows  = @(
        , @('2026-10-27', '출근', '08:52', '18:10', '주간 점검')
        , @('2026-10-28', '출근', '08:55', '18:05', '자료 정리')
        , @('2026-10-29', '출근', '08:50', '18:00', '시험 완료')
    )
    TotalLabel = '합계'
    WordTitle  = 'WorkTool 시험 문서'
    WordParagraphs = @(
        '이 문서는 Office를 실행하지 않고 .NET만으로 만든 시험 문서입니다.'
        '한국어 문단과 표가 정상으로 보이는지, 업무 PC에서 DRM이 어떻게 적용되는지 확인합니다.'
    )
    WordTable  = @(
        , @('항목', '내용')
        , @('작성 도구', 'WorkTool')
        , @('점검 결과', '사용자가 확인')
    )
    SlideTitle = 'WorkTool 시험 슬라이드'
    SlideBullets = @('한국어 글자 표시 확인', '16:9 슬라이드와 글머리 확인', '업무 PC DRM 적용 여부 확인')
}
# =================================

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertTo-XmlText([string]$Text) {
    [System.Security.SecurityElement]::Escape($Text)
}

function Add-PackagePart($Parts, [string]$Name, [string]$ContentType, [string]$Xml) {
    $Parts.Add($Name, @{ ContentType = $ContentType; Xml = $Xml })
}

function New-ExcelParts {
    $parts = [ordered]@{}
    $sheetName = ConvertTo-XmlText $Config.SheetName
    $font = ConvertTo-XmlText $Config.Font
    Add-PackagePart $parts 'xl/workbook.xml' 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml' @"
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <bookViews><workbookView activeTab="0"/></bookViews>
  <sheets><sheet name="$sheetName" sheetId="1" r:id="rId1"/></sheets>
</workbook>
"@
    Add-PackagePart $parts 'xl/_rels/workbook.xml.rels' '' @'
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>
'@
    Add-PackagePart $parts 'xl/styles.xml' 'application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml' @"
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/></numFmts>
  <fonts count="2"><font><sz val="11"/><name val="$font"/></font><font><b/><sz val="11"/><name val="$font"/></font></fonts>
  <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
  <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="3">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
    <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
  </cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>
"@
    $columns = [System.Text.StringBuilder]::new()
    $rows = [System.Text.StringBuilder]::new()
    [void]$rows.Append('<row r="1">')
    for ($c = 0; $c -lt $Config.Headers.Count; $c++) {
        $column = ([char](65 + $c)).ToString()
        $header = ConvertTo-XmlText $Config.Headers[$c]
        $width = $Config.ColumnWidths[$c].ToString([Globalization.CultureInfo]::InvariantCulture)
        [void]$columns.Append("<col min=`"$($c + 1)`" max=`"$($c + 1)`" width=`"$width`" customWidth=`"1`"/>")
        [void]$rows.Append("<c r=`"${column}1`" s=`"1`" t=`"inlineStr`"><is><t>$header</t></is></c>")
    }
    [void]$rows.Append('</row>')
    for ($r = 0; $r -lt $Config.ExcelRows.Count; $r++) {
        $rowNumber = $r + 2
        [void]$rows.Append("<row r=`"$rowNumber`">")
        for ($c = 0; $c -lt $Config.Headers.Count; $c++) {
            $cell = ([char](65 + $c)).ToString() + $rowNumber
            if ($c -eq 0) {
                $date = [datetime]::ParseExact($Config.ExcelRows[$r][$c], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
                $number = $date.ToOADate().ToString([Globalization.CultureInfo]::InvariantCulture)
                [void]$rows.Append("<c r=`"$cell`" s=`"2`"><v>$number</v></c>")
            } else {
                $text = ConvertTo-XmlText $Config.ExcelRows[$r][$c]
                [void]$rows.Append("<c r=`"$cell`" t=`"inlineStr`"><is><t xml:space=`"preserve`">$text</t></is></c>")
            }
        }
        [void]$rows.Append('</row>')
    }
    $lastRow = $Config.ExcelRows.Count + 2
    $total = ConvertTo-XmlText $Config.TotalLabel
    [void]$rows.Append("<row r=`"$lastRow`"><c r=`"A$lastRow`" t=`"inlineStr`"><is><t>$total</t></is></c><c r=`"B$lastRow`"><v>$($Config.ExcelRows.Count)</v></c></row>")
    Add-PackagePart $parts 'xl/worksheets/sheet1.xml' 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml' @"
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <dimension ref="A1:E$lastRow"/>
  <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A2" sqref="A2"/></sheetView></sheetViews>
  <sheetFormatPr defaultRowHeight="16.5"/><cols>$columns</cols><sheetData>$rows</sheetData>
</worksheet>
"@
    return $parts
}

function New-WordParts {
    $parts = [ordered]@{}
    $font = ConvertTo-XmlText $Config.Font
    Add-PackagePart $parts 'word/styles.xml' 'application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml' @"
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="$font" w:hAnsi="$font" w:eastAsia="$font" w:cs="$font"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="ko-KR" w:eastAsia="ko-KR"/></w:rPr></w:rPrDefault><w:pPrDefault/></w:docDefaults>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
  <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="240"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style>
</w:styles>
"@
    Add-PackagePart $parts 'word/_rels/document.xml.rels' '' @'
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>
'@
    $body = [System.Text.StringBuilder]::new()
    $title = ConvertTo-XmlText $Config.WordTitle
    [void]$body.Append("<w:p><w:pPr><w:pStyle w:val=`"Title`"/></w:pPr><w:r><w:t>$title</w:t></w:r></w:p>")
    foreach ($paragraph in $Config.WordParagraphs) {
        $text = ConvertTo-XmlText $paragraph
        [void]$body.Append("<w:p><w:r><w:t xml:space=`"preserve`">$text</w:t></w:r></w:p>")
    }
    [void]$body.Append(@'
<w:tbl><w:tblPr><w:tblW w:w="9000" w:type="dxa"/><w:tblBorders>
  <w:top w:val="single" w:sz="4"/><w:left w:val="single" w:sz="4"/><w:bottom w:val="single" w:sz="4"/><w:right w:val="single" w:sz="4"/><w:insideH w:val="single" w:sz="4"/><w:insideV w:val="single" w:sz="4"/>
</w:tblBorders></w:tblPr><w:tblGrid><w:gridCol w:w="4500"/><w:gridCol w:w="4500"/></w:tblGrid>
'@)
    for ($r = 0; $r -lt $Config.WordTable.Count; $r++) {
        [void]$body.Append('<w:tr>')
        if ($r -eq 0) { [void]$body.Append('<w:trPr><w:tblHeader/></w:trPr>') }
        foreach ($value in $Config.WordTable[$r]) {
            $text = ConvertTo-XmlText $value
            $runProperties = if ($r -eq 0) { '<w:rPr><w:b/></w:rPr>' } else { '' }
            [void]$body.Append("<w:tc><w:tcPr><w:tcW w:w=`"4500`" w:type=`"dxa`"/></w:tcPr><w:p><w:r>$runProperties<w:t xml:space=`"preserve`">$text</w:t></w:r></w:p></w:tc>")
        }
        [void]$body.Append('</w:tr>')
    }
    [void]$body.Append('</w:tbl>')
    Add-PackagePart $parts 'word/document.xml' 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml' @"
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>$body
  <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
</w:body></w:document>
"@
    return $parts
}

function New-PowerPointParts {
    $parts = [ordered]@{}
    $font = ConvertTo-XmlText $Config.Font
    $group = @'
<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
'@
    Add-PackagePart $parts 'ppt/presentation.xml' 'application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml' @'
<p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst>
  <p:sldSz cx="12192000" cy="6858000" type="custom"/><p:notesSz cx="6858000" cy="9144000"/>
</p:presentation>
'@
    Add-PackagePart $parts 'ppt/_rels/presentation.xml.rels' '' @'
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
</Relationships>
'@
    Add-PackagePart $parts 'ppt/slideMasters/slideMaster1.xml' 'application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml' @"
<p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:cSld><p:spTree>$group</p:spTree></p:cSld>
  <p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink" tx1="dk1" tx2="dk2"/>
  <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
  <p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles>
</p:sldMaster>
"@
    Add-PackagePart $parts 'ppt/slideMasters/_rels/slideMaster1.xml.rels' '' @'
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
</Relationships>
'@
    Add-PackagePart $parts 'ppt/slideLayouts/slideLayout1.xml' 'application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml' @"
<p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">
  <p:cSld name="빈 화면"><p:spTree>$group</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sldLayout>
"@
    Add-PackagePart $parts 'ppt/slideLayouts/_rels/slideLayout1.xml.rels' '' @'
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
</Relationships>
'@
    # 테마의 채우기 · 선 · 효과 · 배경 목록은 각각 세 항목을 갖춘다.
    Add-PackagePart $parts 'ppt/theme/theme1.xml' 'application/vnd.openxmlformats-officedocument.theme+xml' @"
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="WorkTool">
  <a:themeElements>
    <a:clrScheme name="WorkTool"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F497D"/></a:dk2><a:lt2><a:srgbClr val="EEECE1"/></a:lt2><a:accent1><a:srgbClr val="4F81BD"/></a:accent1><a:accent2><a:srgbClr val="C0504D"/></a:accent2><a:accent3><a:srgbClr val="9BBB59"/></a:accent3><a:accent4><a:srgbClr val="8064A2"/></a:accent4><a:accent5><a:srgbClr val="4BACC6"/></a:accent5><a:accent6><a:srgbClr val="F79646"/></a:accent6><a:hlink><a:srgbClr val="0000FF"/></a:hlink><a:folHlink><a:srgbClr val="800080"/></a:folHlink></a:clrScheme>
    <a:fontScheme name="WorkTool"><a:majorFont><a:latin typeface="$font"/><a:ea typeface="$font"/><a:cs typeface="$font"/></a:majorFont><a:minorFont><a:latin typeface="$font"/><a:ea typeface="$font"/><a:cs typeface="$font"/></a:minorFont></a:fontScheme>
    <a:fmtScheme name="WorkTool">
      <a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>
      <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln></a:lnStyleLst>
      <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>
      <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>
    </a:fmtScheme>
  </a:themeElements>
</a:theme>
"@
    $title = ConvertTo-XmlText $Config.SlideTitle
    $bullets = [System.Text.StringBuilder]::new()
    foreach ($line in $Config.SlideBullets) {
        $text = ConvertTo-XmlText $line
        [void]$bullets.Append("<a:p><a:pPr marL=`"342900`" indent=`"-285750`"><a:buFont typeface=`"$font`"/><a:buChar char=`"•`"/></a:pPr><a:r><a:rPr lang=`"ko-KR`" sz=`"2400`"><a:solidFill><a:srgbClr val=`"000000`"/></a:solidFill><a:latin typeface=`"$font`"/><a:ea typeface=`"$font`"/></a:rPr><a:t>$text</a:t></a:r><a:endParaRPr lang=`"ko-KR`" sz=`"2400`"/></a:p>")
    }
    Add-PackagePart $parts 'ppt/slides/slide1.xml' 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml' @"
<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree>$group
    <p:sp><p:nvSpPr><p:cNvPr id="2" name="제목"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
      <p:spPr><a:xfrm><a:off x="685800" y="457200"/><a:ext cx="10820400" cy="914400"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
      <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:buNone/></a:pPr><a:r><a:rPr lang="ko-KR" sz="3200" b="1"><a:solidFill><a:srgbClr val="000000"/></a:solidFill><a:latin typeface="$font"/><a:ea typeface="$font"/></a:rPr><a:t>$title</a:t></a:r></a:p></p:txBody>
    </p:sp>
    <p:sp><p:nvSpPr><p:cNvPr id="3" name="본문"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
      <p:spPr><a:xfrm><a:off x="685800" y="1828800"/><a:ext cx="10820400" cy="4114800"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
      <p:txBody><a:bodyPr/><a:lstStyle/>$bullets</p:txBody>
    </p:sp>
  </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sld>
"@
    Add-PackagePart $parts 'ppt/slides/_rels/slide1.xml.rels' '' @'
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
</Relationships>
'@
    return $parts
}

function Write-OfficePackage([string]$Path, [string]$MainPart, $Parts, [string]$Created) {
    $creator = ConvertTo-XmlText $Config.Creator
    Add-PackagePart $Parts 'docProps/core.xml' 'application/vnd.openxmlformats-package.core-properties+xml' @"
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:creator>$creator</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">$Created</dcterms:created>
</cp:coreProperties>
"@
    Add-PackagePart $Parts '_rels/.rels' '' @"
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="$MainPart"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
</Relationships>
"@
    $types = [System.Text.StringBuilder]::new()
    [void]$types.Append('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
    foreach ($part in $Parts.GetEnumerator()) {
        if (-not $part.Key.EndsWith('.rels')) {
            [void]$types.Append("<Override PartName=`"/$($part.Key)`" ContentType=`"$($part.Value.ContentType)`"/>")
        }
    }
    [void]$types.Append('</Types>')
    Add-PackagePart $Parts '[Content_Types].xml' '' $types.ToString()

    # ZIP을 메모리에서 완성한 뒤 CreateNew로 열어, 사전 검사 뒤 생긴 같은 이름도 덮어쓰지 않는다.
    $memory = [System.IO.MemoryStream]::new()
    try {
        $archive = [System.IO.Compression.ZipArchive]::new($memory, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($part in $Parts.GetEnumerator()) {
                $entry = $archive.CreateEntry($part.Key, [System.IO.Compression.CompressionLevel]::Optimal)
                $writer = [System.IO.StreamWriter]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false))
                try {
                    $writer.Write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
                    $writer.Write($part.Value.Xml)
                } finally { $writer.Dispose() }
            }
        } finally { $archive.Dispose() }
        $file = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $memory.Position = 0
            $memory.CopyTo($file)
        } finally { $file.Dispose() }
    } finally { $memory.Dispose() }
}

# ===== 본문 =====
if ([string]::IsNullOrWhiteSpace($OutFolder) -or -not (Test-Path -LiteralPath $OutFolder -PathType Container)) {
    throw "출력 폴더가 없습니다: $OutFolder"
}
$folder = Get-Item -LiteralPath $OutFolder
if ($folder.PSProvider.Name -ne 'FileSystem') { throw "파일 시스템 폴더가 아닙니다: $OutFolder" }
$now = Get-Date
$stamp = $now.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
$created = $now.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
$formats = if ($Type -eq 'all') { @('xlsx', 'docx', 'pptx') } else { @($Type.ToLowerInvariant()) }
$paths = [ordered]@{}
foreach ($format in $formats) {
    $path = Join-Path $folder.FullName ("{0}-{1}.{2}" -f $Config.OutputName, $stamp, $format)
    if (Test-Path -LiteralPath $path) { throw "같은 이름의 파일이 있습니다: $path" }
    $paths.Add($format, $path)
}
foreach ($format in $formats) {
    switch ($format) {
        'xlsx' { $parts = New-ExcelParts; $mainPart = 'xl/workbook.xml' }
        'docx' { $parts = New-WordParts; $mainPart = 'word/document.xml' }
        'pptx' { $parts = New-PowerPointParts; $mainPart = 'ppt/presentation.xml' }
    }
    Write-OfficePackage $paths[$format] $mainPart $parts $created
    $result = Get-Item -LiteralPath $paths[$format]
    Write-Output ("{0} ({1} bytes)" -f $result.FullName, $result.Length)
}
if ($Open) {
    foreach ($path in $paths.Values) { Invoke-Item -LiteralPath $path }
}
