<######################################################################### 
 #####################  AEM EDDS ASSET PACKAGER            ###############
 #####################  Developed by: Amber LeBlanc        ###############
 #####################  Latest update: 2022-02-16          ###############
 #####################  Last updated by: Mathieu Bergeron  ###############
 #####################  Version: 3.3                       ###############
 #########################################################################>

<#
.SYNOPSIS
  Builds and AEM readable package for EDDS assets

.DESCRIPTION
  Gets files from the "db" folder, and uses information from the "lib" folder to build 
  an AEM readable package in the "data" folder. This package is automatically zipped &
  ready for upload to AEM. A text file with a list of assets and pages to clear from 
  the cache is also produced.

.INPUTS
    Two XML files that contain the .content.xml templates for folders and files
    stored as ~\A2GC\lib\file.content.xml
              ~\A2GC\lib\folder.content.xml

    PDFs, Text, and Braille files that are replaced daily with content from the iCMS readme.zip file
    stored as ~\A2GC\db\pub\FOLDER\FILES
              ~\A2GC\db\pbg\FOLDER\FILES
              example: ~\A2GC\db\pub\t4002\t4002-18e.pdf

    One CSV that contains all known publication url's that are owned by Canada Revenue Agency
    stored as ~\A2GC\lib\findchildnodes-allPublications.csv

.OUTPUTS
    Log file stored in ~\A2GC\log\logs.log
    
    One CSV that contains all parent nodes
    stored as ~\A2GC\lib\findchildnodes-parentNodes.csv
    
    Two text files with a list of AEM paths that need to be cleared from the cache (assets & pages)    
    stored as ~\A2GC\CRA-formspubs-assets-in-#.#.txt
              ~\A2GC\CRA-formspubs-pages-in-#.#.txt
              
    One zip file that contains an AEM readable package with all of the assets  
    stored as ~\A2GC\CRA-formspubs-assets-in-#.#.zip

.NOTES
  Version:        3.0
  Author:         Amber LeBlanc
  Creation Date:  2018-10-22 
  Purpose/Change: Initial script development
  Modified Date:  2018-12-18
  Purpose/Change: Added an additional txt file output with a list of assets to clear from the cache
  Modified Date:  2019-01-24
  Purpose/Change: Added logging functions, optimized code, & added an additional txt file output with a list of pages to clear from the cache
  Modified Date:  2019-03-27
  Purpose/Change: Version number is now synced to D2GC. A2GC will differentiate between English/French files and apply some metadata.
  Modified Date:  2020-11-16
  Purpose/Change: Added "jcr:mimeType" property to file template b/c AEM 6.5 defaults to “application/octet-stream” which is treated as general binary files, resulting in a “downloading” PDF instead of “opening” due to a security measure
  Modified Date:  2020-12-21
  Purpose/Change: Removed "jcr:mimeType" property from file template & included it in new original content.xml template
  Modified Date:  2022-02-16
  Purpose/Change: Updated Alt format to read as UTF8 to fix an issue with .txt files getting corrupted
  
#>

#---------------------------------------------------------[Initialisations]--------------------------------------------------------

#Set Error Action to Silently Continue
$ErrorActionPreference = "SilentlyContinue"

#Dot Source required path
$dotSourcePath = $PSScriptRoot + "\lib\Logging_Functions.ps1"

#Dot Source required Function Libraries
. $dotSourcePath

#----------------------------------------------------------[Declarations]----------------------------------------------------------

#Script Version
$scriptVersion = "3" #increment this value by one each time a new version is shared with the team, one digit only
$sScriptVersion = "3.2"
$sScriptModDate = "2020-12-21"
$sScriptModBy = "Amber LeBlanc"
$sScriptUser = $env:UserName.ToLower()

#Sets the date for properties.xml and content.xml files
$date = (Get-Date).ToString("yyyy-MM-dd" +"T" +"HH:mm:ss.fff" + "-04:00")
$shortDate = (get-date).ToString('yyyy-MM-dd')

#Script Path
#$path="C:\Amber-tools\Scripts\D2GC-version-2019-01-24\A2GC"
$path = $PSScriptRoot

#Log File Info
$sLogPath = $PSScriptRoot + "\log\"
$sLogName = "log-" + $shortDate + ".txt"
$sLogFile = Join-Path -Path $sLogPath -ChildPath $sLogName

