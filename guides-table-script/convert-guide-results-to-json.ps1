param(
    [string]$ResultsDir = (Join-Path $PSScriptRoot 'results')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-HtmlFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true))
}

function Repair-MojibakeText {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $current = $Text
    $markerChars = @([char]0x00C3, [char]0x00C2, [char]0x00E2)

    for ($i = 0; $i -lt 3; $i++) {
        $containsMarker = $false
        foreach ($marker in $markerChars) {
            if ($current.Contains([string]$marker)) {
                $containsMarker = $true
                break
            }
        }

        if (-not $containsMarker) {
            break
        }

        $bytes = [System.Text.Encoding]::GetEncoding(1252).GetBytes($current)
        $candidate = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($candidate -eq $current) {
            break
        }

        $current = $candidate
    }

    return $current
}

function Normalize-Text {
    param(
        [AllowEmptyString()]
        [string]$HtmlFragment
    )

    $withBreaks = [regex]::Replace($HtmlFragment, '(?is)<br\s*/?>', ' <br> ')
    $stripped = [regex]::Replace($withBreaks, '(?is)<[^>]+>', ' ')
    $decoded = [System.Net.WebUtility]::HtmlDecode($stripped)
    $normalized = ([regex]::Replace($decoded, '\s+', ' ')).Trim()
    return Repair-MojibakeText -Text $normalized
}

function Get-CellData {
    param(
        [Parameter(Mandatory)]
        [string]$CellHtml
    )

    $linkMatch = [regex]::Match($CellHtml, '(?is)<a\b[^>]*href="(?<href>[^"]+)"[^>]*>(?<label>.*?)</a>')
    if ($linkMatch.Success) {
        return [pscustomobject]@{
            Text = Normalize-Text -HtmlFragment $linkMatch.Groups['label'].Value
            Href = $linkMatch.Groups['href'].Value
        }
    }

    return [pscustomobject]@{
        Text = Normalize-Text -HtmlFragment $CellHtml
        Href = $null
    }
}

function Get-TableRows {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $html = Read-HtmlFile -Path $Path
    $tbodyMatch = [regex]::Match($html, '(?is)<tbody>(?<tbody>.*?)</tbody>')
    if (-not $tbodyMatch.Success) {
        throw "Could not find <tbody> in $Path"
    }

    $rows = New-Object System.Collections.Generic.List[object]
    $rowMatches = [regex]::Matches($tbodyMatch.Groups['tbody'].Value, '(?is)<tr>(?<row>.*?)</tr>')

    foreach ($rowMatch in $rowMatches) {
        $cells = [regex]::Matches($rowMatch.Groups['row'].Value, '(?is)<t[dh][^>]*>(?<cell>.*?)</t[dh]>')
        if ($cells.Count -lt 5) {
            throw "Expected at least 5 cells in $Path row: $($rowMatch.Groups['row'].Value)"
        }

        $rows.Add([pscustomobject]@{
            Year = Normalize-Text -HtmlFragment $cells[0].Groups['cell'].Value
            HtmlAccessible = Get-CellData -CellHtml $cells[1].Groups['cell'].Value
            StandardPdf = Get-CellData -CellHtml $cells[2].Groups['cell'].Value
            LargePrintPdf = Get-CellData -CellHtml $cells[3].Groups['cell'].Value
            DownloadEText = Get-CellData -CellHtml $cells[4].Groups['cell'].Value
        })
    }

    return $rows
}

function Get-LinkArray {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Cell,

        [string]$Label
    )

    if ($Cell.Href) {
        $resolvedLabel = if ([string]::IsNullOrWhiteSpace($Label)) { $Cell.Text } else { $Label }
        return , @($resolvedLabel, $Cell.Href)
    }

    return , @($Cell.Text)
}

