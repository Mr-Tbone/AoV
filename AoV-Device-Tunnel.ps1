<#PSScriptInfo
.VERSION        2.0
.AUTHOR         @MrTbone_se (T-bone Granheden)
.GUID           feedbeef-beef-4dad-beef-b628ccca16e2
.COPYRIGHT      (c) 2026 T-bone Granheden. MIT License - free to use with attribution.
.TAGS           Intune DeviceManagement Win32App PowerShellScript AddRemovePrograms ARP Wrapper Logging Always On VPN AoV
.LICENSEURI     https://opensource.org/licenses/MIT
.PROJECTURI     https://github.com/Mr-Tbone/Intune
.RELEASENOTES
    1.0 2022-02-18 Initial Build
    1.1 2022-07-17 Solved a problem with uninstall device tunnel from Add Remove Programs
    1.2 2022-07-18 Solved Windows 11 problems with CSP over WMI. No blank DNS server list allowed
    1.3 2022-08-15 Fixed Version check
    1.4 2023-01-09 Fixed new DeviceTunnelInfo regkey cleanup
    1.5 2023-03-16 Unified script for both Device and User Tunnel and some Bug Fixes. Removed minimum win build due to not needed
    1.6 2023-03-17 Fixed some bugs
    1.7 2023-11-28 Added modify option in Add Remove Programs to repair/reinstall the VPN connection
    2.0 Completely rewritten script with a unified Add Remove Program wrapper function for both Device and User Tunnel, added logging function, added execution context detection function
#>
<#
.SYNOPSIS
    Script for Intune to build an app that show in Add/Remove Programs from a PowerShell Script
    This script uses the wrapper to create an Always On VPN configuration for the Device Tunnel and publish in Add Remove Programs.
    You can easily update the VPN Configuration by deploying a again with an increment $ConfigVersion version of this scripts.
.DESCRIPTION
    This script will act as a wrapper for PowerShell script.
    It will copy the script and icon to program files and add the necessary registry keys to show up in Add/Remove Programs.
    The PowerShell based app can be installed, uninstalled and reinstalled from Add/Remove Programs and also show the app version and icon.
    This script uses the wrapper to create an Always On VPN configuration for the Device Tunnel and publish in Add Remove Programs.
    You can easily update the VPN Configuration by deploying a again with an increment $ConfigVersion version of this scripts.
.EXAMPLE
   .\AoV-Device-Tunnel.ps1
    Will configure Always On VPN configuration for the Device with settings in the modifyable region. 
.EXAMPLE
   .\AoV-Device-Tunnel.ps1 -InstallType ReInstall
    Will reconfigure Always On VPN configuration for the Device with settings in the modifyable region. 
.EXAMPLE
   .\AoV-Device-Tunnel.ps1 -InstallType UnInstall
    Will remove Always On VPN configuration for the Device with settings in the modifyable region.
.NOTES
    Please feel free to use this, but make sure to credit @MrTbone_se as the original author
.LINK
    https://tbone.se
#>
#region ---------------------------------------------------[Modifiable Parameters and Defaults]------------------------------------
# Customizations NOTE!: If update config to roll out new version, make sure to also update the version in the parameters for Add Remove Programs ($ConfigVersion)! 
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false,          HelpMessage = "Name of the script action for logging")]
    [string]$ScriptActionName       = "AoV Device Tunnel",

    [Parameter(Mandatory = $false,          HelpMessage = 'Specify how to run the script: Install, ReInstall or UnInstall')]    
    [validateset("Install", "ReInstall", "UnInstall")]
    [string]$InstallType            = "Install",

    [Parameter(Mandatory = $false,          HelpMessage = 'Version of the wrapped configuration. Increment when changing config')]
    [ValidatePattern("^\d+\.\d+\.\d+$")]
    [version]$ConfigVersion         = "1.0.0",

    [Parameter(Mandatory = $false,          HelpMessage = "Testmode, same as -WhatIf. Default is false")]
    [bool]$Testmode                 = $false,

# ==========> Wrapped AoV Properties (InlineInstallerScript) <===========================================
    [Parameter(Mandatory = $false,          HelpMessage = 'Path to custom VPN XML configuration file. If specified, overrides the inline XML template in the Custom VPN XML region.')]
    [string]$AoVCustomXMLPath       = "",

    [Parameter(Mandatory = $false,          HelpMessage = 'Company name used in VPN ProfileName and ARP registry keys')]
    [string]$AoVCompany             = "T-Bone",

    [Parameter(Mandatory = $false,          HelpMessage = 'Name of the Always On VPN profile. Defaults to "$AoVCompany AoV Device Tunnel" if empty.')]
    [string]$AoVProfileName         = "",

    [Parameter(Mandatory = $false,          HelpMessage = 'Optional: cleanup old VPN profiles matching this name pattern. Empty = skip.')]
    [string]$AoVOldprofilename      = '',

    [Parameter(Mandatory = $false,          HelpMessage = 'Create the VPN user tunnel profile in the all-users profile. Device tunnels always use the system scope.')]
    [bool]$AoVAllUserProfile        = $false,

    [Parameter(Mandatory = $false,          HelpMessage = 'VPN protocol strategy applied via PBK (not configurable in XML): 5=SSTP only, 6=SSTP first, 7=IKEv2 only, 8=IKEv2 first, 14=IKEv2+SSTP')]
    [string]$AoVStrategy            = "7",

    [Parameter(Mandatory = $false,          HelpMessage = 'VPN mobility (reconnect after outage) applied via PBK (not configurable in XML): 0=Enabled, 1=Disabled (0=Recommended)')]
    [string]$AoVDisableMobility     = "0",
# ==========> Script Context Requirements (verified against execution context) <=======================================

    [Parameter(Mandatory = $false,          HelpMessage = 'Required execution identity. Script aborts if not matched. Valid: System, LocalService, NetworkService, ServiceAccount, Admin, User')]
    [ValidateSet('System','LocalService','NetworkService','ServiceAccount','Admin','User')]
    [string[]]$CTXReqIdentity       = @(),

    [Parameter(Mandatory = $false,          HelpMessage = 'Minimum required PowerShell version (e.g. 5.1). Script aborts if PSVersion is lower.')]
    [version]$CTXReqPSVersion    = $null,

    [Parameter(Mandatory = $false,          HelpMessage = 'Minimum required OS build number (e.g. 19041 for Windows 10 2004). Script aborts if OS build is lower.')]
    [int]$CTXReqOSBuild          = 0,

    [Parameter(Mandatory = $false,          HelpMessage = 'Required process architecture, exits if not matched. Default = "" No required architecture. Valid: "", "x64", "x86"')]
    [ValidateSet('x64','x86','')]
    [string]$CTXReqArchitecture     = "",

    [Parameter(Mandatory = $false,          HelpMessage = 'If $true and CTXReqArchitecture=x64 but running x86, relaunch via SysNative (Intune-friendly self-elevation to x64).')]
    [bool]$CTXAutoRelaunchToX64     = $false,

    [Parameter(Mandatory = $false,          HelpMessage = 'If $true, script aborts when a reboot is pending (CBS, Windows Update, or PendingFileRenameOperations).')]
    [bool]$CTXAbortIfPendingReboot  = $false,

# ==========> Add Application to Add Remove Program (Add-AddRemoveProgram) <===========================================
    [Parameter(Mandatory = $false,          HelpMessage = 'Name of the application/script being wrapped')]
    [String]$ARPAppName             = "",

    [Parameter(Mandatory = $false,          HelpMessage = 'GUID of the application/script being wrapped. Leave blank to auto-read from .GUID in PSScriptInfo header. Must be unique per wrapped app.')]
    [ValidatePattern('^(\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\})?$')]
    [String]$ARPAppGuid             = "",

    [Parameter(Mandatory = $false,          HelpMessage = 'Version of the application. Increment when changing config')]
    [ValidatePattern("^\d+\.\d+\.\d+$")]
    [version]$ARPAppVersion         = $ConfigVersion,

    [Parameter(Mandatory = $false,          HelpMessage = 'Company name used for naming of folders and registry keys')]
    [String]$ARPAppPublisher        = $AoVCompany,
    
    [Parameter(Mandatory = $false,          HelpMessage = 'Optional Base64-encoded .ico content to use as the icon of the app')]
    [string]$ARPAppIcon             = "",

    [Parameter(Mandatory = $false,          HelpMessage = "Application folder path, if not specified, it will use %ProgramFiles%\ARPPublisher\ARPAppName ")]
    [string]$ARPAppFolder           = "",
    
    [Parameter(Mandatory = $false,          HelpMessage = 'Enable an uninstall option in Add Remove Programs, require administrator privileges to uninstall')]
    [bool]$ARPAppEnableUninstall    = $True,

    [Parameter(Mandatory = $false,          HelpMessage = 'Enable a modify option in Add Remove Programs (typically for repair/reinstall), require administrator privileges to modify')]
    [bool]$ARPAppEnableModify       = $True,

    [Parameter(Mandatory = $false,          HelpMessage = 'Optional path to a .ps1 file to use as the installer script')]
    [string]$ARPAppInstallScript    = "",

    [Parameter(Mandatory = $false,          HelpMessage = 'Optional path to a .ps1 file to use as the uninstaller script')]
    [string]$ARPAppUnInstallScript  = "",

    [Parameter(Mandatory = $false,          HelpMessage = 'Optional path to a .ico file to use as the icon of the app')]
    [string]$ARPAppIconPath         = "",

    [Parameter(Mandatory = $false,          HelpMessage = 'If $true, copy every file in the wrapper''s source folder into the app folder (excluding the wrapper itself, the install/uninstall scripts and the icon, which are deployed under standardized names).')]
    [bool]$ARPAppIncludeFolder      = $false,

    [Parameter(Mandatory = $false,          HelpMessage = 'Optional leaf name of a companion file inside the app folder to launch the app (e.g. t-bone.exe). Required for shortcut creation.')]
    [string]$ARPAppUserStartFile    = "",

    [Parameter(Mandatory = $false,          HelpMessage = 'Create an All-Users Desktop shortcut to ARPAppUserStartFile')]
    [bool]$ARPAppShortcutOnDesktop  = $false,

    [Parameter(Mandatory = $false,          HelpMessage = 'Create an All-Users Start Menu shortcut to ARPAppUserStartFile (under Programs\<Publisher>\<AppName>.lnk)')]
    [bool]$ARPAppShortcutInStart    = $false,

    [Parameter(Mandatory = $false,          HelpMessage = 'Force the application reinstall, ignoring any prompts or checks')]
    [bool]$ARPAppForce              = $false,

# ==========> Logging (Invoke-TboneLog) <==============================================================================
    [Parameter(Mandatory = $false,          HelpMessage='Name of Log, to set name for Eventlog and Filelog')]
    [string]$LogName                = "",

    [Parameter(Mandatory = $false,          HelpMessage='Show output in console during execution')]
    [bool]$LogToGUI                 = $true,

    [Parameter(Mandatory = $false,          HelpMessage='Write complete log array to Windows Event when script ends')]
    [bool]$LogToEventlog            = $true,

    [Parameter(Mandatory = $false,          HelpMessage='EventLog IDs as hashtable: @{Info=11001; Warn=11002; Error=11003}')]
    [hashtable]$LogEventIds         = @{Info=11001; Warn=11002; Error=11003},

    [Parameter(Mandatory = $false,          HelpMessage='Return complete log array as Host output when script ends (Good for Intune Remediations)')]
    [bool]$LogToHost                = $false,

    [Parameter(Mandatory = $false,          HelpMessage='Write complete log array to Disk when script ends')]
    [bool]$LogToDisk                = $false,

    [Parameter(Mandatory = $false,          HelpMessage='Path where Disk logs are saved (if LogToDisk is enabled)')]
    [string]$LogToDiskPath          = "$env:TEMP",

    [Parameter(Mandatory = $false,          HelpMessage = "Enable verbose logging. Default is false")]
    [bool]$LogVerboseEnabled        = $false
)
#endregion

#region ---------------------------------------------------[Custom VPN XML]-----------------------------------------
# Inline VPN XML template, edit the values below to match your environment or pase in your own.
# To use an external XML file instead, set -AoVCustomXMLPath (it will override this template).
$AoVVPNProfileXML = '
<VPNProfile>
    <DeviceTunnel>true</DeviceTunnel>                                           <!--true = Create Device Tunnel, false = Create user tunnel (default)-->
    <AlwaysOn>true</AlwaysOn>                                                   <!--true = Tunnel is Always on, false = Tunnel is not Always On (Default) -->
    <RememberCredentials>true</RememberCredentials>                             <!--true = Credentials are cached whenever possible, false = Do not cache credentials (default) -->
    <TrustedNetworkDetection>tbone.se</TrustedNetworkDetection>                 <!--VPN does not connect when connected to this trusted network, multiple networks can be seperated by comma "," Not Recommended on devicetunnel if using both User and Device tunnel-->
    <DnsSuffix>tbone.se</DnsSuffix>                                             <!--The DNS suffix for the VPN NIC-->
    <RegisterDNS>true</RegisterDNS>                                             <!--true = Register in DNS, false = Do not register in DNS (default)-->
        <!--NRPT-->
    <DomainNameInformation>                                                     <!--NRPT exclude your VPN server from suffix rule above -->
        <DomainName>vpn.tbone.se</DomainName>
        <DnsServers>1.1.1.1,8.8.8.8</DnsServers>                                <!--Using public DNS (Cannot be blank in Win 11)-->
        <AutoTrigger>false</AutoTrigger>
        <DomainNameType>FQDN</DomainNameType>
        <Persistent>true</Persistent>
    </DomainNameInformation>
    <DomainNameInformation>                                                     <!--NRPT and Trigger VPN to connect if using any of the listed adresses-->
        <DomainName>dc1.tbone.se, dc2.tbone.se</DomainName>                     <!--NRPT domain to trigger this rule-->
        <DnsServers>10.10.10.4,10.10.10.5</DnsServers>                          <!--NRPT DNS to use when doing lookups on that domain. (Cannot be blank in Win 11)-->
        <AutoTrigger>true</AutoTrigger>                                         <!--NRPT Auto connect VPN if using the domain name-->
    </DomainNameInformation>
    <NativeProfile>
        <Servers>vpn.tbone.se</Servers>                                         <!--VPN Server Address-->
        <RoutingPolicyType>SplitTunnel</RoutingPolicyType>                      <!--SplitTunnel or ForcedTunnel-->
        <NativeProtocolType>IKEv2</NativeProtocolType>                          <!--VPN Connection Protocol, PPTP,L2TP,SSTP,IKEv2,Automatic,ProtocolList-->
        <DisableClassBasedDefaultRoute>true</DisableClassBasedDefaultRoute>     <!--VPN use Custom Routes if set to true-->
            <!--VPN Authentication Method-->
        <Authentication>
            <MachineMethod>Certificate</MachineMethod>                          <!--Authentication, Device tunnel require certificate, User tunnel can use various methods-->
        </Authentication>
            <!--VPN Algorithms used-->
        <CryptographySuite>
            <AuthenticationTransformConstants>SHA256128</AuthenticationTransformConstants>
            <CipherTransformConstants>AES128</CipherTransformConstants>
            <EncryptionMethod>AES128</EncryptionMethod>
            <IntegrityCheckMethod>SHA256</IntegrityCheckMethod>
            <DHGroup>Group14</DHGroup>
            <PfsGroup>PFS2048</PfsGroup>
        </CryptographySuite>
    </NativeProfile>
        <!--VPN Custom Routes-->
    <Route><Address>10.10.10.4</Address><PrefixSize>32</PrefixSize><Metric>0</Metric></Route>   <!--VPN Custom Routes only DC1 on 10.10.10.4-->
    <Route><Address>10.10.10.5</Address><PrefixSize>32</PrefixSize><Metric>0</Metric></Route>   <!--VPN Custom Routes only DC2 on 10.10.10.5-->
    <Route><Address>10.10.10.10</Address><PrefixSize>32</PrefixSize><Metric>0</Metric></Route>  <!--VPN Custom Routes only CA1 on 10.10.10.10-->
        <!--New settings for Windows 11 22H2-->
    <DisableAdvancedOptionsEditButton>false</DisableAdvancedOptionsEditButton>  <!--true = Advanced Options Edit Button is not available, false = Advanced Options Edit Button is available (default)-->
    <DisableDisconnectButton>true</DisableDisconnectButton>                     <!--true = Disconnect Button is not visible, false = Disconnect Button is visible (default)-->
    <DisableIKEv2Fragmentation>false</DisableIKEv2Fragmentation>                <!--true = IKEv2 Fragmentation will not be used, false = IKEv2 Fragmentation will be used (Default)-->
    <DataEncryption>Optional</DataEncryption>                                   <!--Set encryptionlevel to None, Optional, Require(default), Max-->
    <IPv4InterfaceMetric>3</IPv4InterfaceMetric>                                <!--ipv4 interface priority metric for a custom better DNS and nic priority. (0 = Default, 3 = Recommended)-->
    <IPv6InterfaceMetric>3</IPv6InterfaceMetric>                                <!--ipv6 interface priority metric for a custom better DNS and nic priority. (0 = Default, 3 = Recommended)-->
    <NetworkOutageTime>0</NetworkOutageTime>                                    <!--VPN reconnect timeout in seconds: 60, 120, 300, 600, 1200, 1800 (0 = default (1800 = 30 min), 0 = recommended)-->
    <UseRasCredentials>false</UseRasCredentials>                                <!--VPN reuse RAS credentials to connect to internal resources with SSO (1 = Default, 1 = Recommended)-->
    <PrivateNetwork>true</PrivateNetwork>                                       <!--false = VPN connection is public, true = VPN connection is private (default)-->
</VPNProfile>'

# If an external XML is provided with -AoVCustomXMLPath, it overrides the default inline XML content
if (-not [string]::IsNullOrEmpty($AoVCustomXMLPath)) {
    if (Test-Path -LiteralPath $AoVCustomXMLPath -PathType Leaf) {
        try {
            $AoVVPNProfileXML = Get-Content -LiteralPath $AoVCustomXMLPath -Raw -ErrorAction Stop
            Write-Verbose "Custom VPN XML loaded from $AoVCustomXMLPath"
        }
        catch {Write-Warning "Failed to read custom VPN XML from $AoVCustomXMLPath. Error: $($_.Exception.Message)"}
    }
    else {Write-Warning "Custom VPN XML path specified but file not found: $AoVCustomXMLPath"}
}
# Set $AoVDeviceTunnel from the active XML. The dispatch logic uses $AoVDeviceTunnel to decide whether SYSTEM or user CSP context is needed
[bool]$AoVDeviceTunnel = $false  # Default; overwritten by <DeviceTunnel> in the XML
if (-not [string]::IsNullOrWhiteSpace($AoVVPNProfileXML)) {
    try {
        [xml]$private:_xmlTemp = $AoVVPNProfileXML.Trim()
        $AoVDeviceTunnel = $private:_xmlTemp.VPNProfile.DeviceTunnel -eq 'true'
        Write-Verbose "DeviceTunnel synced from VPN XML: $AoVDeviceTunnel"
    }
    catch { Write-Warning "Could not parse <DeviceTunnel> from VPN XML; defaulting to `$false. Error: $($_.Exception.Message)" }
    finally { Remove-Variable _xmlTemp -Scope private -ErrorAction SilentlyContinue }
}
#endregion

