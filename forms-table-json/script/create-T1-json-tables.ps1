<#
create-T1-json-tables.ps1

Generate per-form JSON table data files from a bilingual template.
Defaults are resolved from this script's folder so it can be executed
from any current working directory.

Logic Map
1) Resolve input/template paths and output folder.
2) Load forms list and template text (preserve template encoding/newlines).
3) Phase 1: Generate all output JSON files from template first.
4) Optional pause/stop before link checking for manual inspection.
5) Phase 2: For each generated form JSON, validate EN/FR pairs:
   - Normalize existing "Not available" (NA) markers to symmetric EN+FR NA.
   - Validate generated EN+FR URLs (HEAD -> GET, status 200-399).
   - If either side fails, mark pair as EN+FR NA.
   - If all bilingual pairs in a year row are NA, rewrite that whole row as
     "Not applicable" / "Pas applicable".
6) Write validated output using preserved template encoding/newline style (or print DryRun summary).
#>

[CmdletBinding()]
param(
  [string]$FormsListPath = ".\\recent-T1-forms-9yrs.txt",
  [string]$TemplatePath = ".\\template-table-data.json",
  [string]$OutputDir,
  [int]$TimeoutSec = 12,
  [switch]$GenerateOnly,
  [switch]$PauseBeforeLinkCheck,
  [switch]$DryRun
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Resolve a required file path from:
# 1) absolute path as-is
# 2) path relative to this script's folder
# 3) path relative to current working directory
# Throws when not found so failures are explicit and early.
function Resolve-ExistingPath {
  param(
    [Parameter(Mandatory)] [string]$PathValue,
    [Parameter(Mandatory)] [string]$BaseDir
  )

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    if (-not (Test-Path -LiteralPath $PathValue)) {
      throw "Required file not found: $PathValue"
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

  throw "Required file not found: $PathValue"
}

# Resolve a directory path relative to script folder when not absolute.
# We allow non-existing directories here because callers may create them.
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

# Read form codes, trim whitespace, and optionally skip commented lines.
# Comment lines begin with '#', matching the pattern used in the forms list.
function Get-FormsList {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [switch]$SkipComments
  )

  $forms = Get-Content -LiteralPath $Path |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and $_ -ne '' }

  if ($SkipComments) {
    $forms = $forms | Where-Object { -not $_.StartsWith('#') }
  }

  return $forms
}

# Read file bytes and preserve source encoding + trailing newline style.
# This prevents noisy formatting/encoding diffs when writing output.
function Read-TextFilePreserveEncoding {
  param([Parameter(Mandatory)] [string]$Path)

  function Get-TrailingNewlines([string]$s) {
    $m = [regex]::Match($s, '((?:\r\n|\n|\r)+)$')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
  }

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -eq 0) {
    return [pscustomobject]@{
      Text             = ''
      Encoding         = [System.Text.UTF8Encoding]::new($false)
      TrailingNewlines = ''
    }
  }

  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    return [pscustomobject]@{
      Text             = $text
      Encoding         = [System.Text.UTF8Encoding]::new($true)
      TrailingNewlines = Get-TrailingNewlines $text
    }
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    return [pscustomobject]@{
      Text             = $text
      Encoding         = [System.Text.Encoding]::Unicode
      TrailingNewlines = Get-TrailingNewlines $text
    }
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
    $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    return [pscustomobject]@{
      Text             = $text
      Encoding         = [System.Text.Encoding]::BigEndianUnicode
      TrailingNewlines = Get-TrailingNewlines $text
    }
  }

  $utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
  try {
    $text = $utf8Strict.GetString($bytes)
    return [pscustomobject]@{
      Text             = $text
      Encoding         = [System.Text.UTF8Encoding]::new($false)
      TrailingNewlines = Get-TrailingNewlines $text
    }
  } catch {
    $text = [System.Text.Encoding]::Default.GetString($bytes)
    return [pscustomobject]@{
      Text             = $text
      Encoding         = [System.Text.Encoding]::Default
      TrailingNewlines = Get-TrailingNewlines $text
    }
  }
}

