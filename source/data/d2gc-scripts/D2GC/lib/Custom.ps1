Function ConvertFrom-Xml {
	<#
		.SYNOPSIS
			Converts an Xml object to as PSObject.

		.DESCRIPTION
			The ConvertFrom-Xml recursively goes through an Xml object and enumerates the properties of each inputted element. Those properties are accessed and added to the returned object.

			An XmlElement that has attributes and XmlText will end up with the XmlText value represented as a "#name" property in the resulting object.

		.EXAMPLE
			ConvertFrom-Xml -InputObject $XmlObj

			Returns an PSObject constructed from the $XmlObj variable

		.PARAMETER InputObject
			The InputObject is an Xml type in the System.Xml namespace. It could be an XmlDocument, XmlElement, or XmlNode for example. It cannot be a collection of Xml objects.

		.INPUTS
			System.Xml

		.OUTPUTS
			System.Management.Automation.PSObject

		.NOTES
			AUTHOR: Michael Haken
			LAST UPDATE: 3/31/2015
	#>
    [CmdletBinding()]
    Param(
        [Parameter(Position=0,ValueFromPipeline=$true,Mandatory=$true)]
        [ValidateScript({$_.GetType().Namespace -eq "System.Xml"})]
        $InputObject
    )

    Begin {       
    }

    Process {
		$private:Hash = @{}
        
        Get-Member -InputObject $InputObject -MemberType Property | Where-Object {$_.Name -ne "xml" -and (![System.String]::IsNullOrEmpty($_.Name))} | ForEach-Object {
            $PropertyName = $_.Name
            $InputItem = $InputObject.($PropertyName)

            #There are multiple items with the same tag name
            if ($InputItem.GetType() -eq [System.Object[]]) {
                
                #Make the tag name an array
                $private:Hash.($PropertyName) = @()

                #Go through each item in the array
                $InputItem | Where-Object {$_ -ne $null} | ForEach-Object {
                    
                    #Item is an object in the array
                    $Item = $_
                    [System.Type]$Type = $Item.GetType()

                    if ($Type.IsPrimitive -or $Type -eq [System.String]) {                   
                        $private:Hash.($PropertyName) = $Item
                    }
                    else {
						#Create a temp variable to hold the new object that will be added to the array
						$Temp = @{}  
                                
						#Make attributes properties of the object 
						$Item.Attributes | ForEach-Object {
							$Temp.($_.Name) = $_.Value
						}

						#As an XmlElement, the element will have at least 1 childnode, it's value
						$Item.ChildNodes | Where-Object {$_ -ne $null -and ![System.String]::IsNullOrEmpty($_.Name)} | ForEach-Object {
							$ChildNode = $_
   
							if ($ChildNode.HasChildNodes) {
								#If the item has 1 childnode and the childnode is XmlText, then the child is this type of element,
								#<Name>ValueText</Name>, so its child is just the value
								if ($ChildNode.ChildNodes.Count -eq 1 -and $ChildNode.ChildNodes[0].GetType() -eq [System.Xml.XmlText] -and !($ChildNode.HasAttributes)) {
									$Temp.($ChildNode.ToString()) = $ChildNode.ChildNodes[0].Value
								}
								else {
									$Temp.($ChildNode.ToString()) = ConvertFrom-Xml -InputObject $ChildNode
								}
							}
							else {
								$Temp.($ChildNode.ToString()) = $ChildNode.Value
							}
						}
					
						$private:Hash.($PropertyName) += $Temp
					}
                }
            }
            else {
                if ($InputItem -ne $null) {
                    $Item = $InputItem
                    [System.Type]$Type = $InputItem.GetType()
                    
                    if ($Type.IsPrimitive -or $Type -eq [System.String]) {                   
                        $private:Hash.($PropertyName) = $Item
                    }
                    else {

                        $private:Hash.($PropertyName) = @{}  
                                
                        $Item.Attributes | ForEach-Object {
                            $private:Hash.($PropertyName).($_.Name) = $_.Value
                        }

                        $Item.ChildNodes | Where-Object {$_ -ne $null -and ![System.String]::IsNullOrEmpty($_.Name)} | ForEach-Object {
                            $ChildNode = $_
                            
                            if ($ChildNode.HasChildNodes) {
                                if ($ChildNode.ChildNodes.Count -eq 1 -and $ChildNode.ChildNodes[0].GetType() -eq [System.Xml.XmlText] -and !($ChildNode.HasAttributes)) {      
                                    $private:Hash.($PropertyName).($ChildNode.ToString()) = $ChildNode.ChildNodes[0].Value
                                }
                                else {
                                    $private:Hash.($PropertyName).($ChildNode.ToString()) = ConvertFrom-Xml -InputObject $ChildNode
                                }
                            }
                            else {
                                $private:Hash.($PropertyName).($ChildNode.ToString()) = $ChildNode.Value
                            }
                        }
                    }
                }
            }                  
        }

		 Write-Output -InputObject (New-Object -TypeName System.Management.Automation.PSObject -Property $private:Hash)
    }

    End {      
    }
}

