[CmdletBinding()]
param(
  [string]$FormsListPath = ".\recent-T1-forms-9yrs.txt",
  [string]$ResultsDir = "..\..\forms-table-script\results",
  [string]$OutputDir = "C:\my-working-files\GitHub\t1-readmes-nav\forms-table-json\tables",
  [string[]]$FormCode,
  [switch]$DryRun
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Resolve-ExistingPath {
  param(
    [Parameter(Mandatory)] [string]$PathValue,
    [Parameter(Mandatory)] [string]$BaseDir
  )

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    if (-not (Test-Path -LiteralPath $PathValue)) {
      throw "Required path not found: $PathValue"
    }
    return (Resolve-Path -LiteralPath $PathValue).Path
  }

  $scriptRelative = Join-Path $BaseDir $PathValue
  if (Test-Path -LiteralPath $scriptRelative) {
    return (Resolve-Path -LiteralPath $scriptRelative).Path
  }

  if (Test-Path -LiteralPath $PathValue) {
    return (Resolve-Path -LiteralPath $PathValue).Path
  }

  throw "Required path not found: $PathValue"
}

function Resolve-DirectoryPath {
  param(
    [Parameter(Mandatory)] [string]$PathValue,
    [Parameter(Mandatory)] [string]$BaseDir
  )

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return $PathValue
  }

  return (Join-Path $BaseDir $PathValue)
}

function Get-FormsList {
  param(
    [Parameter(Mandatory)] [string]$Path
  )

  return Get-Content -LiteralPath $Path |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') }
}

function Get-CellValue {
  param(
    [Parameter(Mandatory)] [string]$CellHtml,
    [Parameter(Mandatory)] [string]$Lang
  )

  $linkMatch = [regex]::Match(
    $CellHtml,
    '<a\b[^>]*\bhref\s*=\s*"(?<url>[^"]+)"[^>]*>(?<label>.*?)</a>',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )

  if ($linkMatch.Success) {
    $label = [System.Text.RegularExpressions.Regex]::Replace($linkMatch.Groups['label'].Value, '<[^>]+>', '').Trim()
    $url = $linkMatch.Groups['url'].Value.Trim()
    return @($label, $url)
  }

  $text = [System.Text.RegularExpressions.Regex]::Replace($CellHtml, '<[^>]+>', '').Trim()
  if ($text -match '^(?i:Not\s+available)$' -or $text -match '^(?i:Pas\s+disponible)$') {
    if ($Lang -eq 'fr') { return @('Pas disponible') }
    return @('Not available')
  }

  if ([string]::IsNullOrWhiteSpace($text)) {
    if ($Lang -eq 'fr') { return @('Pas disponible') }
    return @('Not available')
  }

  return @($text)
}