# Write text back with original encoding and original trailing newlines.
# We normalize internal trailing newline runs first, then re-append original tail.
function Write-TextFileWithEncoding {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string]$Text,
    [Parameter(Mandatory)] [System.Text.Encoding]$Encoding,
    [string]$TrailingNewlines = ''
  )
  $normalized = [regex]::Replace($Text, '(?:\r\n|\n|\r)+$', '')
  $toWrite = $normalized + $TrailingNewlines
  [System.IO.File]::WriteAllText($Path, $toWrite, $Encoding)
}

# URL validator used by link-check logic.
# Behavior intentionally mirrors the HTML workflow:
# - Try HEAD first
# - If HEAD fails, try GET
# - Count as valid on HTTP 200-399
# - No retry/backoff here (caller controls timeout only)
function Test-Url200 {
  param([Parameter(Mandatory)] [string]$Url, [int]$TimeoutSec = 10)

  function Get-HttpStatusFromError {
    param([Parameter(Mandatory)] $ErrorRecord)
    try {
      $resp = $ErrorRecord.Exception.Response
      if ($null -eq $resp) { return $null }
      if ($resp -is [System.Net.HttpWebResponse]) { return [int]$resp.StatusCode }
      if ($resp.PSObject.Properties.Name -contains 'StatusCode') { return [int]$resp.StatusCode }
    } catch {
      return $null
    }
    return $null
  }

  try {
    $resp = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop
    if ($resp.StatusCode -ge 200 -and $resp.StatusCode -le 399) { return $true }
  } catch {
    $headStatus = Get-HttpStatusFromError -ErrorRecord $_
    if ($headStatus -ge 200 -and $headStatus -le 399) { return $true }
  }

  try {
    $resp2 = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop
    if ($resp2.StatusCode -ge 200 -and $resp2.StatusCode -le 399) { return $true }
  } catch {
    $getStatus = Get-HttpStatusFromError -ErrorRecord $_
    if ($getStatus -ge 200 -and $getStatus -le 399) { return $true }
    return $false
  }
  return $false
}

# Escape dynamic strings before inserting into regex patterns.
function Get-RegexEscaped {
  param([Parameter(Mandatory)] [string]$Value)
  return [regex]::Escape($Value)
}

# Replace a single JSON array property in the object that matches a given year.
# We update the source JSON text directly to preserve the template's formatting style.
# This avoids pretty-print reformatting that ConvertTo-Json would cause.
function Replace-ArrayInYearObject {
  param(
    [Parameter(Mandatory)] [string]$JsonText,
    [Parameter(Mandatory)] [string]$Year,
    [Parameter(Mandatory)] [string]$KeyName,
    [Parameter(Mandatory)] [string]$NewArrayJson
  )

  $yearPattern = '"year"\s*:\s*"' + (Get-RegexEscaped $Year) + '"'
  $objPattern = '\{(?<obj>[^{}]*' + $yearPattern + '.*?)[\r\n ]*\}'
  $objMatch = [regex]::Match($JsonText, $objPattern, 'Singleline')
  if (-not $objMatch.Success) { return $JsonText }

  $objText = $objMatch.Value
  # Accept both array and legacy string value so NA normalization can recover
  # from either form and always write back as an array.
  $keyPattern = '"' + (Get-RegexEscaped $KeyName) + '"\s*:\s*(\[[^\]]*\]|"[^"]*")'
  $newObjText = [regex]::Replace($objText, $keyPattern, '"' + $KeyName + '": ' + $NewArrayJson, 1)

  if ($newObjText -eq $objText) { return $JsonText }

  return $JsonText.Substring(0, $objMatch.Index) + $newObjText + $JsonText.Substring($objMatch.Index + $objMatch.Length)
}