#region ---------------------------------------------------[Set global script settings]--------------------------------------------
# set strict mode to latest version
Set-StrictMode -Version Latest

# Save original preference states at script scope for restoration in finally block
[System.Management.Automation.ActionPreference]$script:OriginalErrorActionPreference    = $ErrorActionPreference
[System.Management.Automation.ActionPreference]$script:OriginalVerbosePreference        = $VerbosePreference
[bool]$script:OriginalWhatIfPreference                                                  = $WhatIfPreference

# Set verbose- and whatif- preference based on parameter instead of hardcoded values or manually enable whatif mode with parameter $Testmode for testing
if ($LogVerboseEnabled)     {$VerbosePreference = 'Continue'}
else                        {$VerbosePreference = 'SilentlyContinue'}
if($Testmode)               {$WhatIfPreference = $true}
#endregion

#region ---------------------------------------------------[Static Variables]------------------------------------------------------
# Compute profile name default if not supplied
if ([string]::IsNullOrEmpty($AoVProfileName)) {
    if ($AoVDeviceTunnel) { $AoVProfileName = "$AoVCompany AoV Device Tunnel"}
    else {                  $AoVProfileName = "$AoVCompany AoV User Tunnel"}
}
# Compute ARP app name default if not supplied
if ([string]::IsNullOrEmpty($ARPAppName)) {
    if ($AoVDeviceTunnel) { $ARPAppName = "$AoVCompany AoV Device Tunnel"}
    else {                  $ARPAppName = "$AoVCompany AoV User Tunnel"}
}
# Compute ARP app folder default if not supplied
if ([string]::IsNullOrEmpty($ARPAppFolder)) {
    $ARPAppFolder = "$env:ProgramFiles\$AoVCompany\$AoVProfileName"
}
# Compute ARPAppGuid from PSScriptInfo .GUID header if not supplied
if ([string]::IsNullOrEmpty($ARPAppGuid)) {
    $ARPGuidMatch = Get-Content -LiteralPath $PSCommandPath -TotalCount 20 -ErrorAction SilentlyContinue |
        Select-String -Pattern '^\s*\.GUID\s+([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})' |
        Select-Object -First 1
    if ($ARPGuidMatch) { $ARPAppGuid = "{$($ARPGuidMatch.Matches[0].Groups[1].Value)}" }
    if ([string]::IsNullOrEmpty($ARPAppGuid)) { throw "ARPAppGuid is empty and no .GUID found in the PSScriptInfo header of '$PSCommandPath'." }
}

# Auto-detect GUID-named XML sidecar — only when running from the install folder (ARP reinstall/repair scenario).
# $ARPAppGuid and $ARPAppFolder are resolved above, so we can check the correct path and guard against false positives.
if ([string]::IsNullOrEmpty($AoVCustomXMLPath) -and
    -not [string]::IsNullOrEmpty($PSScriptRoot) -and
    -not [string]::IsNullOrEmpty($ARPAppFolder) -and
    $PSScriptRoot.TrimEnd('\').Equals($ARPAppFolder.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
    $private:_sidecarPath = Join-Path $ARPAppFolder "$ARPAppGuid.xml"
    if (Test-Path -LiteralPath $private:_sidecarPath -PathType Leaf) {
        Write-Verbose "Auto-detected staged VPN XML sidecar: $private:_sidecarPath"
        try {
            $AoVVPNProfileXML = Get-Content -LiteralPath $private:_sidecarPath -Raw
            $AoVCustomXMLPath = $private:_sidecarPath  # set so installer re-stages the sidecar on reinstall
            Write-Verbose "Sidecar VPN XML loaded from $private:_sidecarPath"
            # Sync $AoVDeviceTunnel from sidecar
            [xml]$private:_xmlTemp = $AoVVPNProfileXML.Trim()
            $AoVDeviceTunnel = $private:_xmlTemp.VPNProfile.DeviceTunnel -eq 'true'
            Write-Verbose "DeviceTunnel synced from sidecar XML: $AoVDeviceTunnel"
        }
        catch { Write-Warning "Failed to load or parse sidecar VPN XML from $private:_sidecarPath: $_" }
        finally {
            Remove-Variable _xmlTemp  -Scope private -ErrorAction SilentlyContinue
            Remove-Variable _sidecarPath -Scope private -ErrorAction SilentlyContinue
        }
    }
}

# ==========> Logging (Invoke-TboneLog) <==============================================================================
if([string]::IsNullOrWhiteSpace($LogName)) {[string]$LogName = $ScriptActionName}           # Logname defaults to script action name
#endregion

#region ---------------------------------------------------[Import Modules and Extensions]-----------------------------------------
# No modules required for this script
#endregion

#region ---------------------------------------------------[Install and Uninstall ScriptBlock]-------------------------------------
# Note that this scriptblock runs at: new-version Install, ReInstall, and Install-from-installed-path (e.g. ARP Modify).
# It is skipped on Install when the same version is already registered in Add/Remove Programs.
[scriptblock]$InlineInstallerScript = {
# Require VPN profile XML â€” set by the inline template in the Custom VPN XML region or by -AoVCustomXMLPath.
if ([string]::IsNullOrWhiteSpace($AoVVPNProfileXML)) {
    throw "No VPN profile XML is configured. Edit the inline XML template in the Custom VPN XML region, or set -AoVCustomXMLPath to point to an external XML file."
}
# XML cleanup — $AoVVPNProfileXML is either the param-built value or the Custom VPN XML override above.
# HTML-encode for the WMI/CIM bridge (MDM_VPNv2_01 ProfileXML property requires &lt;/&gt;/&quot; encoding).
$AoVVPNProfileXML          = $AoVVPNProfileXML.Trim()   # CSP XML parser requires < as the very first character; here-strings add a leading newline
$AoVProfileNameEscaped     = $AoVProfileName -replace ' ', '%20'
$AoVOldprofilenameEscaped  = $AoVOldprofilename -replace ' ', '%20'
# Extract values needed for legacy PBK fallback (Windows build < 22H2).
# On older builds, these ProfileXML elements are ignored and must be applied via PBK instead.
$AoVIPv4InterfaceMetric = '3'
$AoVIPv6InterfaceMetric = '3'
$AoVNetworkOutageTime   = '0'
[bool]$AoVUseRasCredentials = $false
try {
    [xml]$private:_pbkXml = $AoVVPNProfileXML.Trim()
    if (-not [string]::IsNullOrEmpty($private:_pbkXml.VPNProfile.IPv4InterfaceMetric)) { $AoVIPv4InterfaceMetric = $private:_pbkXml.VPNProfile.IPv4InterfaceMetric }
    if (-not [string]::IsNullOrEmpty($private:_pbkXml.VPNProfile.IPv6InterfaceMetric)) { $AoVIPv6InterfaceMetric = $private:_pbkXml.VPNProfile.IPv6InterfaceMetric }
    if (-not [string]::IsNullOrEmpty($private:_pbkXml.VPNProfile.NetworkOutageTime))   { $AoVNetworkOutageTime   = $private:_pbkXml.VPNProfile.NetworkOutageTime }
    if (-not [string]::IsNullOrEmpty($private:_pbkXml.VPNProfile.UseRasCredentials))   { $AoVUseRasCredentials   = $private:_pbkXml.VPNProfile.UseRasCredentials -eq 'true' }
}
catch { Write-Warning "Could not parse legacy PBK values from VPN XML, using defaults. Error: $($_.Exception.Message)" }
finally { Remove-Variable _pbkXml -Scope private -ErrorAction SilentlyContinue }#Write-Verbose "VPNProfileXML:`n$AoVVPNProfileXML" # Added for t-shoot
# Validate XML is well-formed before staging or sending to CSP — a malformed profile would fail silently at the WMI bridge.
try   { [void][xml]$AoVVPNProfileXML }
catch { throw "VPNProfileXML is not valid XML and cannot be applied: $_" }
# Stage XML sidecar so reinstall/repair from Add/Remove Programs works without the original source file.
# Only written when a custom XML is in use — param-built XML is always rebuilt from parameters.
# The installer runs before Add-AddRemovePrograms creates the folder, so ensure it exists first.
if (-not [string]::IsNullOrEmpty($AoVCustomXMLPath)) {
    try {
        if (-not (Test-Path -LiteralPath $ARPAppFolder -PathType Container)) {
            $null = New-Item -Path $ARPAppFolder -ItemType Directory -Force -ErrorAction Stop
            Write-Verbose "Created ARP app folder for sidecar: $ARPAppFolder"
        }
        Set-Content -LiteralPath "$ARPAppFolder\$ARPAppGuid.xml" -Value $AoVVPNProfileXML -Encoding UTF8 -ErrorAction Stop
        Write-Verbose "Staged VPN XML sidecar to $ARPAppFolder\$ARPAppGuid.xml"
    }
    catch { Write-Warning "Failed to stage VPN XML sidecar to $ARPAppFolder\$ARPAppGuid.xml: $_" }
}
$AoVVPNProfileXML          = $AoVVPNProfileXML -replace '<', '&lt;'
$AoVVPNProfileXML          = $AoVVPNProfileXML -replace '>', '&gt;'
$AoVVPNProfileXML          = $AoVVPNProfileXML -replace '"', '&quot;'
#Write-Verbose "VPNProfileXML:`n$AoVVPNProfileXML"          # Added for t-shoot
    # CSP/WMI bridge constants
    $AoVNodeCSPURI             = "./Vendor/MSFT/VPNv2"     #https://learn.microsoft.com/windows/client-management/mdm/vpnv2-csp?WT.mc_id=EM-MVP-5004264
    $AoVNamespaceName          = "root\cimv2\mdm\dmmap"
    $AoVClassName              = "MDM_VPNv2_01"
    # Registry path constants
    $AoVMDMPath                = "HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked"
    $AoVNetworkProfilesPath    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles\'
    $AoVDeviceTunnelInfoPath   = 'HKLM:\SYSTEM\CurrentControlSet\Services\RasMan\DeviceTunnel\'
    $AoVUserTunnelInfoPath     = 'HKLM:\SYSTEM\CurrentControlSet\Services\RasMan\config'

    # Resolve current interactive user and SID (console or RDP). Skip for device tunnels — not needed.
    $AoVUsername  = $null
    $AoVSidValue  = $null

    if (-not $AoVDeviceTunnel) {
        try {
            # Owner of explorer.exe = the interactive user (works on console and RDP, locale-independent)
            $AoVExplorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
                        Select-Object -First 1
            if ($AoVExplorer) {
                $AoVOwner = Invoke-CimMethod -InputObject $AoVExplorer -MethodName GetOwner -ErrorAction Stop
                if ($AoVOwner.ReturnValue -eq 0 -and $AoVOwner.User) {
                    $AoVUsername  = "$($AoVOwner.Domain)\$($AoVOwner.User)"
                    $AoVSidValue  = (New-Object System.Security.Principal.NTAccount($AoVUsername)).
                                    Translate([System.Security.Principal.SecurityIdentifier]).Value
                    Write-Verbose "Resolved interactive user '$AoVUsername' (SID $AoVSidValue)"
                }
            }
        } catch { Write-Warning "Failed to resolve interactive user via explorer.exe: $_" }
        if (-not $AoVSidValue) {throw "User tunnel install requires an interactive user, but none could be resolved."}
    }

    # Ensure dmwappushservice is running, Required for MDM CSP-over-WMI bridge on most Win10/11 builds.
    $AoVServiceName    = 'dmwappushservice'
    $AoVServiceTimeout = 10
    $AoVServiceRetry   = 3
    $AoVService = Get-Service -Name $AoVServiceName -ErrorAction SilentlyContinue
    if (-not $AoVService) {
        Write-Warning "Service '$AoVServiceName' not found on this OS (may be Server Core / IoT / debloated image). Skipping start."
    }
    elseif ($AoVService.Status -eq 'Running') {
        Write-Verbose "Service '$AoVServiceName' is already running"
    }
    else {
        if ($AoVService.StartType -eq 'Disabled') {
            try   { Set-Service -Name $AoVServiceName -StartupType Manual -ErrorAction Stop; Write-Verbose "Set service '$AoVServiceName' to Manual" }
            catch { Write-Warning "Failed to set service '$AoVServiceName' startup type: $_" }
        }
        for ($AoVSvcTry = 1; $AoVSvcTry -le $AoVServiceRetry; $AoVSvcTry++) {
            try {
                if ($AoVService.Status -notin 'Running','StartPending') {
                    Start-Service -Name $AoVServiceName -ErrorAction Stop
                }
                $AoVService.WaitForStatus('Running', [TimeSpan]::FromSeconds($AoVServiceTimeout))
                Write-Verbose "Service '$AoVServiceName' running (attempt $AoVSvcTry)"
                break
            }
            catch {
                $AoVService.Refresh()
                if ($AoVSvcTry -lt $AoVServiceRetry) {
                    Write-Warning "Attempt $AoVSvcTry/$AoVServiceRetry to start '$AoVServiceName' failed: $_. Retrying..."
                }
                else { throw "Failed to start service '$AoVServiceName' after $AoVServiceRetry attempts: $_" }
            }
        }
    }

    # Connect CSP over WMI bridge. Required to create/delete Always On VPN profiles.
    try {
        $AoVSession = New-CimSession -ErrorAction Stop -Verbose:$false
        $AoVOptions = $null
        if (-not $AoVDeviceTunnel) {
            $AoVOptions = New-Object Microsoft.Management.Infrastructure.Options.CimOperationOptions
            $AoVOptions.SetCustomOption("PolicyPlatformContext_PrincipalContext_Type", "PolicyPlatform_UserContext", $false)
            $AoVOptions.SetCustomOption("PolicyPlatformContext_PrincipalContext_Id", $AoVSidValue, $false)
        }
        Write-Verbose "Success to connect CSP over WMI bridge"
    }
    catch {
        throw "Failed to connect CSP over WMI bridge: $_"
    }

    # Disconnect existing VPN tunnel with same name a new or old profile.
    try   { $null = & rasdial.exe $AoVProfileName /disconnect 2>&1; Write-Verbose "Success to disconnect VPN Tunnel $AoVProfileName" }
    catch { Write-Verbose "Failed to disconnect VPN tunnel $AoVProfileName" }
    if (-not [string]::IsNullOrWhiteSpace($AoVOldprofilename)) {
        try   { $null = & rasdial.exe $AoVOldprofilename /disconnect 2>&1; Write-Verbose "Success to disconnect VPN Tunnel $AoVOldprofilename" }
        catch { Write-Verbose "Failed to disconnect VPN tunnel $AoVOldprofilename" }
    }

    # Remove existing VPN tunnels via CSP over WMI bridge. Required for device-tunnel removal (PowerShell can't remove device tunnels reliably).
    $AoVDeleteInstances = @()
    try {
        $AoVDeleteInstances = if ($AoVDeviceTunnel -or $AoVAllUserProfile) {
            $AoVSession.EnumerateInstances($AoVNamespaceName, $AoVClassName)
        } else {
            $AoVSession.EnumerateInstances($AoVNamespaceName, $AoVClassName, $AoVOptions)
        }
        Write-Verbose "Enumerated $(@($AoVDeleteInstances).Count) VPN profile(s) via CSP"
    }
    catch { Write-Warning "Failed to enumerate VPN profiles via CSP: $_" }
    
    foreach ($AoVInstance in @($AoVDeleteInstances)) {
        $AoVId = $AoVInstance.InstanceID
        if ($AoVId -ne $AoVProfileNameEscaped -and
            ([string]::IsNullOrEmpty($AoVOldprofilenameEscaped) -or $AoVId -ne $AoVOldprofilenameEscaped)) {
            Write-Verbose "Skipped VPN profile '$AoVId' (out of scope)"
            continue
        }
        try {
            if ($AoVDeviceTunnel -or $AoVAllUserProfile) {
                $AoVSession.DeleteInstance($AoVNamespaceName, $AoVInstance)
            } else {
                $AoVSession.DeleteInstance($AoVNamespaceName, $AoVInstance, $AoVOptions)
            }
            Write-Verbose "Deleted VPN profile '$AoVId' via CSP"
        }
        catch { Write-Warning "Failed to delete VPN profile '$AoVId' via CSP: $_" }
    }
    
    # Remove via PowerShell as fallback (covers cases where CSP misses old profiles).
    # Note: when running as SYSTEM, -AllUserConnection is required to see machine-scope profiles; user-scope profiles are handled by the CSP+SID path above.
    foreach ($AoVName in @($AoVProfileName, $AoVOldprofilename) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
        foreach ($AoVScope in @($true, $false)) {  # $true = AllUser, $false = current user
            $AoVParams = @{ Name = $AoVName; ErrorAction = 'SilentlyContinue' }
            if ($AoVScope) { $AoVParams.AllUserConnection = $true }
            $AoVVpn = Get-VpnConnection @AoVParams
            if ($AoVVpn) {
                try {
                    $AoVRemoveParams = @{ Name = $AoVName; Force = $true; ErrorAction = 'Stop' }
                    if ($AoVScope) { $AoVRemoveParams.AllUserConnection = $true }
                    Remove-VpnConnection @AoVRemoveParams
                    Write-Verbose "Deleted VPN '$AoVName' (AllUser=$AoVScope) via PowerShell"
                }
                catch { Write-Warning "Failed to delete VPN '$AoVName' (AllUser=$AoVScope): $_" }
            }
        }
    }

    # Remove MDM tracking entries that reference this VPN profile
    try {
        $AoVEscapedPattern = [regex]::Escape($AoVProfileNameEscaped)
        $AoVMDMSettings = Get-ChildItem -Path $AoVMDMPath -Recurse -Depth 3 -ErrorAction Stop |
            Where-Object {
                $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                $props -and ($props.PSObject.Properties.Value -match $AoVEscapedPattern)
            }
        if ($AoVMDMSettings) {
            $AoVMDMSettings | Remove-Item -Force -ErrorAction Stop
            Write-Verbose "Deleted $(@($AoVMDMSettings).Count) MDM Tracking entries"
        } else { Write-Verbose "No MDM Tracking entries found, skipping" }
    }
    catch { Write-Warning "MDM Tracking cleanup failed: $_" }
    
    # Remove NetworkList profiles whose Description matches our VPN profile name
    try {
        $AoVNetworkProfile = Get-ChildItem -Path $AoVNetworkProfilesPath -ErrorAction Stop | Where-Object {
            (Get-ItemProperty -LiteralPath $_.PSPath -Name Description -ErrorAction SilentlyContinue).Description -eq $AoVProfileName
        }
        if ($AoVNetworkProfile) {
            $AoVNetworkProfile | Remove-Item -Force -Recurse -ErrorAction Stop
            Write-Verbose "Deleted $(@($AoVNetworkProfile).Count) NetworkList entries"
        } else { Write-Verbose "No NetworkList entries found, skipping" }
    }
    catch { Write-Warning "NetworkList cleanup failed: $_" }
    
    # Remove autoconnect / tunnel info from registry
    if ($AoVDeviceTunnel) {
        if (Test-Path $AoVDeviceTunnelInfoPath) {
            try   { Remove-Item $AoVDeviceTunnelInfoPath -Recurse -Force -ErrorAction Stop; Write-Verbose "Deleted $AoVDeviceTunnelInfoPath" }
            catch { Write-Warning "Failed to delete $AoVDeviceTunnelInfoPath : $_" }
        } else { Write-Verbose "Skipped $AoVDeviceTunnelInfoPath, does not exist" }
    }
    else {
        # User tunnel: remove our profile from AutoTriggerDisabledProfilesList
        try {
            $AoVDisabled = @(Get-ItemPropertyValue -Path $AoVUserTunnelInfoPath -Name AutoTriggerDisabledProfilesList -ErrorAction Stop)
            $AoVRemaining = @($AoVDisabled | Where-Object { $_ -ne $AoVProfileName })
            if ($AoVRemaining.Count -eq $AoVDisabled.Count) {
                Write-Verbose "Profile '$AoVProfileName' not in AutoTriggerDisabledProfilesList, skipping"
            }
            elseif ($AoVRemaining.Count -eq 0) {
                Remove-ItemProperty -Path $AoVUserTunnelInfoPath -Name AutoTriggerDisabledProfilesList -ErrorAction Stop
                Write-Verbose "Removed empty AutoTriggerDisabledProfilesList"
            }
            else {
                Set-ItemProperty -Path $AoVUserTunnelInfoPath -Name AutoTriggerDisabledProfilesList -Value $AoVRemaining -ErrorAction Stop
                Write-Verbose "Removed '$AoVProfileName' from AutoTriggerDisabledProfilesList"
            }
        }
        catch [System.Management.Automation.PSArgumentException] {
            Write-Verbose "AutoTriggerDisabledProfilesList does not exist, skipping"
        }
        catch { Write-Warning "AutoTriggerDisabledProfilesList cleanup failed: $_" }
    }
    # Create new VPN connection via CSP over WMI bridge. Required because device tunnels can't be created via PowerShell.
    # Retry up to 3 times — the WMI bridge (MDM_VPNv2_01) is occasionally unresponsive for a few seconds after dmwappushservice starts.
    $AoVCimRetryMax  = 3
    $AoVCimRetryWait = 3
    for ($AoVCimTry = 1; $AoVCimTry -le $AoVCimRetryMax; $AoVCimTry++) {
        try {
            $AoVNewInstance = [Microsoft.Management.Infrastructure.CimInstance]::new($AoVClassName, $AoVNamespaceName)
            $AoVNewInstance.CimInstanceProperties.Add(
                [Microsoft.Management.Infrastructure.CimProperty]::Create('ParentID',   $AoVNodeCSPURI,         'String', 'Key'))
            $AoVNewInstance.CimInstanceProperties.Add(
                [Microsoft.Management.Infrastructure.CimProperty]::Create('InstanceID', $AoVProfileNameEscaped, 'String', 'Key'))
            $AoVNewInstance.CimInstanceProperties.Add(
                [Microsoft.Management.Infrastructure.CimProperty]::Create('ProfileXML', $AoVVPNProfileXML,      'String', 'Property'))

            if ($AoVDeviceTunnel) {
                $null = $AoVSession.CreateInstance($AoVNamespaceName, $AoVNewInstance)
            } else {
                $null = $AoVSession.CreateInstance($AoVNamespaceName, $AoVNewInstance, $AoVOptions)
            }
            Write-Verbose "Created VPN profile '$AoVProfileName' via CSP (attempt $AoVCimTry)"
            break
        }
        catch {
            if ($AoVCimTry -lt $AoVCimRetryMax) {
                Write-Warning "Attempt $AoVCimTry/$AoVCimRetryMax to create VPN profile via CSP failed: $_. Retrying in $AoVCimRetryWait s..."
                Start-Sleep -Seconds $AoVCimRetryWait
            }
            else { throw "Failed to create VPN profile '$AoVProfileName' via CSP after $AoVCimRetryMax attempts: $_" }
        }
    }

    # Resolve PBK file path based on tunnel type
    if ($AoVDeviceTunnel -or $AoVAllUserProfile) {
        $AoVAutoTriggerProfilePhonebookPath = $AoVDeviceTunnelInfoPath
        $AoVRasPhone = "$env:ProgramData\Microsoft\Network\Connections\Pbk\rasphone.pbk"
    }
    else {
        $AoVAutoTriggerProfilePhonebookPath = $AoVUserTunnelInfoPath
        try {
            $AoVUserProfilePath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$AoVSidValue" -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
            $AoVRasPhone = "$AoVUserProfilePath\AppData\Roaming\Microsoft\Network\Connections\Pbk\rasphone.pbk"
            Write-Verbose "Resolved user profile path: $AoVUserProfilePath"
        }
        catch { Write-Warning "Failed to resolve user profile path for SID $AoVSidValue : $_" }
    }
    
    # Override PBK path from registry if available (do not overwrite $AoVRasPhone with $null)
    if (Test-Path -LiteralPath $AoVAutoTriggerProfilePhonebookPath) {
        try {
            $AoVOverride = (Get-ItemProperty -LiteralPath $AoVAutoTriggerProfilePhonebookPath -Name AutoTriggerProfilePhonebookPath -ErrorAction Stop).AutoTriggerProfilePhonebookPath
            if (-not [string]::IsNullOrWhiteSpace($AoVOverride)) {
                $AoVRasPhone = $AoVOverride
                Write-Verbose "Override PBK path from registry: $AoVRasPhone"
            }
        }
        catch { Write-Verbose "No PBK path override in registry, using default" }
    }
    
    if (Test-Path -LiteralPath $AoVRasPhone) {
        Write-Verbose "Found PBK file: $AoVRasPhone"
    
        # Always-applied PBK settings
        $AoVPbkSettings = [ordered]@{
            VpnStrategy     = $AoVStrategy
            DisableMobility = $AoVDisableMobility
        }
    
        # Older Windows builds: these elements aren't honoured by ProfileXML; apply via PBK instead
        $AoVWinInsider = 23403
        try {
            $AoVCurrentBuild = [int](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuild -ErrorAction Stop).CurrentBuild
        } catch { $AoVCurrentBuild = 0 }
    
        if ($AoVCurrentBuild -lt $AoVWinInsider) {
            Write-Verbose "Windows build $AoVCurrentBuild < insider $AoVWinInsider — applying legacy PBK settings"
            $AoVPbkSettings['IpInterfaceMetric']   = $AoVIPv4InterfaceMetric
            $AoVPbkSettings['Ipv6InterfaceMetric'] = $AoVIPv6InterfaceMetric
            $AoVPbkSettings['NetworkOutageTime']   = $AoVNetworkOutageTime
            $AoVPbkSettings['UseRasCredentials']   = $AoVUseRasCredentials
        }
    
        foreach ($AoVKey in $AoVPbkSettings.Keys) {
            $AoVPbkVal = $AoVPbkSettings[$AoVKey]
            try {
                $AoVPbkSecPattern = "\[$([regex]::Escape($AoVProfileName))\]"
                $AoVPbkKeyPattern = "($([regex]::Escape($AoVKey))=)[^\r\n]*"
                $AoVPbkOut = (Get-Content -LiteralPath $AoVRasPhone -Raw) -split '(?=\r?\n\[)' | ForEach-Object {
                    if ($_ -match $AoVPbkSecPattern) { $_ -replace $AoVPbkKeyPattern, "`${1}$AoVPbkVal" } else { $_ }
                }
                Set-Content -LiteralPath $AoVRasPhone -Value (-join $AoVPbkOut) -NoNewline -ErrorAction Stop
                Write-Verbose "Set PBK '$AoVKey' = '$AoVPbkVal'"
            }
            catch { Write-Warning "Failed to set PBK '$AoVKey': $_" }
        }
    }
    else { Write-Warning "PBK file not found: $AoVRasPhone" }
    
    # Ensure DNS adapter registration works reliably
    try {
        New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name DisableNRPTForAdapterRegistration -PropertyType DWORD -Value 1 -Force -ErrorAction Stop | Out-Null
        Write-Verbose "Set DisableNRPTForAdapterRegistration = 1"
    }
    catch { Write-Warning "Failed to set DisableNRPTForAdapterRegistration: $_" }
    
    # Trigger initial VPN connect (rasdial doesn't throw on failure — check exit code)
    try {
        $null = & rasdial.exe $AoVProfileName 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Verbose "Triggered VPN '$AoVProfileName' to connect" }
        else                     { Write-Warning "rasdial '$AoVProfileName' returned exit code $LASTEXITCODE (tunnel may connect later via auto-trigger)" }
    }
    catch { Write-Warning "Failed to invoke rasdial for '$AoVProfileName': $_" }

    # Dispose CimSession
    if ($null -ne $AoVSession) { Remove-CimSession -CimSession $AoVSession -ErrorAction SilentlyContinue }
}