function Get-YearMapFromHtml {
  param(
    [Parameter(Mandatory)] [string]$HtmlText,
    [Parameter(Mandatory)] [string]$Lang
  )

  $yearMap = @{}

  $rowMatches = [regex]::Matches(
    $HtmlText,
    '<tr>\s*<th>\s*(?<year>\d{4})\s*</th>\s*(?<cells>(?:<td>.*?</td>\s*){4})\s*</tr>',
    [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )

  foreach ($row in $rowMatches) {
    $year = $row.Groups['year'].Value
    $cellsBlock = $row.Groups['cells'].Value
    $cellMatches = [regex]::Matches(
      $cellsBlock,
      '<td>\s*(?<cell>.*?)\s*</td>',
      [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if ($cellMatches.Count -lt 4) {
      continue
    }

    $yearMap[$year] = @{
      fill_pdf = Get-CellValue -CellHtml $cellMatches[0].Groups['cell'].Value -Lang $Lang
      stnd_pdf = Get-CellValue -CellHtml $cellMatches[1].Groups['cell'].Value -Lang $Lang
      lrge_pdf = Get-CellValue -CellHtml $cellMatches[2].Groups['cell'].Value -Lang $Lang
      dwld_etx = Get-CellValue -CellHtml $cellMatches[3].Groups['cell'].Value -Lang $Lang
    }
  }

  return $yearMap
}

function Convert-FormPairToObject {
  param(
    [Parameter(Mandatory)] [string]$Form,
    [Parameter(Mandatory)] [string]$EnHtmlPath,
    [Parameter(Mandatory)] [string]$FrHtmlPath
  )

  $enHtml = Get-Content -LiteralPath $EnHtmlPath -Raw
  $frHtml = Get-Content -LiteralPath $FrHtmlPath -Raw

  $enByYear = Get-YearMapFromHtml -HtmlText $enHtml -Lang 'en'
  $frByYear = Get-YearMapFromHtml -HtmlText $frHtml -Lang 'fr'

  $years = @($enByYear.Keys + $frByYear.Keys) |
    Sort-Object -Unique -Descending

  $rows = foreach ($year in $years) {
    if (-not $enByYear.ContainsKey($year) -or -not $frByYear.ContainsKey($year)) {
      throw "Year mismatch for ${Form}: missing EN or FR row for year $year."
    }

    [ordered]@{
      year        = $year
      fill_pdf_en = $enByYear[$year].fill_pdf
      fill_pdf_fr = $frByYear[$year].fill_pdf
      stnd_pdf_en = $enByYear[$year].stnd_pdf
      stnd_pdf_fr = $frByYear[$year].stnd_pdf
      lrge_pdf_en = $enByYear[$year].lrge_pdf
      lrge_pdf_fr = $frByYear[$year].lrge_pdf
      dwld_etx_en = $enByYear[$year].dwld_etx
      dwld_etx_fr = $frByYear[$year].dwld_etx
    }
  }

  return [ordered]@{ data = $rows }
}

function ConvertTo-JsonStringLiteral {
  param([Parameter(Mandatory)] [string]$Value)

  $escaped = $Value `
    -replace '\\', '\\\\' `
    -replace '"', '\"' `
    -replace "`r", '\r' `
    -replace "`n", '\n' `
    -replace "`t", '\t'

  return '"' + $escaped + '"'
}

function ConvertTo-JsonInlineArray {
  param([Parameter(Mandatory)] [object[]]$Values)
  $parts = foreach ($v in $Values) {
    ConvertTo-JsonStringLiteral -Value ([string]$v)
  }
  return '[' + ($parts -join ', ') + ']'
}

function Convert-TableObjectToJsonText {
  param([Parameter(Mandatory)] [hashtable]$TableObject)

  $rows = @($TableObject.data)
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('{')

  if ($rows.Count -eq 0) {
    $lines.Add('  "data": []')
    $lines.Add('}')
    return ($lines -join "`r`n")
  }

  $lines.Add('  "data": [{')

  $keys = @(
    'fill_pdf_en', 'fill_pdf_fr',
    'stnd_pdf_en', 'stnd_pdf_fr',
    'lrge_pdf_en', 'lrge_pdf_fr',
    'dwld_etx_en', 'dwld_etx_fr'
  )

  for ($i = 0; $i -lt $rows.Count; $i++) {
    $row = $rows[$i]

    if ($i -gt 0) {
      $lines.Add('    {')
    }

    $lines.Add('      "year": ' + (ConvertTo-JsonStringLiteral -Value ([string]$row.year)) + ',')

    for ($k = 0; $k -lt $keys.Count; $k++) {
      $key = $keys[$k]
      $arr = @($row.$key)
      $suffix = if ($k -lt ($keys.Count - 1)) { ',' } else { '' }
      $lines.Add('      "' + $key + '": ' + (ConvertTo-JsonInlineArray -Values $arr) + $suffix)
    }

    if ($i -lt ($rows.Count - 1)) {
      $lines.Add('    },')
    } else {
      $lines.Add('    }]')
    }
  }

  $lines.Add('}')
  return ($lines -join "`r`n")
}

function Write-Utf8NoBomFile {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string]$Content
  )

  if (-not ($Content.EndsWith("`r`n") -or $Content.EndsWith("`n"))) {
    $Content += "`r`n"
  }

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

$resolvedFormsListPath = Resolve-ExistingPath -PathValue $FormsListPath -BaseDir $scriptRoot
$resolvedResultsDir = Resolve-ExistingPath -PathValue $ResultsDir -BaseDir $scriptRoot
$resolvedOutputDir = Resolve-DirectoryPath -PathValue $OutputDir -BaseDir $scriptRoot

$forms = if ($FormCode -and $FormCode.Count -gt 0) {
  $FormCode | ForEach-Object { $_.Trim() } | Where-Object { $_ }
} else {
  Get-FormsList -Path $resolvedFormsListPath
}

if (-not $DryRun -and -not (Test-Path -LiteralPath $resolvedOutputDir)) {
  New-Item -Path $resolvedOutputDir -ItemType Directory -Force | Out-Null
}

$successCount = 0
$skipCount = 0

foreach ($form in $forms) {
  $enPath = Join-Path $resolvedResultsDir "$form-table-e.htm"
  $frPath = Join-Path $resolvedResultsDir "$form-table-f.htm"
  $outPath = Join-Path $resolvedOutputDir "$form-table-data.json"

  if (-not (Test-Path -LiteralPath $enPath) -or -not (Test-Path -LiteralPath $frPath)) {
    Write-Warning "Skipping ${form}: missing HTML pair."
    $skipCount++
    continue
  }

  try {
    $obj = Convert-FormPairToObject -Form $form -EnHtmlPath $enPath -FrHtmlPath $frPath
    $json = Convert-TableObjectToJsonText -TableObject $obj

    if ($DryRun) {
      Write-Host "[DryRun] Parsed $form -> $outPath"
    } else {
      Write-Utf8NoBomFile -Path $outPath -Content $json
      Write-Host "Wrote $outPath"
    }
    $successCount++
  } catch {
    Write-Warning "Failed ${form}: $($_.Exception.Message)"
    $skipCount++
  }
}

Write-Host ""
Write-Host "Done. Successful: $successCount. Skipped/Failed: $skipCount."