#Set up a global counter
$Global:counter = 0;

#DB folder
$dbPath = $path + "\db"
$dbpubPath = $dbPath + "\pub";
$dbpbgPath = $dbPath + "\pbg";

#Data folder
$dataPath = $path + "\data"

#library paths
$folderXMLPath = $path + "\lib\folder.content.xml"
$fileXMLPath = $path + "\lib\file.content.xml"
$originalXMLPath = $path + "\lib\original.content.xml" #2020-12-21
$propXMLPath = $path + "\lib\properties.xml"
$allPubsPath = $path + "\lib\findchildnodes-allPublications.csv"

$folderXML = Get-Content -Path $folderXMLPath -Encoding UTF8 -Raw
$fileXML = Get-Content -Path $fileXMLPath -Encoding UTF8 -Raw
$originalXML = Get-Content -Path $originalXMLPath -Encoding UTF8 -Raw #2020-12-21

#Package folders
$pbgPath = $dataPath + "\jcr_root\content\dam\cra-arc\formspubs\pbg" #required!!!!
$pubPath = $dataPath + "\jcr_root\content\dam\cra-arc\formspubs\pub" #required!!!!
$formpubPath = $dataPath + "\jcr_root\content\dam\cra-arc\formspubs"
$filterPath = $dataPath + "\META-INF\vault\filter.xml"
$propPath = $dataPath + "\META-INF\vault\properties.xml"

#Path variables
$bs = "\"
$fs = "/"
$end = "\_jcr_content\renditions\"