function Convert-GuideTablePair {
    param(
        [Parameter(Mandatory)]
        [string]$EnglishPath,

        [Parameter(Mandatory)]
        [string]$FrenchPath
    )

    $englishRows = Get-TableRows -Path $EnglishPath
    $frenchRows = Get-TableRows -Path $FrenchPath

    if ($englishRows.Count -ne $frenchRows.Count) {
        throw "Row count mismatch between $EnglishPath and $FrenchPath"
    }

    $data = New-Object System.Collections.Generic.List[object]
    $graveE = [char]0x00E8

    for ($i = 0; $i -lt $englishRows.Count; $i++) {
        $enRow = $englishRows[$i]
        $frRow = $frenchRows[$i]

        if ($enRow.Year -ne $frRow.Year) {
            throw "Year mismatch between $EnglishPath and $FrenchPath at row $($i): $($enRow.Year) vs $($frRow.Year)"
        }

        $year = $enRow.Year
        $largePrintFrenchLabel = "$year - PDF en gros caract${graveE}res"

        $data.Add([ordered]@{
            year = $year
            html_acc_en = Get-LinkArray -Cell $enRow.HtmlAccessible
            html_acc_fr = Get-LinkArray -Cell $frRow.HtmlAccessible
            stnd_pdf_en = Get-LinkArray -Cell $enRow.StandardPdf -Label "$year - Standard PDF"
            stnd_pdf_fr = Get-LinkArray -Cell $frRow.StandardPdf -Label "$year - PDF standard"
            lrge_pdf_en = Get-LinkArray -Cell $enRow.LargePrintPdf -Label "$year - Large print PDF"
            lrge_pdf_fr = Get-LinkArray -Cell $frRow.LargePrintPdf -Label $largePrintFrenchLabel
            dwld_etx_en = Get-LinkArray -Cell $enRow.DownloadEText -Label "$year - E-text file"
            dwld_etx_fr = Get-LinkArray -Cell $frRow.DownloadEText -Label "$year - Fichier .txt"
        })
    }

    $transformedData = New-Object System.Collections.Generic.List[object]
    $sourceCurrentRow = Copy-GuideDataRow -Row $data[0]
    $sourcePreviousRow = Copy-GuideDataRow -Row $data[1]

    $new2025Row = Copy-GuideDataRow -Row $sourceCurrentRow
    $new2025Row.year = '2025'
    $new2025Row.html_acc_en = @('Current page')
    $new2025Row.html_acc_fr = @('Page actuelle')
    $new2025Row.stnd_pdf_en = Replace-FileArrayYear -Field $sourceCurrentRow.stnd_pdf_en -FromYear '2024' -ToYear '2025'
    $new2025Row.stnd_pdf_fr = Replace-FileArrayYear -Field $sourceCurrentRow.stnd_pdf_fr -FromYear '2024' -ToYear '2025'
    $new2025Row.lrge_pdf_en = Replace-FileArrayYear -Field $sourceCurrentRow.lrge_pdf_en -FromYear '2024' -ToYear '2025'
    $new2025Row.lrge_pdf_fr = Replace-FileArrayYear -Field $sourceCurrentRow.lrge_pdf_fr -FromYear '2024' -ToYear '2025'
    $new2025Row.dwld_etx_en = Replace-FileArrayYear -Field $sourceCurrentRow.dwld_etx_en -FromYear '2024' -ToYear '2025'
    $new2025Row.dwld_etx_fr = Replace-FileArrayYear -Field $sourceCurrentRow.dwld_etx_fr -FromYear '2024' -ToYear '2025'
    $transformedData.Add($new2025Row)

    $archive2024Row = Copy-GuideDataRow -Row $sourceCurrentRow
    $archive2024Row.html_acc_en = Replace-HtmlArrayYear -Field $sourcePreviousRow.html_acc_en -FromYear '2023' -ToYear '2024'
    $archive2024Row.html_acc_fr = Replace-HtmlArrayYear -Field $sourcePreviousRow.html_acc_fr -FromYear '2023' -ToYear '2024'
    $transformedData.Add($archive2024Row)

    for ($i = 1; $i -lt $data.Count; $i++) {
        if ($data[$i].year -eq '2015') {
            continue
        }

        $transformedData.Add((Copy-GuideDataRow -Row $data[$i]))
    }

    return [ordered]@{ data = $transformedData }
}

function Copy-GuideDataRow {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Row
    )

    return [ordered]@{
        year = $Row.year
        html_acc_en = @($Row.html_acc_en)
        html_acc_fr = @($Row.html_acc_fr)
        stnd_pdf_en = @($Row.stnd_pdf_en)
        stnd_pdf_fr = @($Row.stnd_pdf_fr)
        lrge_pdf_en = @($Row.lrge_pdf_en)
        lrge_pdf_fr = @($Row.lrge_pdf_fr)
        dwld_etx_en = @($Row.dwld_etx_en)
        dwld_etx_fr = @($Row.dwld_etx_fr)
    }
}

function Replace-YearText {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$FromYear,

        [Parameter(Mandatory)]
        [string]$ToYear
    )

    $fromShort = $FromYear.Substring(2)
    $toShort = $ToYear.Substring(2)
    $updated = $Text.Replace($FromYear, $ToYear)
    $updated = $updated -replace "-$fromShort(?=[ef]\.(pdf|txt)$)", "-$toShort"
    return $updated
}