# Note that this scriptblock runs at: UnInstall (from Add/Remove Programs or -InstallType UnInstall).
[scriptblock]$InlineUnInstallerScript = {
    $AoVProfileNameEscaped     = $AoVProfileName -replace ' ', '%20'
    $AoVOldprofilenameEscaped  = $AoVOldprofilename -replace ' ', '%20'
    # CSP/WMI bridge constants
    $AoVNodeCSPURI             = "./Vendor/MSFT/VPNv2"     #https://learn.microsoft.com/windows/client-management/mdm/vpnv2-csp?WT.mc_id=EM-MVP-5004264
    $AoVNamespaceName          = "root\cimv2\mdm\dmmap"
    $AoVClassName              = "MDM_VPNv2_01"
    # Registry path constants
    $AoVMDMPath                = "HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked"
    $AoVNetworkProfilesPath    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles\'
    $AoVDeviceTunnelInfoPath   = 'HKLM:\SYSTEM\CurrentControlSet\Services\RasMan\DeviceTunnel\'
    $AoVUserTunnelInfoPath     = 'HKLM:\SYSTEM\CurrentControlSet\Services\RasMan\config'

    # Resolve current interactive user and SID (console or RDP). Skip for device tunnels — not needed.
    $AoVUsername  = $null
    $AoVSidValue  = $null

    if (-not $AoVDeviceTunnel) {
        try {
            # Owner of explorer.exe = the interactive user (works on console and RDP, locale-independent)
            $AoVExplorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
                        Select-Object -First 1
            if ($AoVExplorer) {
                $AoVOwner = Invoke-CimMethod -InputObject $AoVExplorer -MethodName GetOwner -ErrorAction Stop
                if ($AoVOwner.ReturnValue -eq 0 -and $AoVOwner.User) {
                    $AoVUsername  = "$($AoVOwner.Domain)\$($AoVOwner.User)"
                    $AoVSidValue  = (New-Object System.Security.Principal.NTAccount($AoVUsername)).
                                    Translate([System.Security.Principal.SecurityIdentifier]).Value
                    Write-Verbose "Resolved interactive user '$AoVUsername' (SID $AoVSidValue)"
                }
            }
        } catch { Write-Warning "Failed to resolve interactive user via explorer.exe: $_" }
        if (-not $AoVSidValue) { Write-Warning "User tunnel uninstall could not resolve an interactive user — user-context CSP delete may be skipped." }
    }

    # Ensure dmwappushservice is running, Required for MDM CSP-over-WMI bridge on most Win10/11 builds.
    $AoVServiceName    = 'dmwappushservice'
    $AoVServiceTimeout = 10
    $AoVServiceRetry   = 3
    $AoVService = Get-Service -Name $AoVServiceName -ErrorAction SilentlyContinue
    if (-not $AoVService) {
        Write-Warning "Service '$AoVServiceName' not found on this OS (may be Server Core / IoT / debloated image). Skipping start."
    }
    elseif ($AoVService.Status -eq 'Running') {
        Write-Verbose "Service '$AoVServiceName' is already running"
    }
    else {
        if ($AoVService.StartType -eq 'Disabled') {
            try   { Set-Service -Name $AoVServiceName -StartupType Manual -ErrorAction Stop; Write-Verbose "Set service '$AoVServiceName' to Manual" }
            catch { Write-Warning "Failed to set service '$AoVServiceName' startup type: $_" }
        }
        for ($AoVSvcTry = 1; $AoVSvcTry -le $AoVServiceRetry; $AoVSvcTry++) {
            try {
                if ($AoVService.Status -notin 'Running','StartPending') {
                    Start-Service -Name $AoVServiceName -ErrorAction Stop
                }
                $AoVService.WaitForStatus('Running', [TimeSpan]::FromSeconds($AoVServiceTimeout))
                Write-Verbose "Service '$AoVServiceName' running (attempt $AoVSvcTry)"
                break
            }
            catch {
                $AoVService.Refresh()
                if ($AoVSvcTry -lt $AoVServiceRetry) {
                    Write-Warning "Attempt $AoVSvcTry/$AoVServiceRetry to start '$AoVServiceName' failed: $_. Retrying..."
                }
                else { throw "Failed to start service '$AoVServiceName' after $AoVServiceRetry attempts: $_" }
            }
        }
    }

    # Connect CSP over WMI bridge. Required to delete Always On VPN profiles.
    try {
        $AoVSession = New-CimSession -ErrorAction Stop -Verbose:$false
        $AoVOptions = $null
        if (-not $AoVDeviceTunnel -and $AoVSidValue) {
            $AoVOptions = New-Object Microsoft.Management.Infrastructure.Options.CimOperationOptions
            $AoVOptions.SetCustomOption("PolicyPlatformContext_PrincipalContext_Type", "PolicyPlatform_UserContext", $false)
            $AoVOptions.SetCustomOption("PolicyPlatformContext_PrincipalContext_Id", $AoVSidValue, $false)
        }
        Write-Verbose "Success to connect CSP over WMI bridge"
    }
    catch {
        throw "Failed to connect CSP over WMI bridge: $_"
    }

    # Disconnect existing VPN tunnel with same name a new or old profile.
    try   { $null = & rasdial.exe $AoVProfileName /disconnect 2>&1; Write-Verbose "Success to disconnect VPN Tunnel $AoVProfileName" }
    catch { Write-Verbose "Failed to disconnect VPN tunnel $AoVProfileName" }
    if (-not [string]::IsNullOrWhiteSpace($AoVOldprofilename)) {
        try   { $null = & rasdial.exe $AoVOldprofilename /disconnect 2>&1; Write-Verbose "Success to disconnect VPN Tunnel $AoVOldprofilename" }
        catch { Write-Verbose "Failed to disconnect VPN tunnel $AoVOldprofilename" }
    }

    # Remove existing VPN tunnels via CSP over WMI bridge. Required for device-tunnel removal (PowerShell can't remove device tunnels reliably).
    $AoVDeleteInstances = @()
    try {
        $AoVDeleteInstances = if ($AoVDeviceTunnel -or $AoVAllUserProfile) {
            $AoVSession.EnumerateInstances($AoVNamespaceName, $AoVClassName)
        } else {
            $AoVSession.EnumerateInstances($AoVNamespaceName, $AoVClassName, $AoVOptions)
        }
        Write-Verbose "Enumerated $(@($AoVDeleteInstances).Count) VPN profile(s) via CSP"
    }
    catch { Write-Warning "Failed to enumerate VPN profiles via CSP: $_" }

    foreach ($AoVInstance in @($AoVDeleteInstances)) {
        $AoVId = $AoVInstance.InstanceID
        if ($AoVId -ne $AoVProfileNameEscaped -and
            ([string]::IsNullOrEmpty($AoVOldprofilenameEscaped) -or $AoVId -ne $AoVOldprofilenameEscaped)) {
            Write-Verbose "Skipped VPN profile '$AoVId' (out of scope)"
            continue
        }
        try {
            if ($AoVDeviceTunnel -or $AoVAllUserProfile) {
                $AoVSession.DeleteInstance($AoVNamespaceName, $AoVInstance)
            } else {
                $AoVSession.DeleteInstance($AoVNamespaceName, $AoVInstance, $AoVOptions)
            }
            Write-Verbose "Deleted VPN profile '$AoVId' via CSP"
        }
        catch { Write-Warning "Failed to delete VPN profile '$AoVId' via CSP: $_" }
    }

    # Remove via PowerShell as fallback (covers cases where CSP misses old profiles).
    # Note: when running as SYSTEM, -AllUserConnection is required to see machine-scope profiles; user-scope profiles are handled by the CSP+SID path above.
    foreach ($AoVName in @($AoVProfileName, $AoVOldprofilename) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
        foreach ($AoVScope in @($true, $false)) {  # $true = AllUser, $false = current user
            $AoVParams = @{ Name = $AoVName; ErrorAction = 'SilentlyContinue' }
            if ($AoVScope) { $AoVParams.AllUserConnection = $true }
            $AoVVpn = Get-VpnConnection @AoVParams
            if ($AoVVpn) {
                try {
                    $AoVRemoveParams = @{ Name = $AoVName; Force = $true; ErrorAction = 'Stop' }
                    if ($AoVScope) { $AoVRemoveParams.AllUserConnection = $true }
                    Remove-VpnConnection @AoVRemoveParams
                    Write-Verbose "Deleted VPN '$AoVName' (AllUser=$AoVScope) via PowerShell"
                }
                catch { Write-Warning "Failed to delete VPN '$AoVName' (AllUser=$AoVScope): $_" }
            }
        }
    }

    # Remove MDM tracking entries that reference this VPN profile
    try {
        $AoVEscapedPattern = [regex]::Escape($AoVProfileNameEscaped)
        $AoVMDMSettings = Get-ChildItem -Path $AoVMDMPath -Recurse -Depth 3 -ErrorAction Stop |
            Where-Object {
                $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                $props -and ($props.PSObject.Properties.Value -match $AoVEscapedPattern)
            }
        if ($AoVMDMSettings) {
            $AoVMDMSettings | Remove-Item -Force -ErrorAction Stop
            Write-Verbose "Deleted $(@($AoVMDMSettings).Count) MDM Tracking entries"
        } else { Write-Verbose "No MDM Tracking entries found, skipping" }
    }
    catch { Write-Warning "MDM Tracking cleanup failed: $_" }

    # Remove NetworkList profiles whose Description matches our VPN profile name
    try {
        $AoVNetworkProfile = Get-ChildItem -Path $AoVNetworkProfilesPath -ErrorAction Stop | Where-Object {
            (Get-ItemProperty -LiteralPath $_.PSPath -Name Description -ErrorAction SilentlyContinue).Description -eq $AoVProfileName
        }
        if ($AoVNetworkProfile) {
            $AoVNetworkProfile | Remove-Item -Force -Recurse -ErrorAction Stop
            Write-Verbose "Deleted $(@($AoVNetworkProfile).Count) NetworkList entries"
        } else { Write-Verbose "No NetworkList entries found, skipping" }
    }
    catch { Write-Warning "NetworkList cleanup failed: $_" }

    # Remove autoconnect / tunnel info from registry
    if ($AoVDeviceTunnel) {
        if (Test-Path $AoVDeviceTunnelInfoPath) {
            try   { Remove-Item $AoVDeviceTunnelInfoPath -Recurse -Force -ErrorAction Stop; Write-Verbose "Deleted $AoVDeviceTunnelInfoPath" }
            catch { Write-Warning "Failed to delete $AoVDeviceTunnelInfoPath : $_" }
        } else { Write-Verbose "Skipped $AoVDeviceTunnelInfoPath, does not exist" }
    }
    else {
        # User tunnel: remove our profile from AutoTriggerDisabledProfilesList
        try {
            $AoVDisabled = @(Get-ItemPropertyValue -Path $AoVUserTunnelInfoPath -Name AutoTriggerDisabledProfilesList -ErrorAction Stop)
            $AoVRemaining = @($AoVDisabled | Where-Object { $_ -ne $AoVProfileName })
            if ($AoVRemaining.Count -eq $AoVDisabled.Count) {
                Write-Verbose "Profile '$AoVProfileName' not in AutoTriggerDisabledProfilesList, skipping"
            }
            elseif ($AoVRemaining.Count -eq 0) {
                Remove-ItemProperty -Path $AoVUserTunnelInfoPath -Name AutoTriggerDisabledProfilesList -ErrorAction Stop
                Write-Verbose "Removed empty AutoTriggerDisabledProfilesList"
            }
            else {
                Set-ItemProperty -Path $AoVUserTunnelInfoPath -Name AutoTriggerDisabledProfilesList -Value $AoVRemaining -ErrorAction Stop
                Write-Verbose "Removed '$AoVProfileName' from AutoTriggerDisabledProfilesList"
            }
        }
        catch [System.Management.Automation.PSArgumentException] {
            Write-Verbose "AutoTriggerDisabledProfilesList does not exist, skipping"
        }
        catch { Write-Warning "AutoTriggerDisabledProfilesList cleanup failed: $_" }
    }

    # Remove DNS registration registry key (added by installer)
    try {
        Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name DisableNRPTForAdapterRegistration -ErrorAction SilentlyContinue
        Write-Verbose "Removed regkey DisableNRPTForAdapterRegistration"
    }
    catch { Write-Warning "Failed to remove regkey DisableNRPTForAdapterRegistration: $_" }

    # Dispose CimSession
    if ($null -ne $AoVSession) { Remove-CimSession -CimSession $AoVSession -ErrorAction SilentlyContinue }
}
#endregion