#XML filter array initialization
[System.Collections.ArrayList]$xmlFilter = @()
$xmlFilter.Add('<?xml version="1.0" encoding="UTF-8"?>
<workspaceFilter version="1.0">') | Out-Null

#Cache list array initialization for assets
[System.Collections.ArrayList]$fileList = @()

#Cache list array initialization for pages
[System.Collections.ArrayList]$parentpageList = @()
[System.Collections.ArrayList]$allpageList = @()

#Parent & D2GC filter & properties path
$parentPath = (get-item $path ).parent.FullName
$D2GCfilterpath = $parentPath + "\D2GC\data\META-INF\vault\filter.xml"
$D2GCproppath = $parentPath + "\D2GC\data\META-INF\vault\properties.xml"

#-----------------------------------------------------------[Functions]------------------------------------------------------------

#Creates DAM file structure (data), copies/renames forms & publications from the source folder (db) to the correct location, & creates content.xml files
function buildDAM{
  Param($FORMPUB)
  
  Begin{
    Log-Write -LogPath $sLogFile -LineValue "Creating DAM file structure [$FORMPUB]"
  }
  
  Process{
  Try{
  
  $dbformpubPath = $dbPath + $fs + $FORMPUB

  Get-ChildItem -Path $dbformpubPath -Dir -r | ForEach-Object {
    
    #Sets folder/file paths
    $folderName = $_ ; # Folder name (eg. "t4002")
    $folderPath = $($_.FullName) ; # Folder path (eg. "D:\PS-Test\asset-packager\db\pub\t4002") - not used???
     
    #Adds to xml filter array
    $formpubFilter = '<filter root="/content/dam/cra-arc/formspubs/' + $FORMPUB + $fs + $folderName + '" mode="update"/>' ;
    $xmlFilter.Add($formpubFilter) ;
    Write-Host "$formpubFilter" ;
    
    #Creates folders and modifies content.xml files
    $folderCXMLPath = $formpubPath + $bs + $FORMPUB + $bs + $folderName ;
    md $folderCXMLPath | out-null ;
    $folderXML -replace "FOLDERNAME", "$folderName" | Set-Content -Path $folderCXMLPath\.content.xml -Encoding UTF8;
    
    Get-ChildItem -Path $folderPath | ForEach-Object {

        #Sets folder/file paths
        $fileName = $_.Name ; #File name (eg. "t4002-17e.txt")
        $sourcePath = $($_.FullName) ; # Source file path (eg. D:\PS-Test\asset-packager\db\pub\t4002\t4002-17e.txt)
        $destinationPath = $folderCXMLPath + $bs + $fileName + $end ; ### Destination folder path (eg. D:\PS-Test\asset-packager\data\jcr_root\content\dam\cra-arc\formspubs\pub\t4002\t4002-17e.txt\_jcr_content\renditions\)
        $destinationFile = $destinationPath + $fileName ; # Destination file path (eg. D:\PS-Test\asset-packager\data\jcr_root\content\dam\cra-arc\formspubs\pub\t4002\t4002-17e.txt\_jcr_content\renditions\t4002-17e.txt)
                
        #Determines if file is English or French (for metadata update)
        $langLoc = ($filename.Length) - 5;
        $language = $filename.Substring($langLoc,1)
        If($language -eq "e"){$lang = "en"; $author = "Canada Revenue Agency"}
        ElseIf($language -eq "f"){$lang = "fr"; $author = "Agence du revenu du Canada"}
        Else{$lang = "en"; $author = "Canada Revenue Agency"; Write-Host "$filename did not contain 'e' or 'f'. English will be used in the metadata." -ForegroundColor red}
        
        #Updates list of DAM paths
        $formpubFiles = 'https://www.canada.ca/content/dam/cra-arc/formspubs/' + $FORMPUB + $fs + $folderName + $fs + $fileName ;
        $fileList.Add($formpubFiles) | out-null ; 
        
        #Creates folders and files
        md $destinationPath | out-null ;         
        Copy-Item -Path $sourcePath -Destination $destinationPath ;
        Rename-Item -Path $destinationFile -NewName "original" ;
        
        #Gets file extension
        $test = "$fileName"
        $base,$extension = $test.Split("{.}")
        
        #Modifies .content.xml file
        $fileCXMLPath = $folderCXMLPath + $bs + $fileName ;
        $fileXML -replace "FILENAME", "$fileName" `
                 -replace "FOLDERNAME", "$folderName" `
                 -replace "CURRENTDATE", "$date" `
                 -replace "FILETYPE", "$extension" `
                 -replace "FORMPUB", "$FORMPUB" `
                 -replace "USERNAME", "$username" `
                 -replace "CRAAUTHOR", "$author" `
                 -replace "CRALANG", "$lang" `
        | Set-Content -Path $fileCXMLPath\.content.xml -Encoding UTF8;
        
        #Modifies original.content.xml file and copies to subfolder under renditions (for new jrc:mimeType property) #2020-12-21
        md $destinationPath\original.dir | out-null
        $originalXML -replace "USERNAME", "$username" `
                     -replace "FILETYPE", "$extension" `
        | Set-Content -Path $destinationPath\original.dir\.content.xml -Encoding UTF8;
                
        }
    #Updates Log
    $upperName = "$folderName".ToUpper();
    Log-Write -LogPath $sLogFile -LineValue "$upperName - $folderCXMLPath";

    }


        }
    
    Catch{
      Log-Error -LogPath $sLogFile -ErrorDesc $_.Exception -ExitGracefully $True
      Break
    }
  }
  
  End{
    If($?){
      Log-Write -LogPath $sLogFile -LineValue "Completed Successfully."
      Log-Write -LogPath $sLogFile -LineValue " "
    }
  }
}

#Borrowed from Mandré's awesome "FindChildNodes" script! This function compares two csv's and returns child nodes. 
Function getChildrenCSV{
  Param($AllPgs, $PrntNodes)
  
  Begin{
    Log-Write -LogPath $sLogFile -LineValue ""
    Log-Write -LogPath $sLogFile -LineValue "Creating regex and comparing regex with all pages..."
  }
  
  Process{
    Try{
      $referenceRegex = [string]::Join('|', $PrntNodes.Links)
      $childPages = $AllPgs | where {$_.Links -match $referenceRegex; updateProgressBar}
      return $childPages
    }
    
    Catch{
      Log-Error -LogPath $sLogFile -ErrorDesc $_.Exception -ExitGracefully $True
      Break
    }
  }
  
  End{
    If($?){
      Log-Write -LogPath $sLogFile -LineValue "Completed Successfully."
      Log-Write -LogPath $sLogFile -LineValue " "
    }
  }
}

#Borrowed from Mandré's awesome "FindChildNodes" script!
Function updateProgressBar{
 
    $numPages = $AllPgs.Links.length

    [int]$interval = $numPages * 0.1
 
    if ($Global:counter % $interval -eq 0) 
    {
      Write-Progress -Activity Searching -Status "Finding child pages" -PercentComplete (($Global:counter/$numPages)*100)
    }

  
  $Global:counter++
}

#-----------------------------------------------------------[Execution]------------------------------------------------------------

#Updates Log
Log-Start -LogPath $sLogPath -LogName $sLogName -ScriptVersion $ScriptVersion
Log-Write -LogPath $sLogFile -LineValue "A2GC (Assets to Government of Canada)
-------------------------------------"

Write-Host "
 
 
 
               ,,))))))));,
            __)))))))))))))),
 \|/       -\(((((''''((((((((.
 -*-==//////((''  .     `)))))),
 /|\      ))| o    ;-.    '(((((                                  ,(,
          ( `|    /  )    ;))))'                               ,_))^;(~
             |   |   |   ,))((((_     _____------~~~-.        %,;(;(>';'~
             o_);   ;    )))(((` ~---~  `::           \      %%~~)(v;(`('~
                   ;    ''''````         `:       `:::|\,__,%%    );`'; ~
                  |   _                )     /      `:|`----'     `-'
            ______/\/~    |                 /        /
          /~;;.____/;;'  /          ___--,-(   `;;;/
         / //  _;______;'------~~~~~    /;;/\    /
        //  | |                        / ;   \;;,\
       (<_  | ;                      /',/-----'  _>
        \_| ||_                     //~;~~~~~~~~~
            `\_|                   (,~~  
                                    \~\
                                     ~~
                  
                  
                 " -ForegroundColor "magenta"


Write-Host "A2GC (Assets to Government of Canada)" -ForegroundColor "White"
Write-Host "-----------------------------------`r"

################ CONFIRM SCRIPT LOCATION BEFORE DELETIONS ################

#Warns user if modified page file is out of date and gives option to exit without generating a report
Write-Host "`nWARNING: Previous days assets will be deleted from $pubPath & \pbg" -ForegroundColor Yellow 
Write-host "`nIs this the correct data path? (Default is Yes)`n" -ForegroundColor Yellow 
    $Readhost = Read-Host " ( y / n ) " 
    Switch ($ReadHost) 
     { 
       Y {Write-host "`nYes, continue`n"; $continue=$true} 
       N {Write-Host "`nNo, exit`n"; $continue=$false} 
       Default {Write-Host "`nDefault, continue`n"; $continue=$true} 
     } 
If ($continue -eq $false) { Exit }

##########################################################################

######################### SETUP CONFIG.INI FILE ##########################

#Gets path of Custom.ps1 from D2GC folder
$d2gcPath = $path -replace "A2GC$", "D2GC\lib\Custom.ps1"
. "$d2gcPath"

#Config functions
function configRH ($string) {
    return Read-Host "Please state your $string"
}
function configIni() {

    $array = [ordered]@{ "username"="AEM Username (eg. amber.leblanc)"; "initials"="initials (eg. al)"; }
    
    foreach($key in @($array.keys)){
        $f = configRH $array.Item($key)
        $array[$key] = $f
    }
    $f = @{“settings”=$array}

    return $f;
}

function displayIni() {
    $a = gic "$path\config.ini"
    $array = [ordered]@{ "AEM Username"=$a["settings"]["username"]; "Initials"=$a["settings"]["initials"]; }

    return $array;
}

#Confirms config.ini is present/correct or allows user to enter values
$configPath = ($path + "\config.ini")
if (Test-Path $configPath) {
    Write-Host "There is a ""config.ini"" file"
    Write-Host "The following is entered in the ""config.ini"" file:`n`r"
    displayIni
    if ( $confirm -ne "true" ) {
        $q = Read-Host "`n`rIs this correct: [Y]es [N]o (default/nil input is ""Yes"")"
    }
    if ($q -eq "n" -or $q -eq "N") {
        Write-Host ""
        Remove-Item ($configPath)
        $config = configIni
        oif -InputObject $config -FilePath ($configPath)
    }
}
else {
    Write-Host "There is no ""config.ini"" file in the folder. This will be a one time entry`n`r"
    $config = configIni
    oif -InputObject $config -FilePath ($configPath)
}

#Gets username and initials from config.ini for use in properties.xml and content.xml files
$configInfo = gic $configPath
$username = $configInfo["settings"]["username"]
$initials = $configInfo["settings"]["initials"]

##########################################################################

####################### CHECKS TOTAL SIZE OF FILES #######################

$pkgSize = ((Get-ChildItem $dbPath -Recurse | Measure-Object -Property Length -Sum -ErrorAction Stop).Sum / 1MB)

$pkgMB = "{0:N2} MB" -f $pkgSize

If ($pkgSize -lt 10) {

Write-Host "`nEstimated final package size: $pkgMB" -ForegroundColor "Green"

}

Else { 

Write-Host "`nEstimated final package size: $pkgMB" -ForegroundColor "Red"

Write-Host "
Note: Packages must be less than 10 MB for same day upload to PROD. Only continue if this package is intended for overnight upload." -ForegroundColor "Yellow"

Write-host "`nDo you want to create the package anyway? (Default is No)`n" -ForegroundColor Yellow 
    $Readhost = Read-Host " ( y / n ) " 
    Switch ($ReadHost) 
     { 
       Y {Write-host "`nYes, continue`n"; $continue=$true} 
       N {Write-Host "`nNo, exit`n"; $continue=$false} 
       Default {Write-Host "`nDefault, exit`n"; $continue=$true} 
     } 
If ($continue -eq $false) { 
#Updates Log
Log-Write -LogPath $sLogFile -LineValue "Estimated final package size: $pkgMB"
Exit }

}

#Updates Log
Log-Write -LogPath $sLogFile -LineValue "Estimated final package size: $pkgMB"

##########################################################################

############ RENAMES ALL ASSET FOLDERS AND FILES TO LOWERCASE ############

Get-ChildItem -Path $dbPath -Recurse | ForEach-Object {
        $full = $_.FullName
        $lower = $_.Name.ToLower()
        #write-host "Renaming:" $_.Name "to" ($_.Name).ToLower()
        Rename-Item $full ($lower+"_2") -PassThru | Rename-Item -NewName $lower
}

##########################################################################

################ CLEARS OLD PACKAGE & CREATES NEW PACKAGE ################

#Updates Log
Log-Write -LogPath $sLogFile -LineValue "
Step 1 of 7: Convert text documents to UTF8
"
Write-Host "`nStep 1 of 7: Convert text documents to UTF8" -ForegroundColor "Cyan"

#Checks if any text files exist
$txtFiles = (Get-ChildItem -Path $dbPath -Include *.txt -Recurse | Measure-Object -ErrorAction Stop).count
 
If ($txtFiles -eq 0) {

#Updates Log
Log-Write -LogPath $sLogFile -LineValue "No text files were found"
Write-Host "`nNo text files were found"

}

Else { 

#Updates Log
Log-Write -LogPath $sLogFile -LineValue "Converted to UTF8:"
Write-Host "`nConverting to UTF8..."
#Changes encoding of source E-text files to UTF8
Get-ChildItem -Path $dbPath -Include *.txt -Recurse | ForEach-Object { (Get-Content $_ -Encoding UTF8 ) | Out-File -FilePath $_ -Encoding UTF8 ; Write-Host "$($_.Name)" ; Log-Write -LogPath $sLogFile -LineValue "$($_.Name)" }

}

#Updates log
Log-Write -LogPath $sLogFile -LineValue "
Step 2 of 7: Remove previous assets from the package

Removed folders:"
Write-Host "`nStep 2 of 7: Remove previous assets from the package" -ForegroundColor "Cyan"
Write-Host "`nRemoving folders..."
#Remove old files from destination path
Get-ChildItem -Path $pubPath -Dir | ForEach-Object { Write-Host "$pubPath\$_" ; Log-Write -LogPath $sLogFile -LineValue "$pubPath\$_" ; Remove-item -Recurse $_.FullName }
Get-ChildItem -Path $pbgPath -Dir | ForEach-Object { Write-Host "$pbgPath\$_" ; Log-Write -LogPath $sLogFile -LineValue "$pbgPath\$_" ; Remove-item -Recurse $_.FullName }

#Delay
start-sleep -m 4000

#Updates log
Log-Write -LogPath $sLogFile -LineValue "
Step 3 of 7: Create new package structure
"
Write-Host "`nStep 3 of 7: Create new package structure" -ForegroundColor "Cyan"
Write-Host "`nCreating new folders and filters..."

#Creates DAM file structure (data), copies/renames forms & publications from the source folder (db) to the correct location, & creates content.xml files
buildDAM("pub");
buildDAM("pbg");

#Updates log
Log-Write -LogPath $sLogFile -LineValue "Step 4 of 7: Update filter.xml and properties.xml files

Updating..."

Write-Host "`nStep 4 of 7: Update filter.xml and properties.xml files" -ForegroundColor "Cyan"

Write-Host "`nUpdating..."

######################### UPDATE FILTER.XML FILE #########################

#XML filter string finalization
$xmlFilter.Add('</workspaceFilter>') | Out-Null
$xmlFilter | Set-Content -Path $filterPath -Encoding UTF8 #note: change this so mode=update for retained for prior year and mode=replace for not retained
Write-Host "$filterPath"

##########################################################################

####################### UPDATE PROPERTIES.XML FILE #######################

#Updates dates, username, and initial in properties.xml file
(Get-Content -Path $propPath -Encoding UTF8 -Raw) | ForEach-Object  {
    $_ -replace '<entry key="lastModified">.*?</entry>' , "<entry key=`"lastModified`">$date</entry>" `
       -replace '<entry key="created">.*?</entry>' , "<entry key=`"created`">$date</entry>" `
       -replace '<entry key="lastWrapped">.*?</entry>' , "<entry key=`"lastWrapped`">$date</entry>" `
       -replace '<entry key="lastModifiedBy">.*?</entry>' , "<entry key=`"lastModifiedBy`">$username</entry>" `
       -replace '<entry key="createdBy">.*?</entry>' , "<entry key=`"createdBy`">$username</entry>" `
       -replace '<entry key="lastWrappedBy">.*?</entry>' , "<entry key=`"lastWrappedBy`">$username</entry>" `
       -replace '<entry key="name">.*?</entry>' , "<entry key=`"name`">CRA-formspubs-assets-$initials</entry>" `
       -replace "<entry key=`"version`">\d\." , "<entry key=`"version`">$scriptVersion." `
       -replace '<entry key="group">.*?</entry>' , "<entry key=`"group`">CRA</entry>"
    } | Set-Content $propPath
    Write-Host "$propPath"
    
<#Gets version number from properties.xml file and increases by one
$increment = "1"
$propContent = (Get-Content -Path $propPath -Encoding UTF8 -Raw)
$propContent -match "<entry key=`"name`">(.*?)</entry>[\W\w]+?<entry key=`"version`">(\d)\.(.*?)</entry>" | Out-Null
$zipName = $Matches[1]
$revision = $Matches[2]
[int]$version = [int]$Matches[3] + [int]$increment
#>

#Gets version number from D2GC properties.xml file
$propContent = (Get-Content -Path $propPath -Encoding UTF8 -Raw)
$propContent -match "<entry key=`"name`">(.*?)</entry>" | Out-Null
$zipName = $Matches[1]
$d2propContent = (Get-Content -Path $D2GCpropPath -Encoding UTF8 -Raw)
$d2propContent -match "<entry key=`"version`">(\d).(\d)\.(.*?)</entry>" | Out-Null
$revision = $Matches[2]
[int]$version = [int]$Matches[3]
#>

#Updates version numbers in properties.xml file
(Get-Content -Path $propPath -Encoding UTF8 -Raw) | ForEach-Object  {
    $_ -replace "<entry key=`"version`">(.*?)</entry>" , "<entry key=`"version`">$revision.$version</entry>"
    } | Set-Content $propPath
    Write-Host "$propPath"

#Updates log
Log-Write -LogPath $sLogFile -LineValue "$filterPath"
Log-Write -LogPath $sLogFile -LineValue "$propPath"
Log-Write -LogPath $sLogFile -LineValue " "
Log-Write -LogPath $sLogFile -LineValue "Username: $username"
Log-Write -LogPath $sLogFile -LineValue "Modified: $date"
Log-Write -LogPath $sLogFile -LineValue "Version:  $revision.$version"

##########################################################################

######################### ZIP THE ASSET PACKAGE ##########################

#Updates log
Log-Write -LogPath $sLogFile -LineValue "
Step 5 of 7: Create zip file
"
Write-Host "`nStep 5 of 7: Create zip file" -ForegroundColor "Cyan"

$zip = $path + $bs + $zipName + "-$revision.$version.zip"

$7zipPath = $path + "\lib\7za.exe" 

If (test-path $7zipPath) {

& $7zipPath "-mx=9" a $zip $dataPath\*
Write-Host "`nAsset package created:`n$zip`n"
Log-Write -LogPath $sLogFile -LineValue ""
Log-Write -LogPath $sLogFile -LineValue "Asset package created:`n$zip"

}

Else { Write-Host "`nMissing file: $7zipPath" -ForegroundColor "Red"
       Log-Write -LogPath $sLogFile -LineValue ""
       Log-Write -LogPath $sLogFile -LineValue "Missing file: $7zipPath"
}

$finalSize = "{0:N2} MB" -f ((Get-ChildItem $zip | Measure-Object -Property Length -Sum -ErrorAction Stop).Sum / 1MB)

Write-Host "Final package size: $finalSize" -ForegroundColor "Green"

#Updates log
Log-Write -LogPath $sLogFile -LineValue "Final package size: $finalSize"

##########################################################################

########### CREATE TEXT FILES FOR CLEARING THE AEM ASSET CACHE ###########

#Updates log
Log-Write -LogPath $sLogFile -LineValue "
Step 6 of 7: Creating list of assets to clear the cache
"
Write-Host "`nStep 6 of 7: Creating list of assets to clear the cache" -ForegroundColor "Cyan"

#Updates text file with DAM paths
$listPath = $path + $bs + $zipName + "-$revision.$version.txt"
$fileList | Set-Content -Path $listPath -Encoding UTF8
Log-Write -LogPath $sLogFile -LineValue "List of assets:
$listPath"
Write-Host "`n$listPath"

##########################################################################

########### CREATE TEXT FILES FOR CLEARING THE AEM PAGE CACHE ###########

#Updates log
Log-Write -LogPath $sLogFile -LineValue "
Step 7 of 7: Creating list of webpages to clear the cache
"
Write-Host "`nStep 7 of 7: Creating list of webpages to clear the cache" -ForegroundColor "Cyan"

#Updates text file with page paths
$pagePath = $path + $bs + "CRA-formspubs-pages" + "-$initials" + "-$revision.$version.txt"
$parentCSV = $path + $bs + "lib\findchildnodes-parentNodes.csv"
$parentCSVtest = $path + $bs + "lib\findchildnodes-parentNodes-test.csv"

#Removes junk from filter.xml file for cache clearing file
$lineOne,$pageString = Get-Content $D2GCfilterpath ;
$pageString = $pageString[0..($pageString.count - 2)]
$pageString -replace '<workspaceFilter version="1.0">', ""`
            -replace '<filter root="/content/canadasite', "https://www.canada.ca"`
            -replace '/jcr:content" mode="replace"/>', ""`
            -replace '\s', ""`
            -replace '$', ".html" | Set-Content $pagePath

#Creating parent CSV file
$tempList = Get-Content $pagePath
$allpageList.Add($tempList) | out-null ;
$parentpageList.Add("Links") | out-null ; 
$parentpageList.Add($tempList) | out-null ; 
$parentpageList | Set-Content $parentCSV

#Removes URLs that aren't in the publications node
(Import-CSV $parentCSV) | where {$_.Links -match "/publications/"} | Export-CSV $parentCSV -notypeinfo

#Only runs Mandré's find child node script IF there are publications look up
$sparentCSV = Import-CSV $parentCSV
$lenparentCSV = $sparentCSV.count
if($lenparentCSV -gt 0) {

##########################################################################

####################### MANDRÉ'S FIND CHILD NODES ########################

$csvAllPgs = Import-Csv $allPubsPath
$csvPrntNodes = Import-Csv $parentCSV | ForEach-Object {
    $_.Links = $_.Links -replace 'https://www.canada.ca', ''`
                        -replace '.html', '/'
    $_ 
}

$childPages = getChildrenCSV -AllPgs $csvAllPgs -PrntNodes $csvPrntNodes 

Write-Progress -Activity Searching -Status "Completed" -PercentComplete (100)

##########################################################################

################### APPEND CHILD NODES TO CACHE LIST #####################

$len = $childPages.Length
For ($i=0; $i -lt $len; $i++) {
$tempChild = $childPages[$i].Links -replace "/content/canadasite", "https://www.canada.ca"`
                                   -replace "$", ".html"
$allpageList.Add($tempChild) | out-null ;
}
$allpageList | Set-Content $pagePath

}

#Update log
Log-Write -LogPath $sLogFile -LineValue "List of pages:
$pagePath"
Write-Host "`n$pagePath"

##########################################################################

Read-Host "`nPress enter to exit"

#Updates log
Log-Finish -LogPath $sLogFile

################################## END ###################################