function Replace-HtmlArrayYear {
    param(
        [Parameter(Mandatory)]
        [string[]]$Field,

        [Parameter(Mandatory)]
        [string]$FromYear,

        [Parameter(Mandatory)]
        [string]$ToYear
    )

    return @(
        (Replace-YearText -Text $Field[0] -FromYear $FromYear -ToYear $ToYear),
        (Replace-YearText -Text $Field[1] -FromYear $FromYear -ToYear $ToYear)
    )
}

function Replace-FileArrayYear {
    param(
        [Parameter(Mandatory)]
        [string[]]$Field,

        [Parameter(Mandatory)]
        [string]$FromYear,

        [Parameter(Mandatory)]
        [string]$ToYear
    )

    if ($Field.Count -eq 1) {
        return @($Field[0])
    }

    return @(
        (Replace-YearText -Text $Field[0] -FromYear $FromYear -ToYear $ToYear),
        (Replace-YearText -Text $Field[1] -FromYear $FromYear -ToYear $ToYear)
    )
}

function ConvertTo-JsonStringLiteral {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return 'null'
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')

    foreach ($char in $Value.ToCharArray()) {
        switch ([int][char]$char) {
            8 { [void]$builder.Append('\b'); continue }
            9 { [void]$builder.Append('\t'); continue }
            10 { [void]$builder.Append('\n'); continue }
            12 { [void]$builder.Append('\f'); continue }
            13 { [void]$builder.Append('\r'); continue }
            34 { [void]$builder.Append('\"'); continue }
            92 { [void]$builder.Append('\\'); continue }
        }

        if ([int][char]$char -lt 32) {
            [void]$builder.AppendFormat('\u{0:x4}', [int][char]$char)
            continue
        }

        [void]$builder.Append($char)
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-TemplateJson {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Document
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('{')
    $lines.Add('  "data": [')

    for ($rowIndex = 0; $rowIndex -lt $Document.data.Count; $rowIndex++) {
        $row = $Document.data[$rowIndex]
        $rowKeys = @($row.Keys)

        $lines.Add('    {')
        for ($keyIndex = 0; $keyIndex -lt $rowKeys.Count; $keyIndex++) {
            $key = $rowKeys[$keyIndex]
            $value = $row[$key]

            if ($value -is [System.Array]) {
                $items = foreach ($item in $value) {
                    ConvertTo-JsonStringLiteral -Value ([string]$item)
                }
                $valueJson = "[{0}]" -f ($items -join ', ')
            }
            else {
                $valueJson = ConvertTo-JsonStringLiteral -Value ([string]$value)
            }

            $suffix = if ($keyIndex -lt ($rowKeys.Count - 1)) { ',' } else { '' }
            $lines.Add(("      ""{0}"": {1}{2}" -f $key, $valueJson, $suffix))
        }

        $rowSuffix = if ($rowIndex -lt ($Document.data.Count - 1)) { ',' } else { '' }
        $lines.Add("    }$rowSuffix")
    }

    $lines.Add('  ]')
    $lines.Add('}')
    return [string]::Join("`r`n", $lines)
}

if (-not (Test-Path -LiteralPath $ResultsDir)) {
    throw "Results directory does not exist: $ResultsDir"
}

$englishFiles = Get-ChildItem -Path $ResultsDir -Filter '*-table-e.htm' | Sort-Object Name
$created = New-Object System.Collections.Generic.List[string]

foreach ($englishFile in $englishFiles) {
    $frenchName = $englishFile.Name -replace '-table-e\.htm$', '-table-f.htm'
    $frenchPath = Join-Path $ResultsDir $frenchName
    if (-not (Test-Path -LiteralPath $frenchPath)) {
        throw "Missing French pair for $($englishFile.Name)"
    }

    $outputName = $englishFile.Name -replace '-table-e\.htm$', '-table-data.json'
    $outputPath = Join-Path $ResultsDir $outputName
    $jsonObject = Convert-GuideTablePair -EnglishPath $englishFile.FullName -FrenchPath $frenchPath
    $jsonText = ConvertTo-TemplateJson -Document $jsonObject
    [System.IO.File]::WriteAllText($outputPath, "$jsonText`r`n", [System.Text.UTF8Encoding]::new($false))
    $created.Add($outputName)
}

$created