Function Get-IniContent {
    <#
    .Synopsis
        Gets the content of an INI file

    .Description
        Gets the content of an INI file and returns it as a hashtable

    .Notes
        Author		: Oliver Lipkau <oliver@lipkau.net>
		Source		: https://github.com/lipkau/PsIni
                      http://gallery.technet.microsoft.com/scriptcenter/ea40c1ef-c856-434b-b8fb-ebd7a76e8d91
        Version		: 1.0.0 - 2010/03/12 - OL - Initial release
                      1.0.1 - 2014/12/11 - OL - Typo (Thx SLDR)
                                              Typo (Thx Dave Stiff)
                      1.0.2 - 2015/06/06 - OL - Improvment to switch (Thx Tallandtree)
                      1.0.3 - 2015/06/18 - OL - Migrate to semantic versioning (GitHub issue#4)
                      1.0.4 - 2015/06/18 - OL - Remove check for .ini extension (GitHub Issue#6)
                      1.1.0 - 2015/07/14 - CB - Improve round-tripping and be a bit more liberal (GitHub Pull #7)
                                           OL - Small Improvments and cleanup
                      1.1.1 - 2015/07/14 - CB - changed .outputs section to be OrderedDictionary
                      1.1.2 - 2016/08/18 - SS - Add some more verbose outputs as the ini is parsed,
                      				            allow non-existent paths for new ini handling,
                      				            test for variable existence using local scope,
                      				            added additional debug output.

        #Requires -Version 2.0

    .Inputs
        System.String

    .Outputs
        System.Collections.Specialized.OrderedDictionary

    .Parameter FilePath
        Specifies the path to the input file.

    .Parameter CommentChar
        Specify what characters should be describe a comment.
        Lines starting with the characters provided will be rendered as comments.
        Default: ";"

    .Parameter IgnoreComments
        Remove lines determined to be comments from the resulting dictionary.

    .Example
        $FileContent = Get-IniContent "C:\myinifile.ini"
        -----------
        Description
        Saves the content of the c:\myinifile.ini in a hashtable called $FileContent

    .Example
        $inifilepath | $FileContent = Get-IniContent
        -----------
        Description
        Gets the content of the ini file passed through the pipe into a hashtable called $FileContent

    .Example
        C:\PS>$FileContent = Get-IniContent "c:\settings.ini"
        C:\PS>$FileContent["Section"]["Key"]
        -----------
        Description
        Returns the key "Key" of the section "Section" from the C:\settings.ini file

    .Link
        Out-IniFile
    #>

    [CmdletBinding()]
    [OutputType(
        [System.Collections.Specialized.OrderedDictionary]
    )]
    Param(
        [ValidateNotNullOrEmpty()]
        [Parameter(ValueFromPipeline=$True,Mandatory=$True)]
        [string]$FilePath,
        [char[]]$CommentChar = @(";"),
        [switch]$IgnoreComments
    )

    Begin
    {
        Write-Debug "PsBoundParameters:"
        $PSBoundParameters.GetEnumerator() | ForEach-Object { Write-Debug $_ }
        if ($PSBoundParameters['Debug']) { $DebugPreference = 'Continue' }
        Write-Debug "DebugPreference: $DebugPreference"

        Write-Verbose "$($MyInvocation.MyCommand.Name):: Function started"

        $commentRegex = "^([$($CommentChar -join '')].*)$"
        Write-Debug ("commentRegex is {0}." -f $commentRegex)
    }

    Process
    {
        Write-Verbose "$($MyInvocation.MyCommand.Name):: Processing file: $Filepath"

        $ini = New-Object System.Collections.Specialized.OrderedDictionary([System.StringComparer]::OrdinalIgnoreCase)

        if (!(Test-Path $Filepath))
        {
            Write-Verbose ("Warning: `"{0}`" was not found." -f $Filepath)
            return $ini
        }

        $commentCount = 0
        switch -regex -file $FilePath
        {
            "^\s*\[(.+)\]\s*$" # Section
            {
                $section = $matches[1]
                Write-Verbose "$($MyInvocation.MyCommand.Name):: Adding section : $section"
                $ini[$section] = New-Object System.Collections.Specialized.OrderedDictionary([System.StringComparer]::OrdinalIgnoreCase)
                $CommentCount = 0
                continue
            }
            $commentRegex # Comment
            {
                if (!$IgnoreComments)
                {
                    if (!(test-path "variable:local:section"))
                    {
                        $section = $script:NoSection
                        $ini[$section] = New-Object System.Collections.Specialized.OrderedDictionary([System.StringComparer]::OrdinalIgnoreCase)
                    }
                    $value = $matches[1]
                    $CommentCount++
                    Write-Debug ("Incremented CommentCount is now {0}." -f $CommentCount)
                    $name = "Comment" + $CommentCount
                    Write-Verbose "$($MyInvocation.MyCommand.Name):: Adding $name with value: $value"
                    $ini[$section][$name] = $value
                }
                else { Write-Debug ("Ignoring comment {0}." -f $matches[1]) }

                continue
            }
            "(.+?)\s*=\s*(.*)" # Key
            {
                if (!(test-path "variable:local:section"))
                {
                    $section = $script:NoSection
                    $ini[$section] = New-Object System.Collections.Specialized.OrderedDictionary([System.StringComparer]::OrdinalIgnoreCase)
                }
                $name,$value = $matches[1..2]
                Write-Verbose "$($MyInvocation.MyCommand.Name):: Adding key $name with value: $value"
                $ini[$section][$name] = $value
                continue
            }
        }
        Write-Verbose "$($MyInvocation.MyCommand.Name):: Finished Processing file: $FilePath"
        Return $ini
    }

    End
        {Write-Verbose "$($MyInvocation.MyCommand.Name):: Function ended"}
}

Set-Alias gic Get-IniContent

Function Set-IniContent {
    <#
    .Synopsis
        Updates existing values or adds new key-value pairs to an INI file

    .Description
        Updates specified keys to new values in all sections or certain sections.
        Used to add new or change existing values. To comment, uncomment or remove keys use the related functions instead.
        The ini source can be specified by a file or piped in by the result of Get-IniContent.
        The modified content is returned as a ordered dictionary hashtable and can be piped to a file with Out-IniFile.

    .Notes
        Author		: Sean Seymour <seanjseymour@gmail.com> based on work by Oliver Lipkau <oliver@lipkau.net>
		Source		: https://github.com/lipkau/PsIni
                      http://gallery.technet.microsoft.com/scriptcenter/ea40c1ef-c856-434b-b8fb-ebd7a76e8d91
        Version		: 1.0.0 - 2016/08/18 - SS - Initial release
                    : 1.0.1 - 2016/12/29 - SS - Removed need for delimiters by making Sections a string array
                                                and NameValuePairs a hashtable. Thanks Oliver!

        #Requires -Version 2.0

    .Inputs
        System.String
        System.Collections.IDictionary

    .Outputs
        System.Collections.Specialized.OrderedDictionary

    .Parameter FilePath
        Specifies the path to the input file.

    .Parameter InputObject
        Specifies the Hashtable to be modified. Enter a variable that contains the objects or type a command or expression that gets the objects.

    .Parameter NameValuePairs
        Hashtable of one or more key names and values to modify. Required.

    .Parameter Sections
        String array of one or more sections to limit the changes to, separated by a comma.
        Surrounding section names with square brackets is not necessary but is supported.
        Ini keys that do not have a defined section can be modified by specifying '_' (underscore) for the section.

    .Example
        $ini = Set-IniContent -FilePath "C:\myinifile.ini" -Sections 'Printers' -NameValuePairs @{'Name With Space' = 'Value1' ; 'AnotherName' = 'Value2'}
        -----------
        Description
        Reads in the INI File c:\myinifile.ini, adds or updates the 'Name With Space' and 'AnotherName' keys in the [Printers] section to the values specified,
        and saves the modified ini to $ini.

    .Example
        Set-IniContent -FilePath "C:\myinifile.ini" -Sections 'Terminals','Monitors' -NameValuePairs @{'Updated=FY17Q2'} | Out-IniFile "C:\myinifile.ini" -Force
        -----------
        Description
        Reads in the INI File c:\myinifile.ini and adds or updates the 'Updated' key in the [Terminals] and [Monitors] sections to the value specified.
        The ini is then piped to Out-IniFile to write the INI File to c:\myinifile.ini. If the file is already present it will be overwritten.

    .Example
        Get-IniContent "C:\myinifile.ini" | Set-IniContent -NameValuePairs @{'Headers' = 'True' ; 'Update' = 'False'} | Out-IniFile "C:\myinifile.ini" -Force
        -----------
        Description
        Reads in the INI File c:\myinifile.ini using Get-IniContent, which is then piped to Set-IniContent to add or update the 'Headers'  and 'Update' keys in all sections
        to the specified values. The ini is then piped to Out-IniFile to write the INI File to c:\myinifile.ini. If the file is already present it will be overwritten.

    .Example
        Get-IniContent "C:\myinifile.ini" | Set-IniContent -NameValuePairs @{'Updated'='FY17Q2'} -Sections '_' | Out-IniFile "C:\myinifile.ini" -Force
        -----------
        Description
        Reads in the INI File c:\myinifile.ini using Get-IniContent, which is then piped to Set-IniContent to add or update the 'Updated' key that
        is orphaned, i.e. not specifically in a section. The ini is then piped to Out-IniFile to write the INI File to c:\myinifile.ini.

    .Link
        Get-IniContent
        Out-IniFile
    #>

    [CmdletBinding(DefaultParameterSetName = "File")]
    [OutputType(
        [System.Collections.IDictionary]
    )]
    Param
    (
        [Parameter(ParameterSetName="File",Mandatory=$True,Position=0)]
        [ValidateNotNullOrEmpty()]
        [String]$FilePath,

        [Parameter(ParameterSetName="Object",Mandatory=$True,ValueFromPipeline=$True)]
        [ValidateNotNullOrEmpty()]
        [System.Collections.IDictionary]$InputObject,

        [Parameter(ParameterSetName="File",Mandatory=$True)]
        [Parameter(ParameterSetName="Object",Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [HashTable]$NameValuePairs,

        [Parameter(ParameterSetName="File")]
        [Parameter(ParameterSetName="Object")]
        [ValidateNotNullOrEmpty()]
        [String[]]$Sections
    )

    Begin
    {
        Write-Debug "PsBoundParameters:"
        $PSBoundParameters.GetEnumerator() | ForEach-Object { Write-Debug $_ }
        if ($PSBoundParameters['Debug']) { $DebugPreference = 'Continue' }
        Write-Debug "DebugPreference: $DebugPreference"
        Write-Verbose "$($MyInvocation.MyCommand.Name):: Function started"

        # Update or add the name/value pairs to the section.
        Function Update-IniEntry
        {
            param ($content, $section)

            foreach($pair in $NameValuePairs.GetEnumerator())
            {
                if (!($content[$section]))
                {
                    Write-Verbose ("$($MyInvocation.MyCommand.Name):: '{0}' section does not exist, creating it." -f $section)
                    $content[$section] = New-Object System.Collections.Specialized.OrderedDictionary([System.StringComparer]::OrdinalIgnoreCase)
                }

                Write-Verbose ("$($MyInvocation.MyCommand.Name):: Setting '{0}' key in section {1} to '{2}'." -f $pair.key, $section, $pair.value)
                $content[$section][$pair.key] = $pair.value
            }
        }
    }
    # Update the specified keys in the list, either in the specified section or in all sections.
    Process
    {
        # Get the ini from either a file or object passed in.
        if ($PSCmdlet.ParameterSetName -eq 'File') { $content = Get-IniContent $FilePath }
        if ($PSCmdlet.ParameterSetName -eq 'Object') { $content = $InputObject }

        # Specific section(s) were requested.
        if ($Sections)
        {
            foreach ($section in $Sections)
            {
                # Get rid of whitespace and section brackets.
                $section = $section.Trim() -replace '[][]',''

                Write-Debug ("Processing '{0}' section." -f $section)

                Update-IniEntry $content $section
            }
        }
        else # No section supplied, go through the entire ini since changes apply to all sections.
        {
            foreach ($item in $content.GetEnumerator())
            {
                $section = $item.key

                Write-Debug ("Processing '{0}' section." -f $section)

                Update-IniEntry $content $section
            }
        }
        return $content
    }
    End
    {
        Write-Verbose "$($MyInvocation.MyCommand.Name):: Function ended"
    }
}

Set-Alias sic Set-IniContent

Function Out-IniFile {
    <#
    .Synopsis
        Write hash content to INI file

    .Description
        Write hash content to INI file

    .Notes
        Author      : Oliver Lipkau <oliver@lipkau.net>
        Blog        : http://oliver.lipkau.net/blog/
        Source      : https://github.com/lipkau/PsIni
                      http://gallery.technet.microsoft.com/scriptcenter/ea40c1ef-c856-434b-b8fb-ebd7a76e8d91
        Version     : 1.0.0 - 2010/03/12 - OL - Initial release
                      1.0.1 - 2012/04/19 - OL - Bugfix/Added example to help (Thx Ingmar Verheij)
                      1.0.2 - 2014/12/11 - OL - Improved handling for missing output file (Thx SLDR)
                      1.0.3 - 2014/01/06 - CB - removed extra \r\n at end of file
                      1.0.4 - 2015/06/06 - OL - Typo (Thx Dominik)
                      1.0.5 - 2015/06/18 - OL - Migrate to semantic versioning (GitHub issue#4)
                      1.0.6 - 2015/06/18 - OL - Remove check for .ini extension (GitHub Issue#6)
                      1.1.0 - 2015/07/14 - CB - Improve round-tripping and be a bit more liberal (GitHub Pull #7)
                                           OL - Small Improvments and cleanup
                      1.1.2 - 2015/10/14 - OL - Fixed parameters in nested function
                      1.1.3 - 2016/08/18 - SS - Moved the get/create code for $FilePath to the Process block since it
                                                overwrites files piped in by other functions when it's in the Begin block,
                                                added additional debug output.
                      1.1.4 - 2016/12/29 - SS - Support output of a blank ini, e.g. if all sections got removed. This
                                                required removing [ValidateNotNullOrEmpty()] from InputObject

        #Requires -Version 2.0

    .Inputs
        System.String
        System.Collections.IDictionary

    .Outputs
        System.IO.FileSystemInfo

    .Parameter Append
        Adds the output to the end of an existing file, instead of replacing the file contents.

    .Parameter InputObject
        Specifies the Hashtable to be written to the file. Enter a variable that contains the objects or type a command or expression that gets the objects.

    .Parameter FilePath
        Specifies the path to the output file.

     .Parameter Encoding
        Specifies the file encoding. The default is UTF8.

    Valid values are:

    -- ASCII:  Uses the encoding for the ASCII (7-bit) character set.
    -- BigEndianUnicode:  Encodes in UTF-16 format using the big-endian byte order.
    -- Byte:   Encodes a set of characters into a sequence of bytes.
    -- String:  Uses the encoding type for a string.
    -- Unicode:  Encodes in UTF-16 format using the little-endian byte order.
    -- UTF7:   Encodes in UTF-7 format.
    -- UTF8:  Encodes in UTF-8 format.

     .Parameter Force
        Allows the cmdlet to overwrite an existing read-only file. Even using the Force parameter, the cmdlet cannot override security restrictions.

     .Parameter PassThru
        Passes an object representing the location to the pipeline. By default, this cmdlet does not generate any output.

     .Parameter Loose
        Adds spaces around the equal sign when writing the key = value

    .Example
        Out-IniFile $IniVar "C:\myinifile.ini"
        -----------
        Description
        Saves the content of the $IniVar Hashtable to the INI File c:\myinifile.ini

    .Example
        $IniVar | Out-IniFile "C:\myinifile.ini" -Force
        -----------
        Description
        Saves the content of the $IniVar Hashtable to the INI File c:\myinifile.ini and overwrites the file if it is already present

    .Example
        $file = Out-IniFile $IniVar "C:\myinifile.ini" -PassThru
        -----------
        Description
        Saves the content of the $IniVar Hashtable to the INI File c:\myinifile.ini and saves the file into $file

    .Example
        $Category1 = @{“Key1”=”Value1”;”Key2”=”Value2”}
        $Category2 = @{“Key1”=”Value1”;”Key2”=”Value2”}
        $NewINIContent = @{“Category1”=$Category1;”Category2”=$Category2}
        Out-IniFile -InputObject $NewINIContent -FilePath "C:\MyNewFile.ini"
        -----------
        Description
        Creating a custom Hashtable and saving it to C:\MyNewFile.ini
    .Link
        Get-IniContent
    #>

    [CmdletBinding()]
    [OutputType(
        [System.IO.FileSystemInfo]
    )]
    Param(
        [switch]$Append,

        [ValidateSet("Unicode","UTF7","UTF8","ASCII","BigEndianUnicode","Byte","String")]
        [Parameter()]
        [string]$Encoding = "UTF8",

        [ValidateNotNullOrEmpty()]
        [ValidateScript({Test-Path $_ -IsValid})]
        [Parameter(Mandatory=$True,
                   Position=0)]
        [string]$FilePath,

        [switch]$Force,

        [Parameter(ValueFromPipeline=$True,Mandatory=$True)]
        [System.Collections.IDictionary]$InputObject,

        [switch]$Passthru,

        [switch]$Loose
    )

    Begin
    {
        Write-Debug "PsBoundParameters:"
        $PSBoundParameters.GetEnumerator() | ForEach-Object { Write-Debug $_ }
        if ($PSBoundParameters['Debug']) { $DebugPreference = 'Continue' }
        Write-Debug "DebugPreference: $DebugPreference"

        Write-Verbose "$($MyInvocation.MyCommand.Name):: Function started"

        function Out-Keys
        {
            param(
                [ValidateNotNullOrEmpty()]
                [Parameter(ValueFromPipeline=$True,Mandatory=$True)]
                [System.Collections.IDictionary]$InputObject,

                [ValidateSet("Unicode","UTF7","UTF8","ASCII","BigEndianUnicode","Byte","String")]
                [Parameter(Mandatory=$True)]
                [string]$Encoding = "UTF8",

                [ValidateNotNullOrEmpty()]
                [ValidateScript({Test-Path $_ -IsValid})]
                [Parameter(Mandatory=$True,
                           ValueFromPipelineByPropertyName=$true)]
                [string]$Path,

                [Parameter(Mandatory=$True)]
                $delimiter,

                [Parameter(Mandatory=$True)]
                $MyInvocation
            )

            Process
            {
                if (!($InputObject.keys))
                {
                    Write-Warning ("No data found in '{0}'." -f $FilePath)
                }
                Foreach ($key in $InputObject.keys)
                {
                    if ($key -match "^Comment\d+") {
                        Write-Verbose "$($MyInvocation.MyCommand.Name):: Writing comment: $key"
                        Add-Content -Value "$($InputObject[$key])" -Encoding $Encoding -Path $Path
                    } else {
                        Write-Verbose "$($MyInvocation.MyCommand.Name):: Writing key: $key"
                        Add-Content -Value "$key$delimiter$($InputObject[$key])" -Encoding $Encoding -Path $Path
                    }
                }
            }
        }

        $delimiter = '='
        if ($Loose)
            { $delimiter = ' = ' }

        #Splatting Parameters
        $parameters = @{
            Encoding     = $Encoding;
            Path         = $FilePath
        }

    }

    Process
    {
        if ($append)
        {
            Write-Debug ("Appending to '{0}'." -f $FilePath)
            $outfile = Get-Item $FilePath
        } else {
            Write-Debug ("Creating new file '{0}'." -f $FilePath)
            $outFile = New-Item -ItemType file -Path $Filepath -Force:$Force
        }

        if (!(Test-Path $outFile.FullName)) {Throw "Could not create File"}

        Write-Verbose "$($MyInvocation.MyCommand.Name):: Writing to file: $Filepath"
        foreach ($i in $InputObject.keys)
        {
            if (!($InputObject[$i].GetType().GetInterface('IDictionary')))
            {
                #Key value pair
                Write-Verbose "$($MyInvocation.MyCommand.Name):: Writing key: $i"
                Add-Content -Value "$i$delimiter$($InputObject[$i])" @parameters

            } elseif ($i -eq $script:NoSection) {
                #Key value pair of NoSection
                Out-Keys $InputObject[$i] `
                         @parameters `
                         -delimiter $delimiter `
                         -MyInvocation $MyInvocation
            } else {
                #Sections
                Write-Verbose "$($MyInvocation.MyCommand.Name):: Writing Section: [$i]"

                # Only write section, if it is not a dummy ($script:NoSection)
                if ($i -ne $script:NoSection) { Add-Content -Value "`n[$i]" @parameters }

                if ( $InputObject[$i].Count) {
                    Out-Keys $InputObject[$i] `
                         @parameters `
                         -delimiter $delimiter `
                         -MyInvocation $MyInvocation
                }

            }
        }
        Write-Verbose "$($MyInvocation.MyCommand.Name):: Finished Writing to file: $FilePath"
    }

    End
    {
        if ($PassThru)
        {
            Write-Debug ("Returning file due to PassThru argument.")
            Return (Get-Item $outFile)
        }
        Write-Verbose "$($MyInvocation.MyCommand.Name):: Function ended"
    }
}

Set-Alias oif Out-IniFile

Function Out-Zip {
    <#
    .Synopsis
        Outputs files into a zip
    .Description
        Stores files in a zip archive
    .Example
        dir -recurse | Out-Zip -ZipFile ".\a.zip"
    .Example
        dir $home\Documents\WindowsPowerShell\Modules\Pipeworks -Recurse | 
            Out-Zip -ZipFile $home\Pipeworks.zip        
        Expand-Zip $home\Pipeworks.zip -OutputPath $psHome\Modules\Pipeworks
    .Link
        Expand-Zip
    #>
    
    [OutputType([IO.Fileinfo])]
    Param(
    # The path to a file.
    [Parameter(Mandatory=$true,
        ParameterSetName='FileList',
        Position=0,
        ValueFromPipelineByPropertyName=$true)]
    [Alias('Fullname')]
    [string[]]$FilePath,
    
    # The output zip file
    [Parameter(Mandatory=$true,Position=1,ValueFromPipelineByPropertyName=$true)]
    [string]$ZipFile,
    
    # If set, will not show progress.  This improves performance and is good to include when calling this within another command.
    [Switch]$HideProgress,
    
    # The common root
    [string]$CommonRoot
    )
    
    Begin {
    
        $zipFiles = New-Object Collections.ArrayList
        $fileList = New-Object Collections.ArrayList
        
        if (-not $script:cachedContentTypes) {
            $script:cachedContentTypes = @{}
            $ctKey = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey("MIME\Database\Content Type")
            $ctKey.GetSubKeyNames() |
                ForEach-Object {
                    $extension= $ctKey.OpenSubKey($_).GetValue("Extension") 
                    if ($extension) {
                        $script:cachedContentTypes["${extension}"] = $_
                    }
                }

        }

        Add-Type -AssemblyName WindowsBase        
       
    }
    
    Process {
        # Cool trick:  Skip piped in directories by looking @ $_, which will contain the full bound object
        if ($_.PSIsContainer) { return } 
        foreach ($f in $filePath) {
            if ($f) {
                $null = $fileList.Add($f)
            }
        }       
        
        
        if ($zipFile) {
            $null  = $zipFiles.Add($zipFile) 
        }
    }
    
    End {                
        if (-not $commonRoot) {
            $commonRoot = ""
        }
        
        foreach ($f in $fileList) {
            if (-not $commonRoot) {
                $commonRoot = $f.Substring(0, $f.LastIndexOf("\"))
                continue
            }
            
            if ($f -like "${commonRoot}*") {
                continue
            } else {
                while ($commonRoot -and $f -notlike "${CommonRoot}*") {
                    $commonRoot = try { $commonRoot.Substring(0, $commonRoot.LastIndexOf("\")) } catch { ""}
                }
            }                             
        }
       
        $bufferSize = 1kb
        $zipFiles = $zipFiles | Select-Object -Unique
        $progressId = Get-Random
        foreach ($zf in $zipFiles) {
            $fullzf = "$($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($zf))"
            
            if (-not $fullZf) { return } 
            if (-not $HideProgress) {
                Write-Progress "Creating Zip: $fullZf" " " -PercentComplete 1 -Id $progressId
            }
            
            $package = [IO.Packaging.ZipPackage]::Open($fullzf, "Create", "ReadWrite")
            
            # $fileList = $fileList | Select-Object -First 1 
            $count = @($fileList).Count
            $n = 0
            foreach ($f in $fileList) {
                
                $rp = try { "$($ExecutionContext.SessionState.Path.GetResolvedPSPathFromPSPath($f))" } catch { }
                
                if ($rp) {
                    # Put the file in the package 
                    $extension = [IO.Path]::GetExtension($rp)
                    
                    $mimeType = $script:CachedContentTypes[$extension]
                    if (-not $mimeType) {
                        $mimetype = "unknown/unknown"
                    }
                    $uri = $rp.Replace($commonRoot, "").Replace("\", "/")
                    $uri = [Web.HttpUtility]::UrlEncode($uri) -replace 
                        "%2f", "/" -replace "%27", "'"
                    $packagePart = try {
                        $package.CreatePart($uri, $mimetype, "Maximum")
                    } catch {
                        Write-Error -Message "Could Not Pack up $uri" -TargetObject $_ -Exception $_.Exception 
                    }
                    $streamPart = New-Object IO.StreamWriter $packagePart.GetStream("Create","Write")
                    $perc = $n * 100 / $count
                    if (-not $HideProgress) {
                        Write-Progress "Creating Zip: $fullZf" "Reading $rp" -PercentComplete $perc -Id $progressId
                    }
                    
                    $fileBytes= [IO.File]::ReadAllBytes($rp)                    

                    if (-not $HideProgress) {                    
                        Write-Progress "Creating Zip: $fullZf" "Compressing $rp" -PercentComplete $perc -Id $progressId
                    }
                    $write=  $streamPart.basestream.Write($fileBytes, 0, $fileBytes.Count)
                    
                    $streamPart.Close()
                    $package.Flush()

                }
                $n++
                
            }
            
            $package.Close()        
            if (-not $HideProgress) {
                Write-Progress "Creating Zip" "Completed" -Completed -Id $progressId
            }
            
         
            
        }
        
        
        
        
    }
}

Set-Alias oz Out-Zip

Function Test-Xml()
{
    [CmdletBinding(PositionalBinding=$false)]
    Param (
    [Parameter(ValueFromPipeline=$true, Mandatory=$true)]
        [string] [ValidateScript({Test-Path -Path $_})] $Path,
 
        [Parameter(Mandatory=$true)]
        [string] [ValidateScript({Test-Path -Path $_})] $SchemaFilePath,
 
        [Parameter(Mandatory=$false)]
        $Namespace = $null
    )
 
    [string[]]$Script:XmlValidationErrorLog = @()
    [scriptblock] $ValidationEventHandler = {
        $Script:XmlValidationErrorLog += "`n" + "Line: $($_.Exception.LineNumber) Offset: $($_.Exception.LinePosition) - $($_.Message)"
    }
 
    $readerSettings = New-Object -TypeName System.Xml.XmlReaderSettings
    $readerSettings.ValidationType = [System.Xml.ValidationType]::Schema
    $readerSettings.ValidationFlags = [System.Xml.Schema.XmlSchemaValidationFlags]::ProcessIdentityConstraints -bor
            [System.Xml.Schema.XmlSchemaValidationFlags]::ProcessSchemaLocation -bor
            [System.Xml.Schema.XmlSchemaValidationFlags]::ReportValidationWarnings
    $readerSettings.Schemas.Add($Namespace, $SchemaFilePath) | Out-Null
    $readerSettings.add_ValidationEventHandler($ValidationEventHandler)
    
    Try
    {
        $reader = [System.Xml.XmlReader]::Create($Path, $readerSettings)
        while ($reader.Read()) { }
    }
 
    #handler to ensure we always close the reader sicne it locks files
    Finally
    {
        $reader.Close()
    }
 
    if ($Script:XmlValidationErrorLog)
    {
        [string[]]$ValidationErrors = $Script:XmlValidationErrorLog
        Write-Warning "Xml file ""$Path"" is NOT valid according to schema ""$SchemaFilePath"""
        Write-Warning "$($Script:XmlValidationErrorLog.Count) errors found"
    }
    else
    {
        Write-Host "Xml file ""$Path"" is valid according to schema ""$SchemaFilePath"""
    }
 
    Return ,$ValidationErrors #The comma prevents powershell from unravelling the collection http://bit.ly/1fcZovr
}

Set-Alias tx Test-Xml