param(
    [string]$ResultsDir = (Join-Path $PSScriptRoot 'results'),
    [int]$TimeoutSec = 20,
    [string]$OutFile = '',
    [string]$Year = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GuideJsonFiles {
    param(
        [string]$Directory
    )

    return Get-ChildItem -Path $Directory -Filter '*-table-data.json' |
        Where-Object { $_.Name -ne '5000-g-table-data-with-regions.json' } |
        Sort-Object Name
}

function Get-UrlRefs {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$FilterYear = ''
    )

    $refs = New-Object System.Collections.Generic.List[object]

    foreach ($file in $Files) {
        $json = Get-Content -Raw $file.FullName | ConvertFrom-Json
        for ($rowIndex = 0; $rowIndex -lt $json.data.Count; $rowIndex++) {
            $row = $json.data[$rowIndex]
            if ($FilterYear -and [string]$row.year -ne $FilterYear) {
                continue
            }
            foreach ($prop in 'html_acc_en','html_acc_fr','stnd_pdf_en','stnd_pdf_fr','lrge_pdf_en','lrge_pdf_fr','dwld_etx_en','dwld_etx_fr') {
                $value = $row.$prop
                if ($value -is [System.Array] -and $value.Count -gt 1) {
                    $refs.Add([pscustomobject]@{
                        File = $file.Name
                        Year = [string]$row.year
                        Field = $prop
                        Url = [string]$value[1]
                    })
                }
            }
        }
    }

    return $refs
}

function Test-Url {
    param(
        [string]$Url,
        [int]$Timeout
    )

    function Invoke-CurlCheck {
        param(
            [string]$MethodName,
            [bool]$UseHead
        )

        $args = @(
            '--location',
            '--max-redirs', '10',
            '--connect-timeout', [string]$Timeout,
            '--silent',
            '--show-error',
            '--output', 'NUL',
            '--write-out', 'HTTPSTATUS:%{http_code}|FINALURL:%{url_effective}',
            '--url', $Url
        )

        if ($UseHead) {
            $args = @('--head') + $args
        }

        $raw = & curl.exe @args 2>&1
        $exitCode = $LASTEXITCODE
        $text = (($raw | ForEach-Object { $_.ToString() }) -join "`n").Trim()
        $statusCode = 0
        $finalUrl = $Url

        if ($text -match 'HTTPSTATUS:(\d{3})\|FINALURL:(.+)$') {
            $statusCode = [int]$matches[1]
            $finalUrl = [string]$matches[2]
        }
        elseif ($text -match 'HTTPSTATUS:(\d{3})\|FINALURL:$') {
            $statusCode = [int]$matches[1]
        }

        $errorText = ''
        if ($exitCode -ne 0) {
            $errorText = $text
        }

        return [pscustomobject]@{
            Ok = ($exitCode -eq 0 -and $statusCode -ge 200 -and $statusCode -lt 400)
            StatusCode = $statusCode
            FinalUrl = $finalUrl
            Error = $errorText
            Method = $MethodName
            ExitCode = $exitCode
        }
    }

    $headCheck = Invoke-CurlCheck -MethodName 'HEAD' -UseHead $true
    if ($headCheck.Ok) {
        return $headCheck
    }

    if ($headCheck.StatusCode -eq 403 -or $headCheck.StatusCode -eq 405 -or $headCheck.StatusCode -eq 0) {
        $getCheck = Invoke-CurlCheck -MethodName 'GET' -UseHead $false
        if ($getCheck.Ok) {
            return $getCheck
        }
        return $getCheck
    }

    return $headCheck
}

$files = Get-GuideJsonFiles -Directory $ResultsDir
$refs = Get-UrlRefs -Files $files -FilterYear $Year
$uniqueUrls = $refs.Url | Sort-Object -Unique
$results = New-Object System.Collections.Generic.List[object]

foreach ($url in $uniqueUrls) {
    $check = Test-Url -Url $url -Timeout $TimeoutSec
    $urlRefs = $refs | Where-Object { $_.Url -eq $url }
    foreach ($ref in $urlRefs) {
        $results.Add([pscustomobject]@{
            File = $ref.File
            Year = $ref.Year
            Field = $ref.Field
            Url = $url
            Ok = $check.Ok
            StatusCode = $check.StatusCode
            Method = $check.Method
            FinalUrl = $check.FinalUrl
            Error = $check.Error
        })
    }
}

$brokenResults = @($results | Where-Object { -not $_.Ok })
$brokenUrls = @($brokenResults | Select-Object -ExpandProperty Url -ErrorAction SilentlyContinue | Sort-Object -Unique)
$fileCount = [int]$files.Count
$uniqueUrlCount = [int](@($uniqueUrls).Length)
$refCount = [int]$results.Count
$brokenRefCount = [int](@($brokenResults).Length)
$brokenUrlCount = [int](@($brokenUrls).Length)

$summary = [pscustomobject]@{
    FileCount = $fileCount
    UniqueUrlCount = $uniqueUrlCount
    RefCount = $refCount
    BrokenRefCount = $brokenRefCount
    BrokenUrlCount = $brokenUrlCount
}

$reportJson = [pscustomobject]@{
    Summary = $summary
    Broken = @($brokenResults | Sort-Object File, Year, Field, Url)
} | ConvertTo-Json -Depth 6

if ($OutFile) {
    $reportJson | Set-Content -Path $OutFile -Encoding UTF8
}

$reportJson