# Return the URL element from a pair-shaped value:
# ["label", "url"] -> "url"
# Single-item arrays (NA) and scalars return $null.
function Get-LinkUrl {
  param([object]$Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [string]) { return $null }
  if ($Value -is [object[]] -and $Value.Count -ge 2) {
    return [string]$Value[1]
  }
  return $null
}

# If a FR link fails that contains the historical 51xx token, try swapping to 50xx and re-checking.
# Note: This is very UNLIKELY to happen. There are none such cases within the 10 prior years only data we have in 2026.
# We are applying it anyway as we should be aware of possible inconsistencies in the file naming.
# The checks should be rare and should not increase runtime significantly.
function Get-French50xxFallbackPair {
  param(
    [object]$FrValue,
    [Parameter(Mandatory)] [string]$Form,
    [Parameter(Mandatory)] [string]$FrPre2019
  )

  if ($null -eq $FrValue) { return $null }
  if (-not ($FrValue -is [object[]] -and $FrValue.Count -ge 2)) { return $null }

  $label = [string]$FrValue[0]
  $url = [string]$FrValue[1]
  if ([string]::IsNullOrWhiteSpace($url)) { return $null }
  if (-not $url.Contains($FrPre2019)) { return $null }

  $fallbackUrl = $url.Replace($FrPre2019, $Form)
  if ($fallbackUrl -eq $url) { return $null }

  $fallbackLabel = $label
  if (-not [string]::IsNullOrWhiteSpace($fallbackLabel)) {
    $fallbackLabel = $fallbackLabel.Replace($FrPre2019, $Form)
  }

  return @($fallbackLabel, $fallbackUrl)
}

# Detect language-specific "Not available" markers.
function Is-NotAvailablePair {
  param([object]$Value, [string]$Lang)
  if ($null -eq $Value) { return $false }
  if ($Value -is [object[]] -and $Value.Count -eq 1) {
    if ($Lang -eq 'en') { return ($Value[0] -eq 'Not available') }
    if ($Lang -eq 'fr') { return ($Value[0] -eq 'Pas disponible') }
  }
  return $false
}

function Is-NotApplicablePair {
  param([object]$Value, [string]$Lang)
  if ($null -eq $Value) { return $false }
  if ($Value -is [object[]] -and $Value.Count -eq 1) {
    if ($Lang -eq 'en') { return ($Value[0] -eq 'Not applicable') }
    if ($Lang -eq 'fr') { return ($Value[0] -eq 'Pas applicable') }
  }
  return $false
}

function Is-UnavailablePair {
  param([object]$Value, [string]$Lang)
  return (Is-NotAvailablePair -Value $Value -Lang $Lang) -or (Is-NotApplicablePair -Value $Value -Lang $Lang)
}

# Serialize an array into compact inline JSON (e.g. ["a","b"]).
# Used when writing per-cell replacements back into the raw JSON text.
function Convert-ArrayToInlineJson {
  param([Parameter(Mandatory)] [object[]]$Value)
  return ($Value | ConvertTo-Json -Compress)
}

function Get-RowPairBases {
  param([Parameter(Mandatory)] [psobject]$Row)
  return @($Row.PSObject.Properties | ForEach-Object { $_.Name }) |
    Where-Object { $_ -match '_(en|fr)$' } |
    ForEach-Object { $_ -replace '_(en|fr)$', '' } |
    Sort-Object -Unique
}

function Set-PairInRowAndJson {
  param(
    [Parameter(Mandatory)] [psobject]$Row,
    [Parameter(Mandatory)] [string]$YearValue,
    [Parameter(Mandatory)] [string]$EnKey,
    [Parameter(Mandatory)] [object[]]$EnValue,
    [Parameter(Mandatory)] [string]$FrKey,
    [Parameter(Mandatory)] [object[]]$FrValue,
    [Parameter(Mandatory)] [ref]$JsonTextRef
  )

  $Row.$EnKey = $EnValue
  $Row.$FrKey = $FrValue
  $jsonText = [string]$JsonTextRef.Value
  $jsonText = Replace-ArrayInYearObject -JsonText $jsonText -Year $YearValue -KeyName $EnKey -NewArrayJson (Convert-ArrayToInlineJson -Value $EnValue)
  $jsonText = Replace-ArrayInYearObject -JsonText $jsonText -Year $YearValue -KeyName $FrKey -NewArrayJson (Convert-ArrayToInlineJson -Value $FrValue)
  $JsonTextRef.Value = $jsonText
}