#region ---------------------------------------------------[Functions]------------------------------------------------------------
function Invoke-TboneLog { 
<#
.SYNOPSIS
    Unified tiny logger for PowerShell 5.1–7.5 and Azure Automation; overrides Write-* cmdlets and stores all messages in-memory
.DESCRIPTION
    A lightweight, cross-platform logging solution that intercepts all Write-Host, Write-Output, Write-Verbose, 
    Write-Warning, and Write-Error calls. Stores messages in memory with timestamps and can optionally output to:
    -LogToGUI - Console (real-time during execution) -LogToDisk - Disk (log file at script completion) -LogToEventlog - Windows Event Log (Application log)
.NOTES
    Author:  @MrTbone_se (T-bone Granheden)
    Version: 1.1.0
    
    Version History:
    1.0 - Initial version
    1.0.1 - Fixed event log source creation for first-time runs
    1.1.0 - Added parameter logName and logEventIds to customize event log source and file log name
#>
    [CmdletBinding()]
    param(
        [Parameter(                     HelpMessage='Start=Begin logging, Stop=End and output log array')]
        [ValidateSet('Start','Stop')]
        [string]$LogMode,
        [Parameter(                     HelpMessage='Name of Log, to set name for Eventlog and Filelog')]
        [string]$LogName        = "PowerShellScript",
        [Parameter(                     HelpMessage='Show output in console during execution')]
        [bool]$LogToGUI         = $true,
        [Parameter(                     HelpMessage='Write complete log array to Windows Eventlog when script ends')]
        [bool]$LogToEventlog    = $true,
        [Parameter(                     HelpMessage='EventLog IDs as hashtable: @{Info=11001; Warn=11002; Error=11003}')]
        [hashtable]$LogEventIds = @{Info=11001; Warn=11002; Error=11003},
        [Parameter(                     HelpMessage='Return complete log array as Host output when script ends (Good for Intune Remediations)')]
        [bool]$LogToHost        = $True,
        [Parameter(                     HelpMessage='Write complete log array to filelog on disk when script ends')]
        [bool]$LogToDisk        = $true,
        [Parameter(                     HelpMessage='Path where Disk logs are saved (if LogToDisk is enabled)')]
        [string]$LogPath        = "$env:TEMP"
    )
    # Auto-detect mode: if logger functions is already loaded in memory and no mode specified, assume Stop
    if(!$LogMode){$LogMode=if(Get-Variable -Name _l -Scope Global -EA 0){'Stop'}else{'Start'}}
    if(!$LogPath){$LogPath=if($global:_p){$global:_p}elseif($env:TEMP){$env:TEMP}else{'/tmp'}}
    # Stop mode: Save logs and cleanup
    if ($LogMode -eq 'Stop') {
        if((Get-Variable -Name _l -Scope Global -EA 0) -and (Test-Path function:\global:_Save)){_Save;if($global:_r){,$global:_l.ToArray()}}
        Unregister-Event -SourceIdentifier PowerShell.Exiting -ea 0 -WhatIf:$false
        if(Test-Path function:\global:_Clean){_Clean}
        return
    }
    # Start mode: Initialize logging and proxy all Write-* functions
    if ($LogMode -eq 'Start') {
        # Create helper functions and variables
        $global:_az=$env:AZUREPS_HOST_ENVIRONMENT -or $env:AUTOMATION_ASSET_ACCOUNTID # Detect Azure Automation environment
        $global:_l=[Collections.Generic.List[string]]::new();$global:_g=$LogToGUI;$global:_s=$Logname;$global:_n="{0}-{1:yyyyMMdd-HHmmss}"-f$Logname,(Get-Date);$global:_p=$LogPath;$global:_d=$LogToDisk;$global:_e=$LogToEventlog;$global:_i=$LogEventIds;$global:_r=$LogToHost;$global:_w=([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
        if(!(Test-Path function:\global:_Time)){function global:_Time{Get-Date -f 'yyyy-MM-dd,HH:mm:ss'}}
        if(!(Test-Path function:\global:_ID)){function global:_ID{$c=(Get-PSCallStack)[2];$n=if($c.Command -and $c.Command -ne '<ScriptBlock>'){$c.Command}elseif($c.FunctionName -and $c.FunctionName -ne '<ScriptBlock>'){$c.FunctionName}else{'Main-Script'};if($n -like '*.ps1'){'Main-Script'}else{$n}}}
        if(!(Test-Path function:\global:_Save)){function global:_Save{try{if($global:_d){[IO.Directory]::CreateDirectory($global:_p)|Out-Null;[IO.File]::WriteAllLines((Join-Path $global:_p "$($global:_n).log"),$global:_l.ToArray())};if($global:_e -and $global:_w){$isAdmin=$false;try{$id=[Security.Principal.WindowsIdentity]::GetCurrent();$isAdmin=([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)}catch{};$la=$global:_l -join"`n";$h=$la -match ',ERROR,';$et=if($h){'Error'}elseif($la -match ',WARN,'){'Warning'}else{'Information'};$eid=if($h){$global:_i.Error}elseif($la -match ',WARN,'){$global:_i.Warn}else{$global:_i.Info};$ok=$false;try{Write-EventLog -LogName Application -Source $global:_s -EventId $eid -EntryType $et -Message $la -EA Stop;$ok=$true}catch{};if(-not $ok -and $isAdmin){try{[Diagnostics.EventLog]::CreateEventSource($global:_s,'Application')}catch{};try{Write-EventLog -LogName Application -Source $global:_s -EventId $eid -EntryType $et -Message $la}catch{}}}}catch{}}}
        if(!(Test-Path function:\global:_Clean)){function global:_Clean{$WhatIfPreference=$false;Remove-Item -Path function:\Write-Host,function:\Write-Output,function:\Write-Warning,function:\Write-Error,function:\Write-Verbose,function:\_Save,function:\_Clean,function:\_ID,function:\_Time -ea 0 -Force;Remove-Variable -Name _l,_g,_s,_n,_p,_d,_e,_i,_r,_w,_az -Scope Global -ea 0}}
        # Register exit handler FIRST (before Write-* overrides)
        $null=Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action{if($global:_l){try{_Save}catch{}};if(Test-Path function:\_Clean){_Clean}} -MaxTriggerCount 1
        # Create Write-* proxy functions (skip in Azure Automation)
        function Script:Write-Host{$m="$args";$c=(Get-PSCallStack)[1];$r="Row$($c.ScriptLineNumber)";$e="$(_Time),INFO,$r,$(_ID),$m";$global:_l.Add($e);if($global:_g){if($global:_az){Microsoft.PowerShell.Utility\Write-Output $m}else{Microsoft.PowerShell.Utility\Write-Host $e -ForegroundColor Green}}}
        function Script:Write-Output{$m="$args";$c=(Get-PSCallStack)[1];$r="Row$($c.ScriptLineNumber)";$e="$(_Time),OUTPUT,$r,$(_ID),$m";$global:_l.Add($e);if($global:_g){if($global:_az){Microsoft.PowerShell.Utility\Write-Output $m}else{Microsoft.PowerShell.Utility\Write-Host $e -ForegroundColor Green}}}
        function Script:Write-Verbose{$m="$args";$c=(Get-PSCallStack)[1];$r="Row$($c.ScriptLineNumber)";$e="$(_Time),VERBOSE,$r,$(_ID),$m";$global:_l.Add($e);if($global:_g -and $VerbosePreference -ne 'SilentlyContinue'){if($global:_az){Microsoft.PowerShell.Utility\Write-Verbose $m}else{Microsoft.PowerShell.Utility\Write-Host $e -ForegroundColor cyan}}}
        function Script:Write-Warning{$m="$args";$c=(Get-PSCallStack)[1];$r="Row$($c.ScriptLineNumber)";$e="$(_Time),WARN,$r,$(_ID),$m";$global:_l.Add($e);if($global:_g){if($global:_az){Microsoft.PowerShell.Utility\Write-Warning $m}else{Microsoft.PowerShell.Utility\Write-Host $e -ForegroundColor Yellow}};if($WarningPreference -eq 'Stop'){_Save;_Clean;exit}}
        function Script:Write-Error{$m="$args";$c=(Get-PSCallStack)[1];$r="Row$($c.ScriptLineNumber)";$e="$(_Time),ERROR,$r,$(_ID),$m";$global:_l.Add($e);if($global:_g){if($global:_az){Microsoft.PowerShell.Utility\Write-Error $m}else{Microsoft.PowerShell.Utility\Write-Host $e -ForegroundColor Red}};if($ErrorActionPreference -eq 'Stop'){_Save;_Clean;exit}}
    }
}

Function Get-ExecutionContext {
<#
.SYNOPSIS
    Detects how the script is being executed and (optionally) validates it against requirements; can auto-relaunch in 64-bit.
.DESCRIPTION
    Inspects environment variables, the script path, parent/ancestor processes, identity, and architecture and returns a PSCustomObject with the following properties:
    - CTXMode           : WinPE, AzureAutomation, AzureFunction, GitHubActions, GitLabCI, AzureDevOps, TaskSequence,
                              Remediation, Detection, PlatformScript, Intunewin, SCCM, GPO, or Standalone
    - CTXPath           : ProgramFiles, ProgramFilesX86, IMEContent, ProgramData, AppDataRoaming, AppDataLocal,
                              IMECache, CCMCache, SystemRoot, or Other
    - CTXSource         : Managed (set for any non-Standalone CTXMode), or one of
                              Manual, ScheduledTask, RemoteSession, VSCodeDebug, ISE, Explorer, Batch, Interactive
    - CTXIdentity       : System, LocalService, NetworkService, ServiceAccount, Admin, or User
    - CTXArchitecture   : x64 or x86
    - CTXPSVersion      : Version object from $PSVersionTable.PSVersion (e.g. 5.1.19041.0)
    - CTXOSBuild        : Integer Windows OS build number (0 on non-Windows)
    - CTXPendingReboot  : Boolean; $true when a reboot is pending (CBS / Windows Update / PendingFileRenameOperations)

    When any of -CTXReqIdentity / -CTXReqArchitecture / -CTXReqMode / -CTXReqPSVersion / -CTXReqOSBuild / -CTXAbortIfPendingReboot is provided, the detected context is validated:
    On success the context object is returned, on failure $null is returned (and an error is written).
.NOTES
    Version: 1.1.0
    
    Version History:
    1.0 - Initial version
    1.0.1 - Fixed some edge cases in detection logic
    1.1.0 - Added reqirements parameters and validation logic, and auto-relaunch to x64 if required and running x86
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(HelpMessage = 'Required execution identity. Valid: System, LocalService, NetworkService, ServiceAccount, Admin, User')]
        [ValidateSet('System','LocalService','NetworkService','ServiceAccount','Admin','User')]
        [string[]]$CTXReqIdentity     = @(),

        [Parameter(HelpMessage = 'Required process architecture. Valid: x64, x86 (empty = no requirement)')]
        [ValidateSet('x64','x86','')]
        [string]$CTXReqArchitecture   = '',

        [Parameter(HelpMessage = 'Required execution mode (any value returned in CTXMode).')]
        [string[]]$CTXReqMode         = @(),

        [Parameter(HelpMessage = 'Minimum required PowerShell version (e.g. 5.1). Fails if PSVersionTable.PSVersion is lower.')]
        [version]$CTXReqPSVersion  = $null,

        [Parameter(HelpMessage = 'Minimum required OS build number (e.g. 19041 for Win10 2004). Fails if OS build is lower.')]
        [int]$CTXReqOSBuild        = 0,

        [Parameter(HelpMessage = 'If set, abort when a reboot is pending (CBS, Windows Update, or file rename pending).')]
        [switch]$CTXAbortIfPendingReboot,

        [Parameter(HelpMessage = 'If set and process is x86 while x64 is required, relaunch via SysNative.')]
        [switch]$CTXAutoRelaunchToX64,

        [Parameter(HelpMessage = 'Caller bound parameters to forward on relaunch (pass $PSBoundParameters from the caller).')]
        [hashtable]$CTXForwardParameters   = @{}
    )
    Write-Verbose "Start function Get-ExecutionContext"
    # Initialize variables
    [string]$CTXMode    = 'Standalone'
    [string]$CTXPath    = 'Other'
    [string]$CTXSource  = 'Managed'
    [string]$CTXIdentity= 'User'
    [string]$scriptPath = $script:PSCommandPath
    [string]$scriptRoot = $script:PSScriptRoot
    # PS5.1 Desktop is always Windows; PS6+ exposes $IsWindows
    [bool]$isWin = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows

    # Helper: walk parent processes from $PID up to 8 levels using a PID->Win32_Process hashtable
    $getAncestors = {
        param([hashtable]$Table)
        $list = [System.Collections.Generic.List[int]]::new()
        $cur  = $PID
        while ($list.Count -lt 8 -and $Table.ContainsKey($cur)) {
            $parent = [int]$Table[$cur].ParentProcessId
            if ($parent -eq 0 -or $parent -eq $cur) { break }
            $list.Add($parent)
            $cur = $parent
        }
        ,$list
    }

    # ---- Execution Mode detection -------------------------------------------------------------------------------------------------------------------------------------------------------------------
    # Cross-platform managed-host signals first (env vars and PSPrivateMetadata work on every platform)
    if     ((Test-Path variable:PSPrivateMetadata) -and $PSPrivateMetadata.JobId)           { $CTXMode = 'AzureAutomation' }
    elseif ($env:FUNCTIONS_WORKER_RUNTIME -or $env:AZURE_FUNCTIONS_ENVIRONMENT)             { $CTXMode = 'AzureFunction'   }
    elseif ($env:GITHUB_ACTIONS -eq 'true')                                                 { $CTXMode = 'GitHubActions'   }
    elseif ($env:GITLAB_CI -eq 'true')                                                      { $CTXMode = 'GitLabCI'        }
    elseif ($env:TF_BUILD -eq 'True')                                                       { $CTXMode = 'AzureDevOps'     }
    elseif ($env:_SMSTSType -or $env:_SMSTSPackageID -or $env:SMSTSLogPath)                 { $CTXMode = 'TaskSequence'    }
    # Windows-only: WinPE detection requires HKLM provider
    if ($CTXMode -eq 'Standalone' -and $isWin) {
        try { if (Test-Path 'HKLM:\SYSTEM\ControlSet001\Control\MiniNT' -ErrorAction Stop) { $CTXMode = 'WinPE' } } catch {}
    }
    Write-Verbose "Enumerated CTXMode = $CTXMode after environment variable check"

    # If still standalone, get execution mode from script path (Remediation, Detection, PlatformScript, Intunewin, TaskSequence, SCCM)
    if ($CTXMode -eq 'Standalone' -and $scriptPath) {
        if     ($scriptPath -match 'IMECache\\HealthScripts\\.*\\remediate\.ps1$')          { $CTXMode = 'Remediation'    }
        elseif ($scriptPath -match 'IMECache\\HealthScripts\\.*\\detect\.ps1$')             { $CTXMode = 'Detection'      }
        elseif ($scriptPath -match 'IMECache\\Scripts\\')                                   { $CTXMode = 'PlatformScript' }
        elseif ($scriptPath -match 'Microsoft Intune Management Extension\\Content\\')      { $CTXMode = 'Intunewin'      }
        elseif ($scriptPath -match '_SMSTaskSequence\\')                                    { $CTXMode = 'TaskSequence'   }
        elseif ($scriptPath -match '\\ccmcache\\')                                          { $CTXMode = 'SCCM'           }
    }
    Write-Verbose "Enumerated CTXMode = $CTXMode after script path check"

    # If still standalone, walk parent processes via CIM (Windows-only) to detect Intunewin / GPO / SCCM / TaskSequence
    [hashtable]$procTable = @{}
    [System.Collections.Generic.List[int]]$ancestorPids = [System.Collections.Generic.List[int]]::new()
    if ($CTXMode -eq 'Standalone' -and $isWin) {
        try {
            Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction Stop -Verbose:$false |
                ForEach-Object { $procTable[[int]$_.ProcessId] = $_ }
        } catch { Write-Verbose "Failed to build process table with CIM: $_" }
        if ($procTable.Count -gt 0) {
            $ancestorPids = & $getAncestors $procTable
            foreach ($aPid in $ancestorPids) {
                if (-not $procTable.ContainsKey($aPid)) { continue }
                $procName = $procTable[$aPid].Name
                if     ($procName -in 'AgentExecutor.exe','IntuneManagementExtension.exe')  { $CTXMode = 'Intunewin';    break }
                elseif ($procName -eq 'gpscript.exe')                                       { $CTXMode = 'GPO';          break }
                elseif ($procName -in 'CcmExec.exe','ccmsetup.exe')                         { $CTXMode = 'SCCM';         break }
                elseif ($procName -in 'TSManager.exe','smstsbootstrap.exe')                 { $CTXMode = 'TaskSequence'; break }
            }
        }
    }
    Write-Verbose "Enumerated CTXMode = $CTXMode after CIM process detection"

    # ---- Execution path detection -------------------------------------------------------------------------------------------------------------------------------------------------------------------
    if ($scriptRoot) {
        $root = $scriptRoot.TrimEnd('\')
        $sc   = [StringComparison]::OrdinalIgnoreCase
        if     ($env:ProgramFiles        -and $root.StartsWith($env:ProgramFiles.TrimEnd('\'),                                                   $sc)) { $CTXPath = 'ProgramFiles'    }
        elseif (${env:ProgramFiles(x86)} -and $root.StartsWith(${env:ProgramFiles(x86)}.TrimEnd('\') + '\Microsoft Intune Management Extension', $sc)) { $CTXPath = 'IMEContent'      }
        elseif (${env:ProgramFiles(x86)} -and $root.StartsWith(${env:ProgramFiles(x86)}.TrimEnd('\'),                                            $sc)) { $CTXPath = 'ProgramFilesX86' }
        elseif ($env:ProgramData         -and $root.StartsWith($env:ProgramData.TrimEnd('\'),                                                    $sc)) { $CTXPath = 'ProgramData'     }
        elseif ($env:APPDATA             -and $root.StartsWith($env:APPDATA.TrimEnd('\'),                                                        $sc)) { $CTXPath = 'AppDataRoaming'  }
        elseif ($env:LOCALAPPDATA        -and $root.StartsWith($env:LOCALAPPDATA.TrimEnd('\'),                                                   $sc)) { $CTXPath = 'AppDataLocal'    }
        elseif ($env:SystemRoot          -and $root.StartsWith($env:SystemRoot.TrimEnd('\') + '\IMECache',                                       $sc)) { $CTXPath = 'IMECache'        }
        elseif ($env:SystemRoot          -and $root.StartsWith($env:SystemRoot.TrimEnd('\') + '\ccmcache',                                       $sc)) { $CTXPath = 'CCMCache'        }
        elseif ($env:SystemRoot          -and $root.StartsWith($env:SystemRoot.TrimEnd('\'),                                                     $sc)) { $CTXPath = 'SystemRoot'      }
    }
    Write-Verbose "Enumerated CTXPath = $CTXPath after path detection"

    # ---- Source detection (Windows-only; relies on CIM and Windows hosts) ---------------------------------------------------------------------------------------------------------------------------
    if ($CTXMode -eq 'Standalone') {
        $CTXSource = 'Manual'
        if ($isWin) {
            try {
                if ($procTable.Count -eq 0) {
                    Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction Stop -Verbose:$false |
                        ForEach-Object { $procTable[[int]$_.ProcessId] = $_ }
                    $ancestorPids = & $getAncestors $procTable
                }
                $parentName    = if ($ancestorPids.Count -gt 0 -and $procTable.ContainsKey($ancestorPids[0])) { $procTable[$ancestorPids[0]].Name } else { '' }
                $ancestorNames = $ancestorPids | Where-Object { $procTable.ContainsKey($_) } | ForEach-Object { $procTable[$_].Name }
                $svchostPid    = $ancestorPids | Where-Object { $procTable.ContainsKey($_) -and $procTable[$_].Name -eq 'svchost.exe' } | Select-Object -First 1
                $svcNames      = if ($svchostPid) { @(Get-CimInstance Win32_Service -Filter "ProcessId=$svchostPid" -Property Name -ErrorAction SilentlyContinue | ForEach-Object Name) } else { @() }
                if     ($svcNames -contains 'Schedule')                              { $CTXSource = 'ScheduledTask' }
                elseif ($parentName -eq 'wsmprovhost.exe')                           { $CTXSource = 'RemoteSession' }
                elseif ($Host.Name -eq 'Visual Studio Code Host' -or
                        [bool]($ancestorNames -match '^Code( - Insiders)?\.exe$'))  { $CTXSource = 'VSCodeDebug'   }
                elseif ($Host.Name -eq 'Windows PowerShell ISE Host')                { $CTXSource = 'ISE'           }
                elseif ($parentName -eq 'explorer.exe')                              { $CTXSource = 'Explorer'      }
                elseif ($parentName -eq 'cmd.exe')                                   { $CTXSource = 'Batch'         }
                elseif ($parentName -in 'powershell.exe','pwsh.exe')                 { $CTXSource = 'Interactive'   }
            } catch                                                                  { $CTXSource = 'Manual'        }
        }
    }
    Write-Verbose "Enumerated CTXSource = $CTXSource after source detection"

    # ---- Identity detection (Windows-only; WindowsIdentity throws on Linux/macOS pwsh) --------------------------------------------------------------------------------------------------------------
    if ($isWin) {
        try {
            $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $principal       = [System.Security.Principal.WindowsPrincipal]$currentIdentity
            if     ($currentIdentity.IsSystem)                                                                      { $CTXIdentity = 'System'         }
            elseif ($currentIdentity.User.Value -eq 'S-1-5-19')                                                     { $CTXIdentity = 'LocalService'   }
            elseif ($currentIdentity.User.Value -eq 'S-1-5-20')                                                     { $CTXIdentity = 'NetworkService' }
            elseif ($currentIdentity.Name -like 'NT SERVICE\*' -or $currentIdentity.Name -like 'NT AUTHORITY\*')    { $CTXIdentity = 'ServiceAccount' }
            elseif ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))             { $CTXIdentity = 'Admin'          }
            else                                                                                                    { $CTXIdentity = 'User'           }
        } catch { Write-Verbose "Failed to detect CTXIdentity, defaulting to 'User'. Error: $_" }
    }
    Write-Verbose "Enumerated CTXIdentity = $CTXIdentity after identity detection"

    # ---- Architecture / PS version / OS build / pending reboot --------------------------------------------------------------------------------------------------------------------------------------
    [string]$CTXArchitecture = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
    [version]$CTXPSVersion   = $PSVersionTable.PSVersion
    [int]$CTXOSBuild         = if ($isWin) { [Environment]::OSVersion.Version.Build } else { 0 }
    [bool]$CTXPendingReboot  = $false
    if ($isWin) {
        try {
            if     (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')                                                                       { $CTXPendingReboot = $true }
            elseif (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')                                                                      { $CTXPendingReboot = $true }
            elseif ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations) { $CTXPendingReboot = $true }
        } catch { Write-Verbose "Failed to detect pending reboot state. Error: $_" }
    }
    Write-Verbose "Enumerated CTXArchitecture=$CTXArchitecture, CTXPSVersion=$CTXPSVersion, CTXOSBuild=$CTXOSBuild, CTXPendingReboot=$CTXPendingReboot"

    [PSCustomObject]$CTX = [PSCustomObject]@{
        CTXMode          = $CTXMode
        CTXPath          = $CTXPath
        CTXSource        = $CTXSource
        CTXIdentity      = $CTXIdentity
        CTXArchitecture  = $CTXArchitecture
        CTXPSVersion     = $CTXPSVersion
        CTXOSBuild       = $CTXOSBuild
        CTXPendingReboot = $CTXPendingReboot
    }

    # ---- Requirement validation (only runs if any requirement parameter is provided) ---------------------------------------------------------------------------------------------------------------
    [bool]$ok = $true
    if ($CTXReqIdentity.Count -gt 0 -and $CTX.CTXIdentity -notin $CTXReqIdentity) {
        Write-Error "Required identity: $($CTXReqIdentity -join '/'), actual: $($CTX.CTXIdentity)."
        $ok = $false
    }
    if ($CTXReqMode.Count -gt 0 -and $CTX.CTXMode -notin $CTXReqMode) {
        Write-Error "Required execution mode: $($CTXReqMode -join '/'), actual: $($CTX.CTXMode)."
        $ok = $false
    }
    if ($CTXReqArchitecture -and $CTX.CTXArchitecture -ne $CTXReqArchitecture) {
        if ($CTXAutoRelaunchToX64 -and $CTXReqArchitecture -eq 'x64' -and [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
            # Resolve caller script path: prefer $script:PSCommandPath, else first call-stack frame with a ScriptName
            [string]$callerScript = $scriptPath
            if (-not $callerScript) {
                foreach ($frame in (Get-PSCallStack)) {
                    if ($frame.ScriptName) { $callerScript = $frame.ScriptName; break }
                }
            }
            [string]$sysNative = "$env:SystemRoot\SysNative\WindowsPowerShell\v1.0\powershell.exe"
            if (-not $callerScript -or -not (Test-Path -LiteralPath $callerScript)) {
                Write-Error "CTXAutoRelaunchToX64 requires a file-based script (caller path '$callerScript' not resolvable). Architecture requirement failed."
                return $null
            }
            if (-not (Test-Path -LiteralPath $sysNative)) {
                Write-Error "CTXAutoRelaunchToX64 failed: '$sysNative' not found. Architecture requirement failed."
                return $null
            }
            # Build a single -Command line that re-invokes the caller script with forwarded parameters
            [string]$cmdLine = "& '" + ($callerScript -replace "'","''") + "'"
            foreach ($k in $CTXForwardParameters.Keys) {
                $v = $CTXForwardParameters[$k]
                if     ($v -is [switch])  { if ($v.IsPresent) { $cmdLine += " -$k" } }
                elseif ($v -is [bool])    { $cmdLine += " -${k}:`$$($v.ToString().ToLower())" }
                elseif ($v -is [array])   { $cmdLine += " -$k '" + (($v | ForEach-Object { $_ -replace "'","''" }) -join "','") + "'" }
                else                      { $cmdLine += " -$k '" + ($v.ToString() -replace "'","''") + "'" }
            }
            Write-Warning "Process is x86; relaunching as x64 via SysNative: $sysNative"
            $proc = Start-Process -FilePath $sysNative -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command', $cmdLine) -Wait -NoNewWindow -PassThru
            exit $proc.ExitCode  # exits the current script/host after the relaunched x64 process completes
        }
        Write-Error "Required architecture: $CTXReqArchitecture, actual: $($CTX.CTXArchitecture)."
        $ok = $false
    }
    if ($CTXReqPSVersion -and $CTX.CTXPSVersion -lt $CTXReqPSVersion) {
        Write-Error "Required minimum PowerShell version: $CTXReqPSVersion, actual: $($CTX.CTXPSVersion)."
        $ok = $false
    }
    if ($CTXReqOSBuild -gt 0 -and $CTX.CTXOSBuild -lt $CTXReqOSBuild) {
        Write-Error "Required minimum OS build: $CTXReqOSBuild, actual: $($CTX.CTXOSBuild)."
        $ok = $false
    }
    if ($CTXAbortIfPendingReboot -and $CTX.CTXPendingReboot) {
        Write-Error "A reboot is pending on this machine. Aborting as -CTXAbortIfPendingReboot is set."
        $ok = $false
    }
    if (-not $ok) { return $null }
    return $CTX
}
Function Add-AddRemovePrograms {
    <#
    .SYNOPSIS
        Adds an application entry to Add Remove Programs (ARP) in Windows, allowing it to be displayed and optionally uninstalled or modified from there.
    .DESCRIPTION
        This function creates the necessary registry entries and files to make a script or application appear in the Add Remove Programs list in Windows Settings.
        It supports custom uninstall and modify scripts, as well as an application icon. 
        The function is designed to be flexible and can be used for various types of applications or scripts that need to be managed through ARP.
    .NOTES
        Author:  @MrTbone_se (T-bone Granheden)
        Version: 1.1.0
        
        Version History:
        1.0 - Initial version
        1.0.1 - Changed parameter names end improved error handling
        1.1.0 - Major refactor to support more features, better logging and error handling, and to be more modular and maintainable. Added parameters for shortcuts and folder copying.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory = $false,          HelpMessage = 'Name of the application/script being wrapped')]
        [String]$ARPAppName             = "App Name",

        [Parameter(Mandatory = $false,          HelpMessage = 'Version of the application. Increment when changing config')]
        [ValidatePattern("^\d+\.\d+\.\d+$")]
        [version]$ARPAppVersion         = "1.0.0",

        [Parameter(Mandatory = $false,          HelpMessage = 'GUID of the application/script being wrapped. NOTE: This needs to be unique for each wrapped app')]
        [ValidatePattern('^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$')]
        [String]$ARPAppGuid             = "{feedbeef-beef-4dad-beef-b628ccca16e0}",

        [Parameter(Mandatory = $false,          HelpMessage = 'Company name used for naming of folders and registry keys')]
        [String]$ARPAppPublisher        = "Coligo",
        
        [Parameter(Mandatory = $false,          HelpMessage = "Application folder path, if not specified, it will use %ProgramFiles%\ARPPublisher\ARPAppName ")]
        [string]$ARPAppFolder           = "$Env:Programfiles\$ARPAppPublisher\$ARPAppName",
        
        [Parameter(Mandatory = $false,          HelpMessage = 'Enable an uninstall option in Add Remove Programs')]
        [bool]$ARPAppEnableUninstall    = $True,

        [Parameter(Mandatory = $false,          HelpMessage = 'Enable a modify option in Add Remove Programs (typically for repair/reinstall)')]
        [bool]$ARPAppEnableModify       = $True,

        [Parameter(Mandatory = $false,          HelpMessage = 'Optional Base64-encoded .ico content to use as the icon of the app')]
        [string]$ARPAppIcon,
        
        [Parameter(Mandatory = $false,          HelpMessage = 'Optional path to a .ps1 file to use as the installer script')]
        [string]$ARPAppInstallScript    = "",

        [Parameter(Mandatory = $false,          HelpMessage = 'Optional path to a .ps1 file to use as the uninstaller script')]
        [string]$ARPAppUnInstallScript  = "",

        [Parameter(Mandatory = $false,          HelpMessage = 'Optional path to a .ico file to use as the icon of the app')]
        [string]$ARPAppIconPath         = "",

        [Parameter(Mandatory = $false,          HelpMessage = 'If $true, copy every file in the wrapper''s source folder into the app folder (excluding the wrapper itself, the install/uninstall scripts and the icon, which are deployed under standardized names).')]
        [bool]$ARPAppIncludeFolder      = $false,

        [Parameter(Mandatory = $false,          HelpMessage = 'Optional leaf name of a companion file inside the app folder to launch the app (e.g. t-bone.exe). Required for shortcut creation.')]
        [string]$ARPAppUserStartFile    = "",

        [Parameter(Mandatory = $false,          HelpMessage = 'Create an All-Users Desktop shortcut to ARPAppUserStartFile')]
        [bool]$ARPAppShortcutOnDesktop  = $false,

        [Parameter(Mandatory = $false,          HelpMessage = 'Create an All-Users Start Menu shortcut to ARPAppUserStartFile')]
        [bool]$ARPAppShortcutInStart    = $false,

        [Parameter(Mandatory = $false,          HelpMessage = 'Force overwrite of existing files and registry entries')]
        [bool]$ARPAppForce              = $False
    )
    Begin {
        $ErrorActionPreference = 'Stop'
        Write-Verbose "Start Function Add-AddRemovePrograms"
        $private:HKCRDrive = $false

        # Default demo app icon, used when no icon path or Base64 is provided.
        $script:DefaultIconBase64 = ('AAABAAIAEBAAAAEAIAD+AwAAJgAAACAgAAABACAAJQsAACQEAACJUE5HDQoaCgAAAA1JSERSAAAAEAAAABAIBgAAAB/z/2EAAAABc1JHQgCuzhzpAAAABGdBTUEAALGPC/xhBQAAAAlwSFlzAAAOwwAADsMBx2+oZAAAA5NJREFUOE9F0ttP2wUUB/AvE+jl
                    96O0rP219EbpjdtaeqHtyg9GS0tHW+7CGKWj4ybShQ46tpay0UlH2EQckxkxJrKEB02MxpmYGB988JKYGB98W1yMxsTEB2P8D46pGD3JeTyf883JwViLDpO2RiQcFqS8rVjucSI32IXdZD8O5ofwaH4IB3ODeLiSxFsPinjn8R4O93dwt5BFsbAGxK0ajLc1
                    YNppwTxvx1qUx58f7ePkXhYAqt+8Non9+VHsrS3g8H4Rj1/fwf3SJu7krmMrvwqEjPUItVox7W5K92oV2yMGOS3b6+loto+ell6mJzOhG6XUMEqri9jb3sCD0iaKhSw2b67gdi4DBAwqeLXcxy/ZdbTo0NEvz76jL7/5gsp1cPAqrYc7CIDu6ScfFL79+vNQ
                    eXP+xjXksmnks2nAazIsWOpqKWVrJJ6rIRlQHvgHCMrO0HEyRBbgaLuYo1try2SqZ3Fy/HbTxvrKrdd2t47R3cA9dyokxFaL6JKtmTJOC1UB9Otvzyke5Cm9NEstEsFuIZehO7nMDxOjMbq3tU4b62lKTAz+iNpaabufY0krZugwWEU/pxnqk4IevrFH7+/c
                    pCmDrJwovlPKf3o1MUblnhofoMT4AMUjPV/Bp5Lg2ZIVnjqG/lgC/ZQELRgqKBKN0PefvUerdnUZCN/OZ2go2vt7kPc+AWA9efcRLo/FgS4Vg0G9CBfFMA1pK8knF9HouWbSqlW0nhymjENHVSw7AoEwcGV8AKPxMAYiPYhHejAcCwF9aiFG9AKMNwpBr2gQ
                    rGfJJGFpzKqlo347XXcZaK5V1zHha8NwwId4uBvhC+cR4D2IBDqBuEaAmEaAPo0IQTUDm1SY61GKqV0hpbSnmcJmPc06G+cSDhMm3E2IdboQ8Ltx3m0D73UAffUCXFCKwCvF4JUMAuoa+OSiv7rk1RRtkNJih5HcEgGuOIyYcZkw5bIg5G6Ds60J55qMgF8h
                    hFchhk/BwM8x4JUsIrra8nE/TLjMc2NWFabtDUg5jZjrMGOVb0W/VYPKigpUlJ/dcVYMt1wMTxnhGHQqWXSrJQjpZIibOLzYokHC3oCrLiPmPWak3GbYVTKcAU4Be50YzrNidMjF8HIM/KoadKtr0auvQ8zEYbRFg8s2PWb+TTBpN0DJCP8HWmUitNeJ4Cqn
                    4NhTQHMKRE0cRpo1uGTTI+lsRMptwkWLGmzlC/8BfwOcUBv1oWxTjwAAAABJRU5ErkJggolQTkcNChoKAAAADUlIRFIAAAAgAAAAIAgGAAAAc3p69AAAAAFzUkdCAK7OHOkAAAAEZ0FNQQAAsY8L/GEFAAAACXBIWXMAAA7DAAAOwwHHb6hkAAAKuklEQVRY
                    R+WWeWyT9xnHvzlsx06c2PERx3Z830d8xVec2zmcA0IuEnIfBEJIKAmQAiGMI4EQGgKEo1Ao59qyDpW2QmvVatXard00CdRKnTamoW1dV1XV2q6ddmp+ptfQDlWtRPfvHumr16/9vM/349/1PsADUaaVo0wnR7leiahRhSqLBtVWLaptejS4TFgTsGKk0IKx
                    sBGjYRPGiyyYLLVhR9SOvTEnZmudaFKLwAOQDCDpK/ra6DRL0W2Voc+pwIBbg26PHqscesQsGsSsWtTbdKi369HkNqI3aMWmEismSyyYKLVha4UD09Uu7K/34HCjD4urCjDm1yMzOQmpAFLu6wuYr401Jim6LDL0OhTod6nR49GjLd+AFTYdGmw6NDr0aM7X
                    o8NrxHChFVOVTuyqcWFXrRd7V/ox3xzEkbYwjrWFsdgUxM4KJ/K4bHAAsAGwGIgkIDUFyMoC1OqvALQYJOgw56DHLkdfvgo9bh3aXQa0OA1ochrQ5jKiy2dmUvkeX0C8tzHIfOYZgKg3CfbTgzU42VOBo+0lOLAyhN3tNViam8Gvbr+B5cdmcWJxDsuLc1iY
                    m8Zg70qoVF+BqFKLscogRYclFz0OJXpcGnS69FjjNoLo97AqFBtXmZRUqsymUU8uzZWIFx71ZtOBBhed7QnQcnnuoycH63GgqRjbawKY3TSE00cP4vzpJVw+t4yr50/gqYuncfnccQx0NaO9uR59nS0Y7u/AxnW9QFAhRlQtwUpDDrq1fPtkxPR5ldNGq90W
                    qtHKqTJPTJvMQtpmFdBs1E5z7TH60cVD9M5LV+iHl47Tk+OdtNuvqNxe48fm2ggO7pzAiSNzePz4ITz5+BKuPnkST188jVPH5rF/9xQ2jQxguK8DI0NdGB/pBzxyCUJKCSq1MjQo+G92GwTUq8+iuXIzPeoU00tHZ+gvn7xP3xQ/ee4KdelEBEAw3hjF3PQk
                    jszvwbHD+3FmeQGXnziOi2ePYX7/dEI7toxhdLgHY+v6MDG2FvAqc1BjVMErE/7GpdXQupCDJiMOmghbSCsV0r/in9HtW6/Hh3paqCzoTJjevfN2HABxU0ANTi2NmLKpR515A4Dm5vPX6MzyAl1/+jzd/tlrvrMnDmPp0B7s3bUVC7O7sGfnJDZvHMLExiFM
                    TYwAQVUuzHLZTa8ih/KEAhr0mmjYJqdWk5z5V8RhJTNXxjBhSvQZwxBPBsgB0On6fNofVlOfkvcCgPe//9Q5am6o+lSjlNG7t16nhdlpzGzfjN3bN+PQ7DT2zWzFgb3b0d7c0P7K81eB3y5tZZUYVKTLFpCDz6ZqXS5tDllpsshOERGXYhoJtdo1cfl9gDvv
                    /jQBMFVkoh2tUXp5YRtdneylmRL7FQDSo4f30br+9qlCv5tevXntb0SE5753+apcKmq5dvXcu9eunCW/2/73c6cW6cCeqduotmgXy9US8sqySc/nkpLPI41IRIMBG20LW2hL2EKbfLp4Wa4gMSLXn34iATDZVkdlpWH6818/ol/8+h1aeGTwEwC2C2eWKBYt
                    fm9pfg+TLx8d7qPGuig9sqGfXr35DO2aGqORtd1UHC6gx+Z2XkCBUtrtkwmoySAhpzCdRGls4rPYZMhVxEcDjnivQ0/T0UC8za5PAEyNDzL+8TOLs4l7RikAFXLwHoCKpy6coPrqUlo6uIsmx4ffeOLEISbnn4M9bbR7+zhNjg/R/pkttHl0gPneD59cDJM0
                    m2rUQqpSZJJJkEHsFC5FZcn0nagmfqGWR2+sN8VHPNaEWcRjpX//46P4rbdeoSKAOm0qGgrYaMQoHgMw8Mylk0xejygrg37w3GV65uIyc//myFAXTYwN0akj+6ipoZKCvvzPx0f67sCVI2AOzDxdZtovi6VcataLSMDKoBsx0I1ViNMM6HqLIP5Cmyzu4YKE
                    3FS6e+fn8Q8+vEu7/Uqa9Gmoy6mhAsAAYPd3zx9lpggOs46OHpqhY4dmKBL0UWHATQPdLdSyooqCXie1N8USebCLM5EvzoBfkg5teurzdaosMvCz6NZq0J/GU+hWJ+itdsSvREExWUpiFG48ez7+8ad/oD3VLpqvtFGnXUXzW9czB+vxS2ceY3JGt20aJr/b
                    RiGvk9YPrKFMHuflTB5nkHnprmldgVX1lWioKQMs2RlwZvNQIOaiVMaDLTPtw7CAS7e7QR9vAJ0qBP1uEPHNXnW8RilJACwe3Bm/e/dtOjExQNN+FQ26dfRIRwMcNtMH1y4epw1D3dS6sobefO0GpAJ+6dq+dpRF/IgEPCgJeVFeFEBNeQSxighgEfKQn81F
                    QJyGclkaFgJc9GtYdLEyhWISDm3Qg5qMoniny0a9Dk0CYGxdV/zZ65dopDVGOwpU1GeVk4bPmXE7LWTW5RGXlbx9cmwItdEiVBQHEoaMeYHLllDI50RZYQGiJUHAKkiDR8hBWMxBdS4bzSo2FkMcyNjsPzqzuJQvSCcWO4MqvR7aUualbIBMRlVczefQ7nIH
                    LdZ5qckop9aVMdR6zIiGPKgo8t8zjvhRFPAg4nch5HXC4zDDZTPC6zQj7HOiOOQBVOkseIVsRMRsVMpYiMlZqMxlo1zGQQ6HdaU+L4MaVJnE56RRlV5BFTkZVJKTRfuKLXSs2kHH61y02qygIYt0S3u+DrVuMyIeO4IeR8KUkd9tR0G+FflWIxwmHZxmHVxW
                    A9w2w71ORZ+RirCIhSIJC4ViFvwiDvxiLopz0hGQpNNqXRZ5BWlkEvCp3qql+RURWq5101LMRVt8auq0KqkvYKNulx6dbj1WuIwIOs0oyLcwuwEOs/6eTDrYTVrYjJoHGgKmZUoCHFmp8AlZcAvZcGenwSfmIShJZ361hyTp1KgRkI7HInlmJnXY1PEjdX6a
                    LXfSoN9GxQ4bdbgN1OXSo8etT3RVc3WJxgXs1BQkJ31jQ/bfYCUDtiw2HMI0uLK58Ih48Et4CEvT4c7mvthmEFKZlEuhbA4pBAKqtugpppGRTSqhqEJAEz7Vj3vdWvR7dBjy6fHiWH2iLtMbPoT9vVCms2EXchO7ggEoEPMQkqajWy+AV8yjZp2A6hQ88mel
                    kIULqlLwqc0kobFCM+2MBVYwxsMFeowGmG6K2TD3esKHjtTkJNgE9wDcIh5jmoAISJhGGyxbJpvC4jSqlHFptUlMQx4VjRZaaGPYfIYxXxcwYiRowljY8mVN7rcdBSOPBef9UWB0bzq48Im4eKdRzawNKpZnUZNdRf1+4+EuWRIGfToM+w1YHzRiJGTGnip3
                    olb4gboPDZAHwM5lwZ7JgV2QllgT+UIuvCIegtJ0hEVpKNIrS6qUWWi1KdHt1mDAp8NaBiBgxLqg8ctaVQ/UfWgAGQBLUhIs7BRY+OwEBDMKPkk6QjI+ihUCVKjFqDXI0GxTYo1Lgz6vDoMFhgREp0cDMY+FTAASIHH9VlPAPGRilASYOalwMCelOB2BHD4i
                    CgFK8kQo10hQY5Ch0apEe74a3R4d+nx69Pl0CGqFSEtJ+t8BRMw6uC9TchLcQh4CskwUKgQozstGqVqCcq0UVYZcNFiUaHWq0enWosurQ4NTDrEwGexkgH8fgLl+KwAmmBf7FyrITkeJSoRStThhXqaRolyXg0pDLmJmBVbYVGi0q1FhlUKpBLIy8SWA+H8F
                    +L+K/wCOcMeE2Xdw+QAAAABJRU5ErkJggg==')
    }
    Process {
        # Determine scripts own name and path
        if (-not $PSCommandPath) {
            Write-Error "Could not determine the script path. Ensure this is run as a .ps1 file, not pasted into a console."
            $false
            return
        }
        $ExecutingScriptPath = $PSCommandPath
        $ExecutingScriptName = Split-Path $PSCommandPath -Leaf
        Write-Verbose "Executing script is enumerated as: $ExecutingScriptPath ($ExecutingScriptName)"

        # Convert GUID to MSI Packed GUID (ProductID)
        # MSI reverses each segment: segments 1-3 are fully reversed, segments 4-5 are pair-swapped
        # Example: {FEEDBEEF-BEEF-4DAD-BEEF-B628CCCA16E0} → FEEBDEEFFEEBDAD4EBFE6B82CCAC610E
        [string]$private:stripped = $ARPAppGuid -replace '[{}\-]', ''
        [string]$ARPFuncProductID = (
            # Segment 1 (8 chars): reverse
            ($stripped[7..0] -join '') +
            # Segment 2 (4 chars): reverse
            ($stripped[11..8] -join '') +
            # Segment 3 (4 chars): reverse
            ($stripped[15..12] -join '') +
            # Segments 4+5 (16 chars): swap each pair
            (($stripped[16..31] | ForEach-Object -Begin { $private:pair = @() } -Process {
                $pair += $_
                if ($pair.Count -eq 2) { $pair[1]; $pair[0]; $pair = @() }
            }) -join '')
        )
        Write-Verbose "Derived MSI Packed GUID (ProductID): $ARPFuncProductID"

        # Standardized deployed names so batches and registry are stable regardless of source filenames.
        [string]$private:DeployedWrapperName     = 'App-Wrapper.ps1'
        [string]$private:DeployedInstallerName   = "installer-$ARPAppGuid.ps1"
        [string]$private:DeployedUninstallerName = "uninstaller-$ARPAppGuid.ps1"
        [string]$DeployedWrapperPath     = Join-Path -Path $ARPAppFolder -ChildPath $DeployedWrapperName
        [string]$DeployedInstallerPath   = Join-Path -Path $ARPAppFolder -ChildPath $DeployedInstallerName
        [string]$DeployedUninstallerPath = Join-Path -Path $ARPAppFolder -ChildPath $DeployedUninstallerName

        # Registry / icon / batch paths
        [string]$ARPFuncIconPath        = Join-Path -Path $ARPAppFolder -ChildPath "$($ARPAppName -replace '\s', '').ico"
        [string]$ARPFuncUninstallRegKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ARPAppGuid"
        [string]$ARPFuncProductsRegKey  = "HKCR:\Installer\Products\$ARPFuncProductID"

        # Version gate: skip install when an equal-or-newer version is already registered (unless -ARPAppForce $true).
        # Emits $true if the caller should proceed with the installer payload, $false to skip.
        if (-not $ARPAppForce) {
            [version]$private:CurrentVersion = '0.0.0.0'
            try {
                Write-Verbose "Checking installed version under $ARPFuncUninstallRegKey."
                $private:dv = (Get-ItemProperty -LiteralPath $ARPFuncUninstallRegKey -Name DisplayVersion -ErrorAction Stop).DisplayVersion
                if ($dv) {
                    $CurrentVersion = [version]$dv
                    Write-Verbose "Found installed app, CurrentVersion=$CurrentVersion"
                } else {Write-Verbose "DisplayVersion missing/empty under $ARPFuncUninstallRegKey; treating as not installed."}
            } catch [System.Management.Automation.ItemNotFoundException],[System.Management.Automation.PSArgumentException] {
                Write-Verbose "Registry key $ARPFuncUninstallRegKey not found; treating as not installed."
            } catch {Write-Verbose "Failed to read/parse DisplayVersion from $ARPFuncUninstallRegKey ($_); treating as not installed."}
            if ($CurrentVersion -ge $ARPAppVersion) {
                Write-Verbose "Skipping install: installed version ($CurrentVersion) is >= packaged version ($ARPAppVersion). Use -ARPAppForce `$true to override."
                $false
                return
            }
            Write-Verbose "Proceeding with install: $CurrentVersion -> $ARPAppVersion."
        }
        [string]$ARPFuncUninstallBAT    = Join-Path -Path $ARPAppFolder -ChildPath "uninstall-$ARPAppGuid.bat"
        [string]$ARPFuncModifyBAT       = Join-Path -Path $ARPAppFolder -ChildPath "reinstall-$ARPAppGuid.bat"
        [string]$ARPFuncUninstallString = 'CMD /C START cmd /c "{0}"' -f $ARPFuncUninstallBAT
        [string]$ARPFuncModifyString    = 'CMD /C START cmd /c "{0}"' -f $ARPFuncModifyBAT

        # Common batch line: cd to a known-good working directory before invoking PowerShell
        [string]$ARPFuncUninstallcmd1   = 'cd /d "%SystemRoot%"'
        [string]$ARPFuncModifycmd1      = $ARPFuncUninstallcmd1

        # Build the PowerShell command lines that the .bat files will run.
        $private:BuildPwshLine = {
            param([string]$InstallTypeArg, [string]$ExtraArgs)
            "Powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"& '$DeployedWrapperPath' -installtype $InstallTypeArg$ExtraArgs`""
        }

        # Uninstall extras: pass -ARPAppUnInstallScript only if a uninstall script will actually be deployed
        [string]$private:UninstallExtraArgs = ''
        if ($ARPAppUnInstallScript -and (Test-Path $ARPAppUnInstallScript)) {
            $UninstallExtraArgs = " -ARPAppUnInstallScript '$DeployedUninstallerPath'"
        }
        [string]$ARPFuncUninstallcmd2 = & $BuildPwshLine 'UnInstall' $UninstallExtraArgs

        # Modify (ReInstall) extras: forward shortcut/include flags + optional installer script
        [string]$private:ModifyExtraArgs = ''
        if ($ARPAppIncludeFolder)                                    { $ModifyExtraArgs += " -ARPAppIncludeFolder `$true" }
        if (-not [string]::IsNullOrWhiteSpace($ARPAppUserStartFile)) { $ModifyExtraArgs += " -ARPAppUserStartFile '$ARPAppUserStartFile'" }
        if ($ARPAppShortcutOnDesktop)                                { $ModifyExtraArgs += " -ARPAppShortcutOnDesktop `$true" }
        if ($ARPAppShortcutInStart)                                  { $ModifyExtraArgs += " -ARPAppShortcutInStart `$true" }
        if ($ARPAppInstallScript -and (Test-Path $ARPAppInstallScript)) {
            $ModifyExtraArgs = " -ARPAppInstallScript '$DeployedInstallerPath'" + $ModifyExtraArgs
        }
        [string]$ARPFuncModifycmd2 = & $BuildPwshLine 'ReInstall' $ModifyExtraArgs

        # Ensure application folder exists otherwise create it
        if(-not (Test-Path $ARPAppFolder) -or $ARPAppForce){
            if ($PSCmdlet.ShouldProcess($ARPAppFolder, "Create application folder")) {
                try {
                    New-Item -ItemType Directory -Path $ARPAppFolder -Force -ErrorAction Stop | Out-Null
                    Write-Verbose "Application folder ready: $ARPAppFolder"
                    } catch {Write-Warning "Failed to create folder $ARPAppFolder. Error: $_"}
            }
        } else {Write-Verbose "Application folder already exists: $ARPAppFolder"}

        # Create and Save the AppIcon - prefer external .ico file, then parameter Base64, then embedded default Base64
        [string]$private:EffectiveIconBase64 = if ($ARPAppIcon) { $ARPAppIcon } else { $script:DefaultIconBase64 }
        if ($ARPAppIconPath -and (Test-Path $ARPAppIconPath)) {
            if (-not (Test-Path $ARPFuncIconPath) -or $ARPAppForce) {
                if ($PSCmdlet.ShouldProcess($ARPFuncIconPath, "Copy AppIcon from $ARPAppIconPath")) {
                    try {
                        Copy-Item -Path $ARPAppIconPath -Destination $ARPFuncIconPath -Force | Out-Null
                        Write-Verbose "Success to copy AppIcon from $ARPAppIconPath to $ARPFuncIconPath"
                    } catch {Write-Warning "Failed to copy AppIcon from $ARPAppIconPath. Error: $_"}
                }
            } else {Write-Verbose "AppIcon already exists: $ARPFuncIconPath"}
        } elseif ($EffectiveIconBase64 -and (-not (Test-Path $ARPFuncIconPath) -or $ARPAppForce)) {
            if ($PSCmdlet.ShouldProcess($ARPFuncIconPath, "Save AppIcon from Base64")) {
                try {
                    $ContentBytes = [System.Convert]::FromBase64String($EffectiveIconBase64)
                    [System.IO.File]::WriteAllBytes($ARPFuncIconPath, $ContentBytes)
                    Write-Verbose "Success to save AppIcon from Base64 to $ARPFuncIconPath"
                } catch {Write-Warning "Failed to save AppIcon to $ARPFuncIconPath. Error: $_"}
            }
        } elseif (Test-Path $ARPFuncIconPath) {Write-Verbose "AppIcon already exists: $ARPFuncIconPath"}

        # Save the current PowerShell script (renamed to standardized deployed name)
        if ($ExecutingScriptPath -ne $DeployedWrapperPath -or $ARPAppForce) {
            if ($PSCmdlet.ShouldProcess($DeployedWrapperPath, "Copy wrapper script")) {
                try {
                    Copy-Item $ExecutingScriptPath $DeployedWrapperPath -Force | Out-Null
                    Write-Verbose "Success to copy script to $DeployedWrapperPath"
                } catch {Write-Warning "Failed to copy script to $DeployedWrapperPath. Error: $_"}
            }
        } else {Write-Verbose "Script already exists at target: $DeployedWrapperPath"}

        # Copy external install script if provided (renamed to standardized deployed name)
        if ($ARPAppInstallScript -and (Test-Path $ARPAppInstallScript)) {
            $private:InstallTarget = Join-Path -Path $ARPAppFolder -ChildPath $DeployedInstallerName
            if (-not (Test-Path $InstallTarget) -or $ARPAppForce) {
                if ($PSCmdlet.ShouldProcess($InstallTarget, "Copy install script")) {
                    try {
                        Copy-Item -Path $ARPAppInstallScript -Destination $InstallTarget -Force | Out-Null
                        Write-Verbose "Success to copy install script to $InstallTarget"
                    } catch {Write-Warning "Failed to copy install script. Error: $_"}
                }
            } else {Write-Verbose "Install script already exists at target: $InstallTarget"}
        }

        # Copy external uninstall script if provided (renamed to standardized deployed name)
        if ($ARPAppUnInstallScript -and (Test-Path $ARPAppUnInstallScript)) {
            $private:UninstallTarget = Join-Path -Path $ARPAppFolder -ChildPath $DeployedUninstallerName
            if (-not (Test-Path $UninstallTarget) -or $ARPAppForce) {
                if ($PSCmdlet.ShouldProcess($UninstallTarget, "Copy uninstall script")) {
                    try {
                        Copy-Item -Path $ARPAppUnInstallScript -Destination $UninstallTarget -Force | Out-Null
                        Write-Verbose "Success to copy uninstall script to $UninstallTarget"
                    } catch {Write-Warning "Failed to copy uninstall script. Error: $_"}
                }
            } else {Write-Verbose "Uninstall script already exists at target: $UninstallTarget"}
        }

        # Copy every other file from the wrapper's source folder into the app folder (excluding the wrapper, install/uninstall scripts and icon)
        if ($ARPAppIncludeFolder) {
            [string]$private:SourceFolder = $PSScriptRoot
            if ([string]::IsNullOrWhiteSpace($SourceFolder) -or -not (Test-Path -LiteralPath $SourceFolder -PathType Container)) {
                Write-Warning "ARPAppIncludeFolder set but source folder could not be resolved from `$PSScriptRoot. Skipping folder copy."
            } elseif ((Resolve-Path -LiteralPath $SourceFolder).Path -eq (Resolve-Path -LiteralPath $ARPAppFolder).Path) {
                Write-Verbose "ARPAppIncludeFolder source equals target ($SourceFolder); nothing to copy."
            } else {
                # Build exclude set of source leaf names that are deployed under standardized names (or are the wrapper itself)
                [System.Collections.Generic.HashSet[string]]$private:Excluded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                [void]$Excluded.Add((Split-Path -Path $PSCommandPath -Leaf))
                if ($ARPAppInstallScript)   { [void]$Excluded.Add((Split-Path -Path $ARPAppInstallScript   -Leaf)) }
                if ($ARPAppUnInstallScript) { [void]$Excluded.Add((Split-Path -Path $ARPAppUnInstallScript -Leaf)) }
                if ($ARPAppIconPath)            { [void]$Excluded.Add((Split-Path -Path $ARPAppIconPath            -Leaf)) }
                foreach ($private:srcFile in (Get-ChildItem -LiteralPath $SourceFolder -File -Force)) {
                    if ($Excluded.Contains($srcFile.Name)) { Write-Verbose "Skipping excluded source file: $($srcFile.Name)"; continue }
                    [string]$private:companionTarget = Join-Path -Path $ARPAppFolder -ChildPath $srcFile.Name
                    if (-not (Test-Path $companionTarget) -or $ARPAppForce) {
                        if ($PSCmdlet.ShouldProcess($companionTarget, "Copy file from source folder")) {
                            try {
                                Copy-Item -LiteralPath $srcFile.FullName -Destination $companionTarget -Force | Out-Null
                                Write-Verbose "Success to copy file to $companionTarget"
                            } catch {Write-Warning "Failed to copy file '$($srcFile.FullName)'. Error: $_"}
                        }
                    } else {Write-Verbose "File already exists at target: $companionTarget"}
                }
            }
        }

        # Create All-Users desktop and startmenu shortcuts to the configured start file (after companion-file copy so the target exists)
        if (-not [string]::IsNullOrWhiteSpace($ARPAppUserStartFile)) {
            [string]$private:StartFileLeaf   = Split-Path -Path $ARPAppUserStartFile -Leaf
            [string]$private:StartFileTarget = Join-Path -Path $ARPAppFolder -ChildPath $StartFileLeaf
            if (-not (Test-Path -LiteralPath $StartFileTarget -PathType Leaf)) {
                Write-Warning "ARPAppUserStartFile '$StartFileLeaf' not found in $ARPAppFolder. Place it in the wrapper's source folder and use -ARPAppIncludeFolder `$true. Skipping shortcut creation."
            } elseif ($ARPAppShortcutOnDesktop -or $ARPAppShortcutInStart) {
                [string]$private:DesktopLnk   = Join-Path -Path "$Env:Public\Desktop" -ChildPath "$ARPAppName.lnk"
                [string]$private:StartMenuDir = Join-Path -Path "$Env:ProgramData\Microsoft\Windows\Start Menu\Programs" -ChildPath $ARPAppPublisher
                [string]$private:StartMenuLnk = Join-Path -Path $StartMenuDir -ChildPath "$ARPAppName.lnk"
                [string]$private:LnkIcon      = if (Test-Path -LiteralPath $ARPFuncIconPath) { $ARPFuncIconPath } else { $StartFileTarget }
                try {
                    $private:WshShell = New-Object -ComObject WScript.Shell
                    if ($ARPAppShortcutOnDesktop -and (-not (Test-Path -LiteralPath $DesktopLnk) -or $ARPAppForce)) {
                        if ($PSCmdlet.ShouldProcess($DesktopLnk, "Create Desktop shortcut")) {
                            try {
                                $private:lnk = $WshShell.CreateShortcut($DesktopLnk)
                                $lnk.TargetPath        = $StartFileTarget
                                $lnk.WorkingDirectory  = $ARPAppFolder
                                $lnk.IconLocation      = $LnkIcon
                                $lnk.Description       = $ARPAppName
                                $lnk.Save()
                                Write-Verbose "Success to create Desktop shortcut: $DesktopLnk"
                            } catch {Write-Warning "Failed to create Desktop shortcut $DesktopLnk. Error: $_"}
                        }
                    } elseif ($ARPAppShortcutOnDesktop) {Write-Verbose "Desktop shortcut already exists: $DesktopLnk"}

                    if ($ARPAppShortcutInStart) {
                        if (-not (Test-Path -LiteralPath $StartMenuDir)) {
                            if ($PSCmdlet.ShouldProcess($StartMenuDir, "Create Start Menu folder")) {
                                try { New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null }
                                catch { Write-Warning "Failed to create Start Menu folder $StartMenuDir. Error: $_" }
                            }
                        }
                        if (-not (Test-Path -LiteralPath $StartMenuLnk) -or $ARPAppForce) {
                            if ($PSCmdlet.ShouldProcess($StartMenuLnk, "Create Start Menu shortcut")) {
                                try {
                                    $private:lnk = $WshShell.CreateShortcut($StartMenuLnk)
                                    $lnk.TargetPath        = $StartFileTarget
                                    $lnk.WorkingDirectory  = $ARPAppFolder
                                    $lnk.IconLocation      = $LnkIcon
                                    $lnk.Description       = $ARPAppName
                                    $lnk.Save()
                                    Write-Verbose "Success to create Start Menu shortcut: $StartMenuLnk"
                                } catch {Write-Warning "Failed to create Start Menu shortcut $StartMenuLnk. Error: $_"}
                            }
                        } else {Write-Verbose "Start Menu shortcut already exists: $StartMenuLnk"}
                    }
                } finally {
                    if ($WshShell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($WshShell) }
                }
            }
        }

        # Create and Save the uninstall batch file
        if ($ARPAppEnableUninstall -and (-not (Test-Path $ARPFuncUninstallBAT) -or $ARPAppForce)) {
            if ($PSCmdlet.ShouldProcess($ARPFuncUninstallBAT, "Create uninstall batch file")) {
                try {
                    Set-Content -Path $ARPFuncUninstallBAT -Value @($ARPFuncUninstallcmd1, $ARPFuncUninstallcmd2) -Encoding Ascii -Force
                    Write-Verbose "Success to create Batch file for uninstall to $ARPAppFolder"
                } catch {Write-Warning "Failed to create batch file for uninstall. Error: $_"}
            }
        } elseif (-not $ARPAppEnableUninstall) {Write-Verbose "Uninstall not enabled, skipping batch file creation"}
        else {Write-Verbose "Batch file for uninstall already exists in $ARPAppFolder"}

        # Create and Save the modify batch file
        if ($ARPAppEnableModify -and (-not (Test-Path $ARPFuncModifyBAT) -or $ARPAppForce)) {
            if ($PSCmdlet.ShouldProcess($ARPFuncModifyBAT, "Create modify (reinstall) batch file")) {
                try {
                    Set-Content -Path $ARPFuncModifyBAT -Value @($ARPFuncModifycmd1, $ARPFuncModifycmd2) -Encoding Ascii -Force
                    Write-Verbose "Success to create Batch file for modify to $ARPAppFolder"
                } catch {Write-Warning "Failed to create batch file for modify. Error: $_"}
            }
        } elseif (-not $ARPAppEnableModify) {Write-Verbose "Modify not enabled, skipping batch file creation"}
        else {Write-Verbose "Batch file for modify already exists in $ARPAppFolder"}

        # Create or Add Registry Keys
        Write-Verbose "Starting registry operations."
        try {
            if (-not (Get-PSDrive HKCR -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) {
                New-PSDrive -PSProvider Registry -Name HKCR -Root HKEY_CLASSES_ROOT | Out-Null
                $private:HKCRDrive = $true
                Write-Verbose "Created HKCR PSDrive."
            }

            # HKLM Registry Uninstall/Modify Entries
            if (-not (Test-Path $ARPFuncUninstallRegKey) -or $ARPAppForce) {
                if ($PSCmdlet.ShouldProcess($ARPFuncUninstallRegKey, "Create Registry Key")) {
                    try {
                        New-Item -Path $ARPFuncUninstallRegKey -Force | Out-Null
                        Write-Verbose "Success to create Registry Path $($ARPFuncUninstallRegKey)."
                    } catch {Write-warning "Failed to create Registry Path $($ARPFuncUninstallRegKey). Error: $_"}
                }
            }else {Write-Verbose "Registry Path already exists: $ARPFuncUninstallRegKey"}

            $RegistryProperties = @(
                @{ Name = "DisplayName";         Type = "String";    Value = $ARPAppName },
                @{ Name = "DisplayVersion";      Type = "String";    Value = $ARPAppVersion.ToString() },
                @{ Name = "Version";             Type = "DWord";     Value = ($ARPAppVersion.Major -shl 24) -bor ($ARPAppVersion.Minor -shl 16) -bor $ARPAppVersion.Build },
                @{ Name = "VersionMajor";        Type = "DWord";     Value = $ARPAppVersion.Major },
                @{ Name = "VersionMinor";        Type = "DWord";     Value = $ARPAppVersion.Minor },
                @{ Name = "Publisher";           Type = "String";    Value = $ARPAppPublisher },
                @{ Name = "DisplayIcon";         Type = "String";    Value = $ARPFuncIconPath },
                @{ Name = "Comments";            Type = "String";    Value = $ARPAppName },
                @{ Name = "InstallLocation";     Type = "String";    Value = $ARPAppFolder },
                @{ Name = "UninstallString";     Type = "String";    Value = $ARPFuncUninstallString },
                @{ Name = "QuietUninstallString";Type = "String";    Value = $ARPFuncUninstallString },
                @{ Name = "ModifyRegistryKey";   Type = "String";    Value = $ARPFuncUninstallRegKey },
                @{ Name = "ModifyString";        Type = "String";    Value = $ARPFuncModifyString },
                @{ Name = "ModifyPath";          Type = "String";    Value = $ARPFuncModifyString },
                @{ Name = "NoRemove";            Type = "DWord";     Value = 1 },# Default: Hide Remove button
                @{ Name = "NoModify";            Type = "DWord";     Value = 1 } # Default: Hide Modify button
            )
            # Adjust Uninstall/Remove if enabled
            if ($ARPAppEnableUninstall) {($RegistryProperties | Where-Object { $_.Name -eq "NoRemove" }).Value = 0}     
            # Adjust Modify/Repair if enabled       
            if ($ARPAppEnableModify) {($RegistryProperties | Where-Object { $_.Name -eq "NoModify" }).Value = 0}

            foreach ($Property in $RegistryProperties) {
                if ($PSCmdlet.ShouldProcess("$ARPFuncUninstallRegKey\$($Property.Name)", "Set Registry Value")) {
                    try {
                        New-ItemProperty -Path $ARPFuncUninstallRegKey -Name $Property.Name -PropertyType $Property.Type -Value $Property.Value -Force | Out-Null
                        Write-Verbose "Success to create/update Registry value '$($Property.Name)' under $($ARPFuncUninstallRegKey)."
                    } catch {Write-warning "Failed to create/update Registry value '$($Property.Name)' under $($ARPFuncUninstallRegKey). Error: $_"}
                }
            }

            # HKCR Registry Installer\Products Entries
            if (-not (Test-Path $ARPFuncProductsRegKey)) {
                if ($PSCmdlet.ShouldProcess($ARPFuncProductsRegKey, "Create Registry Key")) {
                    try {
                        New-Item -Path $ARPFuncProductsRegKey -Force | Out-Null
                        Write-Verbose "Success to create Registry Path $($ARPFuncProductsRegKey)."
                    } catch {Write-warning "Failed to create Registry Path $($ARPFuncProductsRegKey). Error: $_"}
                }
            } else {Write-Verbose "Registry Path already exists: $ARPFuncProductsRegKey"}

            $AdditionalRegistryProperties = @(
                @{ Name = "ProductName";       Type = "String";        Value = $ARPAppName },
                @{ Name = "Manufacturer";      Type = "String";        Value = $ARPAppPublisher },
                @{ Name = "ProductIcon";       Type = "String";        Value = $ARPFuncIconPath },
                @{ Name = "ProductVersion";    Type = "String";        Value = $ARPAppVersion.ToString() },
                @{ Name = "Version";           Type = "DWord";         Value = ($ARPAppVersion.Major -shl 24) -bor ($ARPAppVersion.Minor -shl 16) -bor $ARPAppVersion.Build },
                @{ Name = "VersionMajor";      Type = "DWord";         Value = $ARPAppVersion.Major },
                @{ Name = "VersionMinor";      Type = "DWord";         Value = $ARPAppVersion.Minor },
                @{ Name = "AdvertiseFlags";    Type = "DWord";         Value = 388 },
                @{ Name = "Assignment";        Type = "DWord";         Value = 1 },
                @{ Name = "AuthorizedLUAApp";  Type = "DWord";         Value = 0 },
                @{ Name = "Clients";           Type = "MultiString";   Value = @(":") },
                @{ Name = "DeploymentFlags";   Type = "DWord";         Value = 3 },
                @{ Name = "InstanceType";      Type = "DWord";         Value = 0 },
                @{ Name = "Language";          Type = "DWord";         Value = 1033 }
            )
            foreach ($Property in $AdditionalRegistryProperties) {
                if ($PSCmdlet.ShouldProcess("$ARPFuncProductsRegKey\$($Property.Name)", "Set Registry Value")) {
                    try {
                        New-ItemProperty -Path $ARPFuncProductsRegKey -Name $Property.Name -PropertyType $Property.Type -Value $Property.Value -Force | Out-Null
                        Write-Verbose "Success to create/update Registry value '$($Property.Name)' under $($ARPFuncProductsRegKey)."
                    } catch {Write-warning "Failed to create/update Registry value '$($Property.Name)' under $($ARPFuncProductsRegKey). Error: $_"}
                }
            }

            # HKCR Registry Installer\Products\...\Sourcelist Entries
            $SourceListPath = Join-Path -Path $ARPFuncProductsRegKey -ChildPath "Sourcelist"
            if (-not (Test-Path $SourceListPath)) {
                if ($PSCmdlet.ShouldProcess($SourceListPath, "Create Registry Key")) {
                    try {
                        New-Item -Path $SourceListPath -Force | Out-Null
                        Write-Verbose "Success to create Registry Path $SourceListPath."
                    } catch { Write-warning "Failed to create Registry Path $SourceListPath. Error: $_" }
                }
            } else {Write-Verbose "Registry Path already exists: $SourceListPath"}

            $SourcelistProperties = @(
                @{ Name = "LastUsedSource";    Type = "ExpandString";  Value = "n;1;$($ARPAppFolder)\" },
                @{ Name = "PackageName";       Type = "String";        Value = $DeployedWrapperName }
            )

            foreach ($Property in $SourcelistProperties) {
                if ($PSCmdlet.ShouldProcess("$SourceListPath\$($Property.Name)", "Set Registry Value")) {
                    try {
                        New-ItemProperty -Path $SourceListPath -Name $Property.Name -PropertyType $Property.Type -Value $Property.Value -Force | Out-Null
                        Write-Verbose "Success to create/update Registry value '$($Property.Name)' under $SourceListPath."
                    } catch {Write-warning "Failed to create/update Registry value '$($Property.Name)' under $SourceListPath. Error: $_"}
                }
            }
            
            # HKCR Registry Installer\Products\...\Sourcelist\Media Entries
            $MediaListPath = Join-Path -Path $SourceListPath -ChildPath "Media"
            if (-not (Test-Path $MediaListPath)) {
                if ($PSCmdlet.ShouldProcess($MediaListPath, "Create Registry Key")) {
                    try {
                        New-Item -Path $MediaListPath -Force | Out-Null
                        Write-Verbose "Success to create Registry Path $MediaListPath." 
                    } catch { Write-warning "Failed to create Registry Path $MediaListPath. Error: $_" }
                }
            } else {Write-Verbose "Registry Path already exists: $MediaListPath"}

            if ($PSCmdlet.ShouldProcess("$MediaListPath\1", "Set Registry Value")) {
                try {
                    New-ItemProperty -Path $MediaListPath -Name "1" -PropertyType "String" -Value ";" -Force | Out-Null
                    Write-Verbose "Success to create/update Registry value '1' under $MediaListPath."
                } catch {Write-warning "Failed to create/update Registry value '1' under $MediaListPath. Error: $_"}
            }

            # HKCR Registry Installer\Products\...\Sourcelist\Net Entries
            $NetListPath = Join-Path -Path $SourceListPath -ChildPath "Net"
            if (-not (Test-Path $NetListPath)) {
                if ($PSCmdlet.ShouldProcess($NetListPath, "Create Registry Key")) {
                    try {
                        New-Item -Path $NetListPath -Force | Out-Null
                        Write-Verbose "Success to create Registry Path $NetListPath." 
                    } catch { Write-warning "Failed to create Registry Path $NetListPath. Error: $_" }
                }
            } else {Write-Verbose "Registry Path already exists: $NetListPath"}

            if ($PSCmdlet.ShouldProcess("$NetListPath\1", "Set Registry Value")) {
                try {
                    New-ItemProperty -Path $NetListPath -Name "1" -PropertyType "ExpandString" -Value "$($ARPAppFolder)\" -Force | Out-Null
                    Write-Verbose "Success to create/update Registry value '1' under $NetListPath."
                } catch {Write-warning "Failed to create/update Registry value '1' under $NetListPath. Error: $_"}
            }

        } catch {Write-warning "An error occurred during registry operations section: $_"}
        # Signal caller to proceed with installer payload.
        $true
    }
    End {
        if ($private:HKCRDrive -and (Get-PSDrive HKCR -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) {
            try {
                Remove-PSDrive -Name HKCR
                Write-Verbose "Successfully removed HKCR PSDrive."
            } catch {Write-warning "Failed to remove HKCR PSDrive. Error: $_"}
        }
        Write-Verbose "Finished function Add-AddRemovePrograms."
    }
}
Function Remove-AddRemovePrograms {
        <#
    .SYNOPSIS
        Removes an application entry from Add Remove Programs (ARP) in Windows, including registry entries and associated files.
    .DESCRIPTION
        This function deletes the registry entries and files that were created to make a script or application appear in the Add Remove Programs list in Windows Settings.
        It is designed to clean up all traces of the application from ARP, including uninstall and modify options, as well as the application icon.
    .NOTES
        Author:  @MrTbone_se (T-bone Granheden)
        Version: 1.1.0
        
        Version History:
        1.0 - Initial version
        1.0.1 - Changed parameter names end improved error handling
        1.1.0 - Major refactor for better maintainability, added verbose logging, and improved error handling with try/catch blocks.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    Param(
        [Parameter(Mandatory, HelpMessage = 'Name of the application/script being removed (used also to determine icon name)')]
        [string]$ARPAppName,

        [Parameter(Mandatory, HelpMessage = 'GUID of the application used during installation')]
        [ValidatePattern('^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$')]
        [string]$ARPAppGuid,

        [Parameter(Mandatory, HelpMessage = 'Application folder path where components were installed')]
        [string]$ARPAppFolder,

        [Parameter(Mandatory = $false, HelpMessage = 'Publisher name used to locate Start Menu shortcut folder')]
        [string]$ARPAppPublisher = ""
    )
    Begin {
        $ErrorActionPreference = 'Stop'
        Write-Verbose "Start Function Remove-AddRemovePrograms"
        $private:HKCRDrive = $false
    }
    Process {
        # Convert GUID to ProductID (it needs to be in reversed order)
        [string]$private:parts = $ARPAppGuid -replace '[{}]', ''
        [array]$private:seg    = $parts.Split('-')
        [char[]]$private:tail  = $seg[4].ToCharArray()
        $ARPFuncProductID = $seg[0] + $seg[1] + $seg[2] + $seg[3] + (-join ($tail[1],$tail[0],$tail[3],$tail[2],$tail[5],$tail[4],$tail[7],$tail[6],$tail[9],$tail[8],$tail[11],$tail[10]))
        Write-Verbose "Derived ProductID for removal: $ARPFuncProductID"

        # Standardized deployed paths (must match the one used in Add-AddRemovePrograms)
        $private:DeployedWrapperPath     = Join-Path -Path $ARPAppFolder -ChildPath 'App-Wrapper.ps1'
        $private:DeployedInstallerPath   = Join-Path -Path $ARPAppFolder -ChildPath "installer-$ARPAppGuid.ps1"
        $private:DeployedUninstallerPath = Join-Path -Path $ARPAppFolder -ChildPath "uninstaller-$ARPAppGuid.ps1"

        # Registry / icon / batch paths
        $ARPFuncIconPath        = Join-Path -Path $ARPAppFolder -ChildPath "$($ARPAppName -replace '\s', '').ico"
        $ARPFuncUninstallRegKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ARPAppGuid"
        $ARPFuncProductsRegKey  = "HKCR:\Installer\Products\$ARPFuncProductID"
        $ARPFuncUninstallBAT    = Join-Path -Path $ARPAppFolder -ChildPath "uninstall-$ARPAppGuid.bat"
        $ARPFuncModifyBAT       = Join-Path -Path $ARPAppFolder -ChildPath "reinstall-$ARPAppGuid.bat"

        # Remove Registry Keys
        Write-Verbose "Starting registry key removal."
        try {
            if (-not (Get-PSDrive HKCR -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) {
                New-PSDrive -PSProvider Registry -Name HKCR -Root HKEY_CLASSES_ROOT | Out-Null
                $private:HKCRDrive = $true
                Write-Verbose "Created HKCR PSDrive."
            }

            # Remove HKLM Uninstall Key
            if (Test-Path $ARPFuncUninstallRegKey) {
                if ($PSCmdlet.ShouldProcess($ARPFuncUninstallRegKey, "Remove Registry Key")) {
                    try {
                        Remove-Item -Path $ARPFuncUninstallRegKey -Recurse -Force
                        Write-Verbose "Success to remove registry key: $ARPFuncUninstallRegKey"
                    } catch {Write-Warning "Failed to remove registry key $ARPFuncUninstallRegKey. Error: $_"}
                }
            } else {Write-Verbose "Registry key not found: $ARPFuncUninstallRegKey"}

            # Remove HKCR Installer Products Key
            if (Test-Path $ARPFuncProductsRegKey) {
                if ($PSCmdlet.ShouldProcess($ARPFuncProductsRegKey, "Remove Registry Key")) {
                    try {
                        Remove-Item -Path $ARPFuncProductsRegKey -Recurse -Force
                        Write-Verbose "Success to remove registry key: $ARPFuncProductsRegKey"
                    } catch {Write-Warning "Failed to remove registry key $ARPFuncProductsRegKey. Error: $_"}
                }
            } else {Write-Verbose "Registry key not found: $ARPFuncProductsRegKey"}
        } catch {Write-Warning "An error occurred during registry key removal section: $_"}

        # Remove Files (script, icon, uninstall/reinstall batches, and any companion files staged into $ARPAppFolder)
        Write-Verbose "Starting file removal in $ARPAppFolder."
        $FilesToDelete = [System.Collections.Generic.List[string]]::new()
        $FilesToDelete.Add($ARPFuncIconPath)
        $FilesToDelete.Add($ARPFuncUninstallBAT)
        $FilesToDelete.Add($ARPFuncModifyBAT)
        $FilesToDelete.Add($DeployedWrapperPath)
        $FilesToDelete.Add($DeployedInstallerPath)
        $FilesToDelete.Add($DeployedUninstallerPath)
        # All-Users shortcuts (created in Add-AddRemovePrograms when ARPAppUserStartFile was configured). Always attempt deletion
        $FilesToDelete.Add((Join-Path -Path "$Env:Public\Desktop" -ChildPath "$ARPAppName.lnk"))
        if (-not [string]::IsNullOrWhiteSpace($ARPAppPublisher)) {
            $FilesToDelete.Add((Join-Path -Path "$Env:ProgramData\Microsoft\Windows\Start Menu\Programs\$ARPAppPublisher" -ChildPath "$ARPAppName.lnk"))
        }
        # Any remaining files staged into $ARPAppFolder
        if (Test-Path -LiteralPath $ARPAppFolder -PathType Container) {
            foreach ($private:extraFile in (Get-ChildItem -LiteralPath $ARPAppFolder -File -Force -ErrorAction SilentlyContinue)) {
                $FilesToDelete.Add($extraFile.FullName)
            }
        }

        foreach ($FileItem in $FilesToDelete) {
            if (Test-Path $FileItem) {
                if ($PSCmdlet.ShouldProcess($FileItem, "Remove File")) {
                    try {
                        Remove-Item -Path $FileItem -Force
                        Write-Verbose "Success to remove file: $FileItem"
                    } catch {Write-Warning "Failed to remove file $FileItem. Error: $_"}
                }
            } else {Write-Verbose "File not found: $FileItem"}
        }

        # Remove the publisher Start Menu folder (if empty)
        if (-not [string]::IsNullOrWhiteSpace($ARPAppPublisher)) {
            [string]$private:StartMenuPubDir = Join-Path -Path "$Env:ProgramData\Microsoft\Windows\Start Menu\Programs" -ChildPath $ARPAppPublisher
            if (Test-Path -LiteralPath $StartMenuPubDir) {
                if (@(Get-ChildItem -LiteralPath $StartMenuPubDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                    try {
                        [System.IO.Directory]::Delete($StartMenuPubDir, $false)
                        Write-Verbose "Success to remove empty Start Menu publisher folder: $StartMenuPubDir"
                    } catch { Write-Warning "Failed to remove Start Menu publisher folder $StartMenuPubDir. Error: $_" }
                } else { Write-Verbose "Start Menu publisher folder not empty, skipping: $StartMenuPubDir" }
            }
        }

        # Remove Application Folder (if empty), then Publisher Folder (if empty) and so on until a non empty foler is reached, or a protected root
        [string[]]$private:ProtectedRoots = @(
            $Env:ProgramFiles,
            ${Env:ProgramFiles(x86)},
            $Env:ProgramData,
            $Env:SystemDrive,
            $Env:SystemRoot,
            $Env:windir
        ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

        [string]$private:FolderToCheck = $ARPAppFolder
        try { Set-Location -LiteralPath $Env:SystemRoot -ErrorAction Stop } catch { Write-Verbose "Could not Set-Location to $Env:SystemRoot: $_" }
        for ($private:depth = 0; $depth -lt 2 -and $FolderToCheck; $depth++) {
            if (-not (Test-Path $FolderToCheck)) {
                Write-Verbose "Folder not found: $FolderToCheck"
                break
            }
            [string]$private:Trimmed = $FolderToCheck.TrimEnd('\')
            if ($ProtectedRoots -contains $Trimmed) {
                Write-Verbose "Reached protected root, stopping cleanup: $FolderToCheck"
                break
            }
            if (@(Get-ChildItem -Path $FolderToCheck -Force -ErrorAction SilentlyContinue).Count -ne 0) {
                Write-Verbose "Folder not empty, skipping removal: $FolderToCheck"
                break
            }
            if ($PSCmdlet.ShouldProcess($FolderToCheck, "Remove empty directory")) {
                try {
                    [System.IO.Directory]::Delete($FolderToCheck, $false)
                    Write-Verbose "Success to remove empty folder: $FolderToCheck"
                } catch {
                    Write-Warning "Failed to remove folder $FolderToCheck. Error: $_"
                    break
                }
            }
            $FolderToCheck = Split-Path -Path $FolderToCheck -Parent
        }
    }
    End {
        if ($private:HKCRDrive -and (Get-PSDrive HKCR -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) {
            try {
                Remove-PSDrive -Name HKCR
                Write-Verbose "Successfully removed HKCR PSDrive."
            } catch {Write-Warning "Failed to remove HKCR PSDrive. Error: $_"}
        }
        Write-Verbose "Finished function Remove-AddRemovePrograms."
    }
}
#endregion

#region ---------------------------------------------------[[Script Execution]------------------------------------------------------
# Start T-Bone custom logging (can be removed if you don't want to use T-Bone logging)
Invoke-TboneLog -LogMode Start -Logname $LogName -LogToGUI $LogToGUI -LogToEventlog $LogToEventlog -LogEventIds $LogEventIds -LogToDisk $LogToDisk -LogPath $LogToDiskPath -LogToHost $LogToHost

# Preflight: detect execution context + validate requirements (identity / architecture / mode), optional x86->x64 relaunch.
$CTX = Get-ExecutionContext -CTXReqIdentity $CTXReqIdentity -CTXReqArchitecture $CTXReqArchitecture -CTXAutoRelaunchToX64:$CTXAutoRelaunchToX64 -CTXReqPSVersion $CTXReqPSVersion -CTXReqOSBuild $CTXReqOSBuild -CTXAbortIfPendingReboot:$CTXAbortIfPendingReboot -CTXForwardParameters $PSBoundParameters
if (-not $CTX) { Invoke-TboneLog Stop; return }

# Derived flags + script-specific gate: elevation is required unless we're already installed AND doing a plain Install.
[bool]$IsInstalled = $CTX.CTXPath     -in 'ProgramFiles','ProgramFilesX86','ProgramData'
[bool]$IsElevated  = $CTX.CTXIdentity -in 'System','Admin'

# To create device tunnel or all users tunnel the script needs to run as System. To create user tunnel the script needs to run in user context as system or admin
if (($AoVDeviceTunnel -or $AoVAllUserProfile) -and ($InstallType -eq "install" -or $InstallType -eq "reinstall")){
        if ($CTX.CTXIdentity -eq 'System'){Write-Verbose "Success to verify credentials, The script is running as admin with the SYSTEM credentials"}
        else { throw "Failed to verify credentials, The script must run as System" }}
    else{
        if ($CTX.CTXIdentity -eq "System"){Write-Verbose "Success to verify credentials, The script is running as admin with the SYSTEM credentials"}
        elseif ($CTX.CTXIdentity -eq "Admin"){Write-Verbose "Success to verify credentials, The script is running as admin with the current user credentials"}
        else { throw "Script must run as admin with the logged on user credentials, or run as System" }
        }

# Check and add scripts as wrapped Un/installer scripts if provided, otherwise use the inline scripts defined in the function bodies 
$WrappedInstallerScript   = $InlineInstallerScript
if (-not [string]::IsNullOrWhiteSpace($ARPAppInstallScript)) {
    if (Test-Path -LiteralPath $ARPAppInstallScript -PathType Leaf) {
        try {
            $WrappedInstallerScript = [scriptblock]::Create((Get-Content -LiteralPath $ARPAppInstallScript -Raw -ErrorAction Stop))
            Write-Verbose "Loaded installer script from: $ARPAppInstallScript"
        } catch {Write-Warning "Failed to load installer script from '$ARPAppInstallScript': $($_.Exception.Message). Using inline installer."}
    } else {Write-Warning "Installer script file not found at '$ARPAppInstallScript'. Using inline installer."}
} else {Write-Verbose "No ARPAppInstallScript provided. Using inline installer."}
$WrappedUnInstallerScript = $InlineUnInstallerScript
if (-not [string]::IsNullOrWhiteSpace($ARPAppUnInstallScript)) {
    if (Test-Path -LiteralPath $ARPAppUnInstallScript -PathType Leaf) {
        try {
            $WrappedUnInstallerScript = [scriptblock]::Create((Get-Content -LiteralPath $ARPAppUnInstallScript -Raw -ErrorAction Stop))
            Write-Verbose "Loaded uninstaller script from: $ARPAppUnInstallScript"
        } catch {Write-Warning "Failed to load uninstaller script from '$ARPAppUnInstallScript': $($_.Exception.Message). Using inline uninstaller."}
    } else {Write-Warning "Uninstaller script file not found at '$ARPAppUnInstallScript'. Using inline uninstaller."}
} else {Write-Verbose "No ARPAppUnInstallScript provided. Using inline uninstaller."}

# Dispatch by CTXPath + InstallType Logic:
#   Installed + Install     : Run wrapped installer only (already staged)
#   Staging   + Install     : Run wrapped installer -> Stage files -> Register ARP (version gate applies to staging/ARP only)
#   Installed + ReInstall   : Run wrapped installer -> Re-stage files -> Re-register ARP
#   Staging   + ReInstall   : Run from installed path if exists -> Run wrapped installer -> Stage files -> Register ARP
#   Installed + UnInstall   : Run wrapped uninstaller -> Remove ARP -> Delete app folder + Companion files
#   Staging   + UnInstall   : Run from installed path if exists -> Run wrapped uninstaller -> Remove ARP -> Delete app folder + Companion files

try {
    switch ($InstallType) {
        'Install' {
            if ($IsInstalled) {
                Write-Verbose "Running Installmode from installed location ($($CTX.CTXPath)) - running payload only"
                if ($PSCmdlet.ShouldProcess('Installer payload', 'Run installer script')) { & $WrappedInstallerScript }; break
            }
            Write-Verbose "Running Installmode from staging ($($CTX.CTXPath)) - run installer, then stage files and register ARP"
            if ($PSCmdlet.ShouldProcess('Installer payload', 'Run installer script')) { & $WrappedInstallerScript }
            $null = Add-AddRemovePrograms -ARPAppName $ARPAppName -ARPAppVersion $ARPAppVersion -ARPAppGuid $ARPAppGuid -ARPAppPublisher $ARPAppPublisher -ARPAppFolder $ARPAppFolder -ARPAppEnableUninstall $ARPAppEnableUninstall `
                -ARPAppEnableModify $ARPAppEnableModify -ARPAppIcon $ARPAppIcon -ARPAppIconPath $ARPAppIconPath -ARPAppInstallScript $ARPAppInstallScript -ARPAppUnInstallScript $ARPAppUnInstallScript -ARPAppIncludeFolder $ARPAppIncludeFolder `
                -ARPAppUserStartFile $ARPAppUserStartFile -ARPAppShortcutOnDesktop $ARPAppShortcutOnDesktop -ARPAppShortcutInStart $ARPAppShortcutInStart -ARPAppForce $ARPAppForce
        }
        'ReInstall' {
            # No staging-path redirect for ReInstall: run the installer directly from wherever the script was launched.
            # When triggered via Add/Remove Programs, the reinstall.bat already calls the installed wrapper, so $IsInstalled will be true.
            Write-Verbose "Running ReInstallmode from $($CTX.CTXPath) (installed=$IsInstalled) - running installer then re-staging files and re-registering ARP."
            if ($PSCmdlet.ShouldProcess('Installer payload', 'Run installer script')) { & $WrappedInstallerScript }
            $null = Add-AddRemovePrograms -ARPAppName $ARPAppName -ARPAppVersion $ARPAppVersion -ARPAppGuid $ARPAppGuid -ARPAppPublisher $ARPAppPublisher -ARPAppFolder $ARPAppFolder -ARPAppEnableUninstall $ARPAppEnableUninstall `
                -ARPAppEnableModify $ARPAppEnableModify -ARPAppIcon $ARPAppIcon -ARPAppIconPath $ARPAppIconPath -ARPAppInstallScript $ARPAppInstallScript -ARPAppUnInstallScript $ARPAppUnInstallScript -ARPAppIncludeFolder $ARPAppIncludeFolder `
                -ARPAppUserStartFile $ARPAppUserStartFile -ARPAppShortcutOnDesktop $ARPAppShortcutOnDesktop -ARPAppShortcutInStart $ARPAppShortcutInStart -ARPAppForce $true
        }
        'UnInstall' {
            if (-not $IsInstalled) {
                write-verbose "Running UnInstallmode from staging location ($($CTX.CTXPath)) - Redirecting to installed app folder for UnInstall execution."
                [string]$private:UninstallBatPath = Join-Path -Path $ARPAppFolder -ChildPath "uninstall-$ARPAppGuid.bat"
                if (Test-Path -LiteralPath $UninstallBatPath) {
                    Write-Verbose "Redirecting UnInstall from '$($CTX.CTXPath)' to installed batch: $UninstallBatPath"
                    if ($PSCmdlet.ShouldProcess($UninstallBatPath, 'Run installed batch (UnInstall)')) { & $UninstallBatPath }
                    break
                }
                Write-Verbose "No redirect batch found at $UninstallBatPath; continuing in-process UnInstall."
            }
            Write-Verbose "Running UnInstallmode from installed location ($($CTX.CTXPath)) - Running uninstaller and removing ARP."
            if ($PSCmdlet.ShouldProcess('Uninstaller payload', 'Run uninstaller script')) { & $WrappedUnInstallerScript }
            Remove-AddRemovePrograms -ARPAppName $ARPAppName -ARPAppGuid $ARPAppGuid -ARPAppFolder $ARPAppFolder -ARPAppPublisher $ARPAppPublisher
        }
    }
    write-Verbose "Completed InstallType '$InstallType' execution."
}
finally {
    $ErrorActionPreference = $script:OriginalErrorActionPreference
    $VerbosePreference     = $script:OriginalVerbosePreference
    $WhatIfPreference      = $script:OriginalWhatIfPreference
    Invoke-TboneLog Stop
}
#endregion