function Set-PairToNotAvailable {
  param(
    [Parameter(Mandatory)] [psobject]$Row,
    [Parameter(Mandatory)] [string]$YearValue,
    [Parameter(Mandatory)] [string]$EnKey,
    [Parameter(Mandatory)] [string]$FrKey,
    [Parameter(Mandatory)] [ref]$JsonTextRef
  )

  Set-PairInRowAndJson -Row $Row -YearValue $YearValue -EnKey $EnKey -EnValue $EN_NA -FrKey $FrKey -FrValue $FR_NA -JsonTextRef $JsonTextRef
}

function Set-PairToNotApplicable {
  param(
    [Parameter(Mandatory)] [psobject]$Row,
    [Parameter(Mandatory)] [string]$YearValue,
    [Parameter(Mandatory)] [string]$EnKey,
    [Parameter(Mandatory)] [string]$FrKey,
    [Parameter(Mandatory)] [ref]$JsonTextRef
  )

  Set-PairInRowAndJson -Row $Row -YearValue $YearValue -EnKey $EnKey -EnValue $EN_NAP -FrKey $FrKey -FrValue $FR_NAP -JsonTextRef $JsonTextRef
}

function Normalize-NaArrayLiterals {
  param([Parameter(Mandatory)] [string]$JsonText)
  $out = $JsonText
  $out = [regex]::Replace($out, '("(?<k>[^"]+_en)"\s*:\s*)"Not available"', '$1["Not available"]')
  $out = [regex]::Replace($out, '("(?<k>[^"]+_fr)"\s*:\s*)"Pas disponible"', '$1["Pas disponible"]')
  $out = [regex]::Replace($out, '("(?<k>[^"]+_en)"\s*:\s*)"Not applicable"', '$1["Not applicable"]')
  $out = [regex]::Replace($out, '("(?<k>[^"]+_fr)"\s*:\s*)"Pas applicable"', '$1["Pas applicable"]')
  return $out
}

$EN_NA = @('Not available')
$FR_NA = @('Pas disponible')
$EN_NAP = @('Not applicable')
$FR_NAP = @('Pas applicable')

$FormsListPath = Resolve-ExistingPath -PathValue $FormsListPath -BaseDir $scriptRoot
$TemplatePath = Resolve-ExistingPath -PathValue $TemplatePath -BaseDir $scriptRoot

# Default output folder: sibling "tables" directory next to script folder.
if (-not $PSBoundParameters.ContainsKey('OutputDir') -or [string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path $scriptRoot '..\\tables'
} else {
  $OutputDir = Resolve-DirectoryPath -PathValue $OutputDir -BaseDir $scriptRoot
}
[System.IO.Directory]::CreateDirectory($OutputDir) | Out-Null

$formsForGeneration = Get-FormsList -Path $FormsListPath -SkipComments
if (-not $formsForGeneration) {
  throw "No form codes found in $FormsListPath"
}

$templateFile = Read-TextFilePreserveEncoding -Path $TemplatePath
$templateText = $templateFile.Text

$generatedTotal = 0
Write-Host "Step 1/2: Generating JSON files from template..." -ForegroundColor Cyan

foreach ($form in $formsForGeneration) {
  if ($form -notmatch '^\d{4}-.+$') {
    Write-Warning "Skipping invalid form code: '$form'"
    continue
  }

  $first4 = [int]$form.Substring(0,4)
  $suffix = $form.Substring(4)
  $formPlus100 = ($first4 + 100).ToString() + $suffix
  $outJson = $templateText.Replace('5000-s2', $form).Replace('5100-s2', $formPlus100)
  $outPath = Join-Path $OutputDir "$form-table-data.json"

  try {
    $null = $outJson | ConvertFrom-Json
  } catch {
    throw "Invalid JSON after replacement for $form. $($_.Exception.Message)"
  }

  if ($DryRun) {
    Write-Host "[DRY RUN] $form => would write $outPath"
  } else {
    Write-TextFileWithEncoding -Path $outPath -Text $outJson -Encoding $templateFile.Encoding -TrailingNewlines $templateFile.TrailingNewlines
  }
  $generatedTotal++
}

Write-Host "Done. Generated $generatedTotal JSON file(s) in '$OutputDir'." -ForegroundColor Cyan

if ($GenerateOnly) {
  Write-Host "Generate-only mode enabled. Skipping link validation." -ForegroundColor Yellow
  return
}

if ($PauseBeforeLinkCheck -and -not $DryRun) {
  $answer = (Read-Host "Files generated. Validate links now? [Y/N]").Trim().ToLowerInvariant()
  if ($answer -notin @('y', 'yes')) {
    Write-Host "Skipped link validation by user choice." -ForegroundColor Yellow
    return
  }
}

Write-Host "Step 2/2: Validating bilingual links..." -ForegroundColor Cyan
$validatedTotal = 0

foreach ($form in $formsForGeneration) {
  if ($form -notmatch '^\d{4}-.+$') {
    continue
  }

  $outPath = Join-Path $OutputDir "$form-table-data.json"
  $first4 = [int]$form.Substring(0,4)
  $suffix = $form.Substring(4)
  # Historical alternate family token replacement used during generation.
  $frPre2019 = ($first4 + 100).ToString() + $suffix

  if ($DryRun) {
    $jsonSourceText = $templateText.Replace('5000-s2', $form).Replace('5100-s2', $frPre2019)
    $sourceEncoding = $templateFile.Encoding
    $sourceTrailingNewlines = $templateFile.TrailingNewlines
  } else {
    if (-not (Test-Path -LiteralPath $outPath)) {
      Write-Warning "Generated file missing for $form ($outPath). Skipping validation."
      continue
    }
    $generatedFile = Read-TextFilePreserveEncoding -Path $outPath
    $jsonSourceText = $generatedFile.Text
    $sourceEncoding = $generatedFile.Encoding
    $sourceTrailingNewlines = $generatedFile.TrailingNewlines
  }

  try {
    $jsonObj = $jsonSourceText | ConvertFrom-Json
  } catch {
    throw "Invalid generated JSON for $form. $($_.Exception.Message)"
  }
  $outJsonFinal = $jsonSourceText
  $changedPairs = 0

  if ($null -eq $jsonObj.data) {
    throw "Generated JSON missing 'data' array for $form."
  }

  foreach ($row in $jsonObj.data) {
    $yearValue = [string]$row.year
    # Discover all bilingual pair bases dynamically:
    # fill_pdf_en/fill_pdf_fr -> base "fill_pdf", etc.
    $bases = Get-RowPairBases -Row $row

    foreach ($base in $bases) {
      $enKey = "${base}_en"
      $frKey = "${base}_fr"
      if (-not ($row.PSObject.Properties.Name -contains $enKey)) { continue }
      if (-not ($row.PSObject.Properties.Name -contains $frKey)) { continue }

      $enVal = $row.$enKey
      $frVal = $row.$frKey

      # If one side is already marked NA, normalize both sides to NA for symmetry.
      $enIsNA = Is-NotAvailablePair -Value $enVal -Lang 'en'
      $frIsNA = Is-NotAvailablePair -Value $frVal -Lang 'fr'
      if ($enIsNA -or $frIsNA) {
        Set-PairToNotAvailable -Row $row -YearValue $yearValue -EnKey $enKey -FrKey $frKey -JsonTextRef ([ref]$outJsonFinal)
        $changedPairs++
        continue
      }

      $enUrl = Get-LinkUrl -Value $enVal
      $frUrl = Get-LinkUrl -Value $frVal

      # Primary pass: validate links exactly as listed in template/output.
      $enValid = $false
      $frValid = $false
      if ($enUrl) { $enValid = Test-Url200 -Url $enUrl -TimeoutSec $TimeoutSec }
      if ($frUrl) { $frValid = Test-Url200 -Url $frUrl -TimeoutSec $TimeoutSec }

      # If only FR failed and it uses the historical 51xx token, try 50xx fallback.
      if ($enValid -and -not $frValid) {
        $frFallbackPair = Get-French50xxFallbackPair -FrValue $frVal -Form $form -FrPre2019 $frPre2019
        if ($null -ne $frFallbackPair) {
          $frFallbackUrl = Get-LinkUrl -Value $frFallbackPair
          $frFallbackValid = $false
          if ($frFallbackUrl) { $frFallbackValid = Test-Url200 -Url $frFallbackUrl -TimeoutSec $TimeoutSec }
          if ($frFallbackValid) {
            Set-PairInRowAndJson -Row $row -YearValue $yearValue -EnKey $enKey -EnValue @($enVal) -FrKey $frKey -FrValue @($frFallbackPair) -JsonTextRef ([ref]$outJsonFinal)
            $changedPairs++
            continue
          }
        }
      }

      # Happy path: both links are live, leave as-is.
      if ($enValid -and $frValid) { continue }

      # Pair-level rule: if either side fails, mark pair as unavailable.
      if (-not ($enValid -and $frValid)) {
        Set-PairToNotAvailable -Row $row -YearValue $yearValue -EnKey $enKey -FrKey $frKey -JsonTextRef ([ref]$outJsonFinal)
        $changedPairs++
      }
    }

    # If all bilingual pairs in this year are unavailable, promote the whole row
    # from "Not available" to "Not applicable".
    $allPairsUnavailable = $true
    foreach ($base in $bases) {
      $enKey = "${base}_en"
      $frKey = "${base}_fr"
      if (-not ($row.PSObject.Properties.Name -contains $enKey)) { continue }
      if (-not ($row.PSObject.Properties.Name -contains $frKey)) { continue }

      $enIsUnavailable = Is-UnavailablePair -Value $row.$enKey -Lang 'en'
      $frIsUnavailable = Is-UnavailablePair -Value $row.$frKey -Lang 'fr'
      if (-not ($enIsUnavailable -and $frIsUnavailable)) {
        $allPairsUnavailable = $false
        break
      }
    }

    if ($allPairsUnavailable -and $bases.Count -gt 0) {
      foreach ($base in $bases) {
        $enKey = "${base}_en"
        $frKey = "${base}_fr"
        if (-not ($row.PSObject.Properties.Name -contains $enKey)) { continue }
        if (-not ($row.PSObject.Properties.Name -contains $frKey)) { continue }

        $enAlreadyNap = Is-NotApplicablePair -Value $row.$enKey -Lang 'en'
        $frAlreadyNap = Is-NotApplicablePair -Value $row.$frKey -Lang 'fr'
        if ($enAlreadyNap -and $frAlreadyNap) { continue }

        Set-PairToNotApplicable -Row $row -YearValue $yearValue -EnKey $enKey -FrKey $frKey -JsonTextRef ([ref]$outJsonFinal)
        $changedPairs++
      }
    }
  }

  if ($DryRun) {
    Write-Host "[DRY RUN] $form => would modify $changedPairs pair(s) in $outPath"
  } else {
    # Persist using source file encoding/newline style to keep output stable.
    $outJsonFinal = Normalize-NaArrayLiterals -JsonText $outJsonFinal
    Write-TextFileWithEncoding -Path $outPath -Text $outJsonFinal -Encoding $sourceEncoding -TrailingNewlines $sourceTrailingNewlines
    Write-Host "$form => modified $changedPairs pair(s)."
  }
  $validatedTotal++
}

Write-Host "Done. Validated $validatedTotal JSON file(s)." -ForegroundColor Green
