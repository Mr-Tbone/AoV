<#PSScriptInfo
.SYNOPSIS
    Script for Always On VPN

.DESCRIPTION
    This script will configure Always On VPN connection for the Device 
    The script uses CSP over WMI to configure the VPN profile
    The script needs to be run in the targeted end Device context i.e "nt authority\system"
        
.EXAMPLE
   .\AoV-Device-Tunnel.ps1
    Will configure Always On VPN configuration for the Device with settings in the modifyable region. 

   .\AoV-Device-Tunnel.ps1 -InstallType ReInstall
    Will reconfigure Always On VPN configuration for the Device with settings in the modifyable region. 

   .\AoV-Device-Tunnel.ps1 -InstallType UnInstall
    Will remove Always On VPN configuration for the Device with settings in the modifyable region.

.NOTES
    Written by Mr-Tbone (Tbone Granheden) Coligo AB
    torbjorn.granheden@coligo.se

.VERSION
    1.7

.RELEASENOTES
    1.0 2022-02-18 Initial Build
    1.1 2022-07-17 Solved a problem with uninstall device tunnel from Add Remove Programs
    1.2 2022-07-18 Solved Windows 11 problems with CSP over WMI. No blank DNS server list allowed
    1.3 2022-08-15 Fixed Version check
    1.4 2023-01-09 Fixed new DeviceTunnelInfo regkey cleanup
    1.5 2023-03-16 Unified script for both Device and User Tunnel and some Bug Fixes. Removed minimum win build due to not needed
    1.6 2023-03-17 Fixed some bugs
    1.7 2023-11-28 Added modify button in Add Remove Programs to repair/reinstall the VPN connection

.AUTHOR
    Tbone Granheden 
    @MrTbone_se

.COMPANYNAME 
    Coligo AB

.GUID 
    65FD0F16-91BE-4346-BDA4-24BAAA2344E3

.COPYRIGHT
    Feel free to use this, But would be grateful if My name is mentioned in Notes 

.CHANGELOG
    1.0.2202.1 - Initial Version
    1.1.2207.1 - Solved a problem with uninstall device tunnel from Add Remove Programs
    1.2.2207.2 - Solved Windows 11 problems with CSP over WMI. No blank DNS server list allowed
    1.3.2208.1 - Fixed Version Check
    1.4.2301.1 - Fixed new DeviceTunnelInfo regkey cleanup      
    1.4.2301.2 - Fixed bug in DeviceTunnelInfo regkey cleanup
    1.5.2303.1 - Unified script for both Device and User Tunnel and a lot of  bug Fixes and cleanups       
    1.6.2303.1 - Fixed some bugs
    1.7.2311.1 - Added modify button in Add Remove Programs to repair/reinstall the VPN connection
#>

#region ---------------------------------------------------[Set script requirements]-----------------------------------------------
#
#Requires -Version 4.0
#Requires -RunAsAdministrator
#endregion

#region ---------------------------------------------------[Script Parameters]-----------------------------------------------
Param(

    [Parameter(HelpMessage = 'Enter Install, ReInstall or UnInstall.')]    
    [validateset("Install", "ReInstall", "UnInstall")][string]$InstallType = "Install"
)
#endregion

#region ---------------------------------------------------[Modifiable Parameters and defaults]------------------------------------
# Customizations
$Company = "Coligo"    #Used in VPN ProfileName and registry keys

#Version info
[version]$ConfigVersion   = "1.6.2303.1"  #Increment when changing config, stored in registry to check if new config is needed. syntax: 1.1.YYMM.Version (1.1.2001.1)
$AddRemoveProgramEnabled  = $True         #$true register an App in Add Remove Programs for versioning and uninstall, $false skip registration in Add Remove Programs
$AddRemoveProgramUninstall= $True         #$true enables an uninstall button in Add Remove Programs for the posibility to uninstall the VPN connection, $false hide the button
$AddRemoveProgramModify   = $True         #$true enables an modify button in Add Remove Programs for the posibility to repair/reinstall the VPN connection, $false hide the button

#Log settings
$Global:GuiLogEnabled   = $False       #$true = GUI lologging for test of script in manual execution
$Global:EventlogEnabled = $True        #$True = Create an event log in Event viewer Application log
$Global:FileLogEnabled  = $False       #$True = Create a file log for troubleshooting in specified path
$Global:FileLogPath     = "$env:TEMP"  #Path to the file log
$Global:FileLogPurge    = $True        #$True = Purge old file logs to cleanup after previous executions
$Global:FileLogHistory  = 10           #Purges but keep this number of file logs for history

#Always on VPN PBK settings
$RasNicMetric       = "3"   #Ras NIC ipv4 interface priority metric for a custom better DNS and nic priority. (0 = Default, 3 = Recommended)
$RasNicMetricIPv6   = "3"   #Ras NIC ipv4 interface priority metric for a custom better DNS and nic priority. (0 = Default, 3 = Recommended)
$VpnStrategy        = "7"   #Ras default protocol: 5 = Only SSTP,6 = SSTP first,7 = Only IKEv2,8 = IKEv2 first,14 = IKEv2 first then SSTP (6 = Default, 8 = Recommended)
$DisableMobility    = "0"   #VPN reconnect after network outage: 0 = Enabled, 1= Disabled (0 = Default, 0 = Recommended) 
$NetworkOutageTime  = "0"   #VPN reconnect timeout in seconds: '60', '120', '300', '600', '1200', '1800' (0 = default (1800 = 30 min), 0 = recommended)
$UseRasCredentials  = "1"   #VPN reuses RAS credentials to connect to internal resourses with SSO (1 = Default, 1 = Recommended)
   
# Always on VPN connection XML settings
$AllUserProfile = $False     #Option to create the Always On VPN user tunnel profile in the all users profile 
$Oldprofilename = ''        #Optional, Cleanup of old connections with another name for example: "AoV-Usertunnel*". To delete none, enter: '' 
$ProfileName    = "$Company AoV Device Tunnel" #Name of the VPN profile to create
$VPNProfileXML     = '
<VPNProfile>
    <DeviceTunnel>true</DeviceTunnel>                                       <!--true = Create Device Tunnel, false = Create user tunnel (default)-->
    <AlwaysOn>true</AlwaysOn>                                               <!--true = Tunnel is Always on, false = Tunnel is not Always On (Default) -->
    <RememberCredentials>true</RememberCredentials>                         <!--true = Credentials are cached whenever possible, false = Do not cache credentials (default) -->
    <TrustedNetworkDetection>coligo.se</TrustedNetworkDetection>            <!--VPN does not connect when connected to this trusted network, multiple networks can be seperated by comma "," Not Recommended on devicetunnel if using both User and Device tunnel-->
    <DnsSuffix>coligo.se</DnsSuffix>                                        <!--The DNS suffix for the VPN NIC-->
    <RegisterDNS>true</RegisterDNS>                                         <!--true = Register in DNS, false = Do not register in DNS (default)-->
    <NativeProfile>    
        <Servers>vpn.coligo.se</Servers>                                    <!--VPN Server Address-->
        <RoutingPolicyType>SplitTunnel</RoutingPolicyType>                  <!--SplitTunnel or ForcedTunnel-->
        <NativeProtocolType>IKEv2</NativeProtocolType>                      <!--VPN Connection Protocol, PPTP,L2TP,SSTP,IKEv2,Automatic,ProtocolList-->
        <DisableClassBasedDefaultRoute>true</DisableClassBasedDefaultRoute> <!--VPN use Custom Routes if set to true-->
<!--VPN Authentication Method-->
        <Authentication>
            <MachineMethod>Certificate</MachineMethod>
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
<!--New settings for Windows 11 Insider-->
    <DisableIKEv2Fragmentation>false</DisableIKEv2Fragmentation>                <!--true = IKEv2 Fragmentation will not be used, false = IKEv2 Fragmentation will be used (Default)-->
    <DataEncryption>Optional</DataEncryption>                                   <!--Set encryptionlevel to None, Optional, Require(default), Max-->
    <IPv4InterfaceMetric>3</IPv4InterfaceMetric>                                <!--ipv4 interface priority metric for a custom better DNS and nic priority. (0 = Default, 3 = Recommended)-->
    <IPv6InterfaceMetric>3</IPv6InterfaceMetric>                                <!--ipv6 interface priority metric for a custom better DNS and nic priority. (0 = Default, 3 = Recommended)-->
    <NetworkOutageTime>0</NetworkOutageTime>                                    <!--VPN reconnect timeout in seconds: 60, 120, 300, 600, 1200, 1800 (0 = default (1800 = 30 min), 0 = recommended)-->
    <UseRasCredentials>false</UseRasCredentials>                                <!--VPN reuse RAS credentials to connect to internal resourses with SSO (1 = Default, 1 = Recommended)-->
    <PrivateNetwork>true</PrivateNetwork>                                       <!--false = VPN connection is public, true = VPN connection is private (default)-->
</VPNProfile>'

#endregion

#region ---------------------------------------------------[Set global script settings]--------------------------------------------
Set-StrictMode -Version Latest
#endregion

#region ---------------------------------------------------[Static Variables]------------------------------------------------------
#Log File Info
$startTime          = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$Global:ScriptName  = ([io.fileinfo]$MyInvocation.MyCommand.Definition).BaseName
$Global:ScriptPath  =  $MyInvocation.MyCommand.Path
$logFile            = $Global:FileLogPath + "\" + $Global:ScriptName + "-" + $startTime + ".log"
$Global:Eventlog    = @()
#WMI Classes
$nodeCSPURI         = "./Vendor/MSFT/VPNv2"     #https://learn.microsoft.com/windows/client-management/mdm/vpnv2-csp?WT.mc_id=EM-MVP-5004264
$namespaceName      = "root\cimv2\mdm\dmmap"
$className          = "MDM_VPNv2_01"
$deleteInstances    = $null
#XML cleanup
$ProfileNameEscaped     = $Profilename -replace ' ', '%20'
$OldprofilenameEscaped  = $Oldprofilename -replace ' ', '%20'
[XML]$XMLVPNProfile = $VPNProfileXML
$VPNProfileXML = $VPNProfileXML -replace '<', '&lt;'
$VPNProfileXML = $VPNProfileXML -replace '>', '&gt;'
$VPNProfileXML = $VPNProfileXML -replace '"', '&quot;'
#Service related variables
$ServiceName        = "dmwappushservice"
$serviceTimeout     = 10
$serviceRetry       = 3
#Apps and version settings
$AppPublisher   = $company                                  # The publisher of the application in Add Remove Programs
$AppFolder      = "$Env:Programfiles\$company"              # The folder for uninstallation scripts
if ($XMLVPNProfile.ChildNodes.devicetunnel -eq "true"){$AppGuid = "{65FD0F16-91BE-4346-BDA4-24BAAA2344E3}"}  # Application GUID for Device Tunnel used in Add Remove Programs
else {$AppGuid          = "{65FD0F16-91BE-4346-BDA4-24BAAA2344E2}"}                                          # Application GUID for User Tunnel used in Add Remove Programs
$MDMPath                = "HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked"
$NetworkProfilesPath    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles\'
$DeviceTunnelInfoPath   = 'HKLM:\SYSTEM\CurrentControlSet\Services\RasMan\DeviceTunnel\'
$UserTunnelInfoPath     = 'HKLM:\SYSTEM\CurrentControlSet\Services\RasMan\config'
$AppKey                 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$AppGuid"
# Imported icon for Add remove Programs in Base64 format 
$AppIcon = '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'
#endregion

#region ---------------------------------------------------[Import Modules and Extensions]-----------------------------------------
#endregion

#region ---------------------------------------------------[Functions]------------------------------------------------------------

Function LogWrite {
    Param(
        $logfile = "$logfile",
        [validateset("Info", "Warning", "Error","Start","End")]$type = "Info",
        [string]$Logstring
    )
    Begin { }
    Process {
            if ($type -eq "Info") {$foreGroundColor = "Green"}
            elseif ($type -eq "Warning") {$foreGroundColor = "Cyan"}
            elseif ($type -eq "Error") {$foreGroundColor = "Red";$EventType="Error";$EventID=999}
            elseif ($type -eq "Start") {$foreGroundColor = "Green"}
            elseif ($type -eq "End") {$foreGroundColor = "Green";$EventType="Information";$EventID=0}
            $logmessage = "$(Get-Date -Format 'yyyy-MM-dd'),$(Get-Date -format 'HH:mm:ss'),$type,$logstring"
        if ($Global:GUILogEnabled) {
            Write-Host $logmessage -ForegroundColor $foreGroundColor
            }
        If ($Global:FileLogEnabled) {
            if(!(Test-Path $Global:FileLogPath )){
                Try {New-Item -ItemType Directory -Path $Global:FileLogPath  -Force}
                Catch{Write-Host $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $_ -ForegroundColor Red;Break}
                }
            Try {Add-content $Logfile -value $logmessage}
            Catch{Write-Host $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $_ -ForegroundColor Red;Break}
            if ($Global:FileLogPurge){
                Try {Get-ChildItem -Path $Global:FileLogPath  | Where{ $_.name -like "$Global:ScriptName*"} | sort CreationTime -Descending| select -Skip $Global:FileLogHistory |remove-item -force}
                catch {Write-Host $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $_ -ForegroundColor Cyan}
                $Global:FileLogPurge = $false
                }            
            }
        if ($Global:EventLogEnabled){
            $Global:eventlog += $logmessage
            $eventlog = ($Global:eventlog |out-string)
            if ($type -eq "Error" -or $type -eq "End"){
                if(![System.Diagnostics.Eventlog]::SourceExists($Global:scriptName)){
                    Try {New-EventLog -LogName Application -Source "$Global:scriptName"}
                    Catch{Write-Host $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $_ -ForegroundColor Red;Break}
                    }
                Try {Write-EventLog -LogName Application -Source $Global:scriptName -EntryType $EventType -EventID $EventId -Message $eventlog}
                Catch{Write-Host $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $_ -ForegroundColor Red;Break}
                }
            }
        if ($type -eq "Error"){
            if($Global:GUILogEnabled) {Exit(1)}
            else{[System.Environment]::Exit(1)}
            }
        if ($type -eq "End"){
            if($Global:GUILogEnabled) {Exit(0)}
            else{[System.Environment]::Exit(0)}
            }
        }
    End { }
}
function enable-Service {
    param(
    [String] $serviceName,
    [Int32] $timeoutSeconds,
    [Int32] $maxTries
    )
    $service = Get-Service $serviceName
    if ( -not $service ) {logwrite -Logstring "Failed to find the service $($servicename), cannot start it" -type Error}

    if ( $service.Status -eq [ServiceProcess.ServiceControllerStatus]::Running ) {
        logwrite -Logstring "Success to verify the service $($servicename), it is already running" -type Info
        return}

    if ( $service.Starttype -eq "Disabled"){
        try {Set-Service $service.Name -StartupType Automatic
        logwrite -Logstring "Success to set the service $($servicename) to start automatic" -type Info}
        catch {logwrite -Logstring "Failed to set the service $($servicename) to start automatic with error: $_" -type Warning}
        }
        $timeSpan = New-Object Timespan 0,0,$timeoutSeconds
        for ($i=0; $i -lt $maxTries; $i++) {
            try {
                $service.Start()
                $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, $timeSpan)
                logwrite -Logstring "Success to start the service $($servicename)" -type Info
                return
            }
            catch [Management.Automation.MethodInvocationException],[ServiceProcess.TimeoutException] {
                if ($i -lt $maxTries - 1) {
                    logwrite -Logstring "Failed to start the service $($servicename) with warning: $_" -type Warning
                    Start-Sleep -Seconds $timeoutSeconds
                }
                else{logwrite -Logstring "Failed to start the service $($servicename) with error: $_" -type Error}
            }
        }
    logwrite -Logstring "Failed to start the service $($servicename) after $maxTries attempts" -type Error
    return
}

Function Add-AddRemovePrograms($DisplayName, $Version, $guid, $Publisher, $icon, $AppFolder, $UnInstall, $Modify){  

    logwrite -Logstring "Success to start adding entry in Add Remove Programs for Always On VPN" -type Info
    $IconName = $displayname -replace '\s',''
    $ProductID = $guid -replace '[{}]',""
    $ProductID = $productID.Split("-")
    $id0 = $ProductID[0][-1..-$ProductID[0].Length] -join ''
    $id1 = $ProductID[1][-1..-$ProductID[1].Length] -join ''
    $id2 = $ProductID[2][-1..-$ProductID[2].Length] -join ''
    $id3 = $ProductID[3][-1..-$ProductID[3].Length] -join ''
    $id4 = $ProductID[4].TocharArray()
    $id4 = $id4[1]+$id4[0]+$id4[3]+$id4[2]+$id4[5]+$id4[4]+$id4[7]+$id4[6]+$id4[9]+$id4[8]+$id4[11]+$id4[10]
    $ProductID = $id0+$id1+$id2+$id3+$id4
    $AddRemKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
    $ProductsKey = "HKCR:\Installer\Products\$ProductID"
    $UninstallString = "CMD /C START cmd /c "+'"'+"$appfolder\uninstall-$guid.bat"+'"'
    $UninstallBAT = "$appfolder\uninstall-$guid.bat"
    $Uninstallcmd1 = "cd $appfolder\"
    $Uninstallcmd2 = "Powershell.exe -noexit -ep bypass -file .\$Global:ScriptName.ps1 -installtype UnInstall"
    $ModifyString = "CMD /C START cmd /c "+'"'+"$appfolder\reinstall-$guid.bat"+'"'
    $ModifyBAT = "$appfolder\reinstall-$guid.bat"
    $Modifycmd1 = "cd $appfolder\"
    $Modifycmd2 = "Powershell.exe -noexit -ep bypass -file .\$Global:ScriptName.ps1 -installtype ReInstall"
    $IconPath = "$appfolder\$IconName.ico"  
     if(!(Test-Path $AppFolder )){
        Try {New-Item -ItemType Directory -Path $AppFolder  -Force
            logwrite -Logstring "Success to create program files path for uninstall script" -type Info}
        catch [Exception]{logwrite -Logstring "Failed to create program files path for uninstall script with error: $_" -type Warning}}
    Try {$Content = [System.Convert]::FromBase64String($icon)
        Set-Content -Path $IconPath -Value $content -Encoding Byte
        logwrite -Logstring "Success to copy icon to program files path" -type Info}
    catch [Exception]{logwrite -Logstring "Failed to copy icon to program files path with error: $_" -type Warning}
    If ("$($Global:ScriptPath)" -ne "$($AppFolder)\$($Global:ScriptName).ps1"){
        try {copy-item $Global:ScriptPath "$AppFolder\$Global:ScriptName.ps1" -force | Out-null
            logwrite -Logstring "Success to copy current executing script to program files path for uninstall" -type Info}
        catch [Exception]{logwrite -Logstring "Failed to copy current executing script to program files path for uninstall with error: $_" -type Warning}}
    $Uninstallcmd1 | Out-File -FilePath $UninstallBAT -Encoding ascii -Force
    $Uninstallcmd2 | Out-File -FilePath $UninstallBAT -Encoding ascii -Append
    $Modifycmd1 | Out-File -FilePath $ModifyBAT -Encoding ascii -Force
    $Modifycmd2 | Out-File -FilePath $ModifyBAT -Encoding ascii -Append

    Try{IF(!(Get-PSDrive HKCR -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) {New-PSDrive -PSProvider Registry -Name HKCR -Root  HKEY_CLASSES_ROOT | Out-Null}
                logwrite -Logstring "Success to connect to HKCR registry." -type Info}
    Catch [Exception]{logwrite -Logstring "Failed to connect to HKCR registry with error: $_" -type Warning}

    #Add regkeys to Add Remove Programs for Always On VPN
    IF(!(Test-Path $AddRemKey)){
        Try {New-Item -Path $AddRemKey -Force | Out-Null
            logwrite -Logstring "Success to create Registry Path $($AddRemKey) in registry." -type Info}
        catch{logwrite -Logstring "Failed to create Registry Path $($AddRemKey) in registry" -type Warning}
        }    
    try {New-ItemProperty -Path $AddRemKey -Name DisplayName -PropertyType String -Value $displayname -Force | Out-null
        logwrite -Logstring "Success to create Registry key DisplayName for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key DisplayName for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $AddRemKey -Name DisplayVersion -PropertyType String -Value $Version -Force | Out-null
        logwrite -Logstring "Success to create Registry key DisplayVersion for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key DisplayVersion for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $AddRemKey -Name VersionMajor -PropertyType String -Value $Version.major -Force | Out-null
        logwrite -Logstring "Success to create Registry key VersionMajor for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key VersionMajor for Add Remove Programs with error: $_" -type Warning} 
        try {New-ItemProperty -Path $AddRemKey -Name VersionMinor -PropertyType String -Value $Version.minor -Force | Out-null
        logwrite -Logstring "Success to create Registry key VersionMinor for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key VersionMinor for Add Remove Programs with error: $_" -type Warning}
    if ($uninstall){    
        try {New-ItemProperty -Path $AddRemKey -Name UninstallString -PropertyType String -Value $UninstallString -Force | Out-null
            logwrite -Logstring "Success to create Registry key UninstallString for Add Remove Programs." -type Info}
        catch [Exception]{logwrite -Logstring "Failed to create Registry key UninstallString for Add Remove Programs with error: $_" -type Warning}
        try {New-ItemProperty -Path $AddRemKey -Name UninstallPath -PropertyType String -Value $UninstallString -Force | Out-null
            logwrite -Logstring "Success to create Registry key UninstallPath for Add Remove Programs." -type Info}
        catch [Exception]{logwrite -Logstring "Failed to create Registry key UninstallPath for Add Remove Programs with error: $_" -type Warning}
        try {New-ItemProperty -Path $AddRemKey -Name NoRemove -PropertyType dword -Value 0 -Force | Out-null
            logwrite -Logstring "Success to create Registry key NoRemove for Add Remove Programs." -type Info}
        catch [Exception]{logwrite -Logstring "Failed to create Registry key NoRemove for Add Remove Programs with error: $_" -type Warning}}
    else{
        try {New-ItemProperty -Path $AddRemKey -Name NoRemove -PropertyType dword -Value 1 -Force | Out-null
            logwrite -Logstring "Success to create Registry key NoRemove for Add Remove Programs." -type Info}
        catch [Exception]{logwrite -Logstring "Failed to create Registry key NoRemove for Add Remove Programs with error: $_" -type Warning}}
    try {New-ItemProperty -Path $AddRemKey -Name Publisher -PropertyType String -Value $Publisher -Force | Out-null
        logwrite -Logstring "Success to create Registry key Publisher for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key Publisher for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $AddRemKey -Name Displayicon -PropertyType String -Value $IconPath -Force | Out-null
        logwrite -Logstring "Success to create Registry key DisplayIcon for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key DisplayIcon for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $AddRemKey -Name Comments -PropertyType String -Value $Displayname -Force | Out-null
        logwrite -Logstring "Success to create Registry key Comments for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key Comments for Add Remove Programs with error: $_" -type Warning}   
    try {New-ItemProperty -Path $AddRemKey -Name InstallLocation -PropertyType String -Value "c:\windows\vclogs" -Force | Out-null
        logwrite -Logstring "Success to create Registry key InstallLocation for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key InstallLocation for Add Remove Programs with error: $_" -type Warning}
    if ($modify){
        try {New-ItemProperty -Path $AddRemKey -Name ModifyString -PropertyType String -Value $ModifyString -Force | Out-null
            logwrite -Logstring "Success to create Registry key ModifyString for Add Remove Programs." -type Info}
        catch [Exception]{logwrite -Logstring "Failed to create Registry key ModifyString for Add Remove Programs with error: $_" -type Warning}
        try {New-ItemProperty -Path $AddRemKey -Name ModifyPath -PropertyType String -Value $ModifyString -Force | Out-null
            logwrite -Logstring "Success to create Registry key ModifyPath for Add Remove Programs." -type Info}
        catch [Exception]{logwrite -Logstring "Failed to create Registry key ModifyPath for Add Remove Programs with error: $_" -type Warning}
        try {New-ItemProperty -Path $AddRemKey -Name NoModify -PropertyType dword -Value 0 -Force | Out-null
            logwrite -Logstring "Success to create Registry key NoModify for Add Remove Programs." -type Info}
        catch [Exception]{logwrite -Logstring "Failed to create Registry key NoModify for Add Remove Programs with error: $_" -type Warning}}
    else{
        try {New-ItemProperty -Path $AddRemKey -Name NoModify -PropertyType dword -Value 1 -Force | Out-null
            logwrite -Logstring "Success to create Registry key NoModify for Add Remove Programs." -type Info}
        catch [Exception]{logwrite -Logstring "Failed to create Registry key NoModify for Add Remove Programs with error: $_" -type Warning}}

    IF(!(Test-Path $ProductsKey)){
        Try {New-Item -Path $ProductsKey -Force | Out-Null
            logwrite -Logstring "Success to create Registry Path $($ProductsKey) in registry." -type Info}
         catch{logwrite -Logstring "Cannot create Registry Path $($ProductsKey) in registry" -type Warning}
         }
    try {New-ItemProperty -Path $ProductsKey -Name ProductName -PropertyType String -Value $DisplayName -Force | Out-null
        logwrite -Logstring "Success to create Registry key ProductName for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key ProductName for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name ProductIcon -PropertyType String -Value $IconPath -Force | Out-null
        logwrite -Logstring "Success to create Registry key ProductIcon for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key ProductIcon for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name AdvertiseFlags -PropertyType dword -Value 388 -Force | Out-null
        logwrite -Logstring "Success to create Registry key AdvertiseFlags for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key AdvertiseFlags for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name Assignment -PropertyType dword -Value 1 -Force | Out-null
        logwrite -Logstring "Success to create Registry key Assignment for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key Assignment for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name AuthorizedLUAApp -PropertyType dword -Value 0 -Force | Out-null
        logwrite -Logstring "Success to create Registry key AuthorizedLUAApp for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key AuthorizedLUAApp for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name Clients -PropertyType MultiString  -Value (':') -Force | Out-null
        logwrite -Logstring "Success to create Registry key Clients for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key Clients for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name DeploymentFlags -PropertyType dword -Value 3 -Force | Out-null
        logwrite -Logstring "Success to create Registry key DeploymentFlags for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key DeploymentFlags for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name InstanceType -PropertyType dword -Value 0 -Force | Out-null
        logwrite -Logstring "Success to create Registry key InstanceType for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key InstanceType for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name Language -PropertyType dword -Value 1033 -Force | Out-null
        logwrite -Logstring "Success to create Registry key Language for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key Language for Add Remove Programs with error: $_" -type Warning}
    IF(!(Test-Path $ProductsKey\Sourcelist)){
        Try {New-Item -Path $ProductsKey\Sourcelist -Force | Out-Null
            logwrite -Logstring "Success to create Registry Path $($ProductsKey)\Sourcelist in registry." -type Info}
         catch{logwrite -Logstring "Cannot create Registry Path $($ProductsKey)\Sourcelist in registry" -type Warning}
         }
    try {New-ItemProperty -Path $ProductsKey\Sourcelist -Name LastUsedSource -PropertyType ExpandString -Value "n;1;$($appfolder)\" -Force | Out-null
        logwrite -Logstring "Success to create Registry key LastUsedSource for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key LastUsedSource for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey\Sourcelist -Name PackageName -PropertyType String -Value "uninstall-$($guid).bat" -Force | Out-null
        logwrite -Logstring "Success to create Registry key PackageName for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key PackageName for Add Remove Programs with error: $_" -type Warning}
    IF(!(Test-Path $ProductsKey\sourcelist\media)){
        Try {New-Item -Path $ProductsKey\Sourcelist\media -Force | Out-Null
            logwrite -Logstring "Success to create Registry Path $($ProductsKey)\Sourcelist\media in registry." -type Info}
         catch{logwrite -Logstring "Cannot create Registry Path $($ProductsKey)\Sourcelist\media in registry" -type Warning}
         }
    try {New-ItemProperty -Path $ProductsKey\Sourcelist\media -Name 1 -PropertyType String -Value ";" -Force | Out-null
        logwrite -Logstring "Success to create Registry key 1 for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key 1 for Add Remove Programs with error: $_" -type Warning}
    IF(!(Test-Path $ProductsKey\Sourcelist\Net)){
        Try {New-Item -Path $ProductsKey\Sourcelist\Net -Force | Out-Null
            logwrite -Logstring "Success to create Registry Path $($ProductsKey)\Sourcelist\net in registry." -type Info}
         catch{logwrite -Logstring "Cannot create Registry Path $($ProductsKey)\Sourcelist\net in registry" -type Warning}
         }
    try {New-ItemProperty -Path $ProductsKey\Sourcelist\Net -Name 1 -PropertyType ExpandString -Value "$($appfolder)\" -Force | Out-null
        logwrite -Logstring "Success to create Registry key 1 for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Failed to create Registry key 1 for Add Remove Programs with error: $_" -type Warning}

    remove-psdrive -name HKCR 
 }

 Function Remove-AddRemovePrograms($DisplayName, $Version, $guid, $AppFolder){  

    logwrite -Logstring "Success to start removing entry in Add Remove Programs for Always On VPN" -type Info
    $ProductID = $guid -replace '[{}]',""
    $ProductID = $productID.Split("-")
    $id0 = $ProductID[0][-1..-$ProductID[0].Length] -join ''
    $id1 = $ProductID[1][-1..-$ProductID[1].Length] -join ''
    $id2 = $ProductID[2][-1..-$ProductID[2].Length] -join ''
    $id3 = $ProductID[3][-1..-$ProductID[3].Length] -join ''
    $id4 = $ProductID[4].TocharArray()
    $id4 = $id4[1]+$id4[0]+$id4[3]+$id4[2]+$id4[5]+$id4[4]+$id4[7]+$id4[6]+$id4[9]+$id4[8]+$id4[11]+$id4[10]
    $ProductID = $id0+$id1+$id2+$id3+$id4
    $AddRemKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
    $ProductsKey = "HKCR:\Installer\Products\$ProductID"
    $IconName = $displayname -replace '\s',''
    $Iconfile = "$IconName.ico"
    
    Try{IF(!(Get-PSDrive HKCR -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) {New-PSDrive -PSProvider Registry -Name HKCR -Root  HKEY_CLASSES_ROOT | Out-Null}
                logwrite -Logstring "Success to connect to HKCR registry." -type Info}
            Catch [Exception]{logwrite -Logstring "Failed to connect to HKCR registry with error: $_" -type Warning}

    IF(Test-Path $AddRemKey){
        Try{Remove-Item -Path $AddRemKey -ErrorAction SilentlyContinue -Force | Out-null
            logwrite -Logstring "Success to remove Registry hive $($AddRemKey) from registry." -type Info}
        catch {logwrite -Logstring "Failed to remove Registry hive $($AddRemKey) from registry." -type Warning}
        }
    else{logwrite -Logstring "Skipped to remove Registry hive $($AddRemKey), does not exist" -type Warning}

    IF(Test-Path $ProductsKey){
        Try{Remove-Item -Path $ProductsKey -ErrorAction SilentlyContinue -Force -Recurse | Out-null
            logwrite -Logstring "Success to remove Registry hive $($ProductsKey) from registry." -type Info}
        catch {logwrite -Logstring "Failed to remove Registry hive $($ProductsKey) from registry." -type Warning}
        }
    else{logwrite -Logstring "Skipped to remove Registry hive $($ProductsKey), does not exist" -type Warning}

    if(Test-Path $AppFolder ){
        $Otherfiles = Get-ChildItem $AppFolder -recurse -exclude "$Global:ScriptName.ps1", "uninstall-$guid.bat", "reinstall-$guid.bat", $Iconfile
        if ($otherfiles){
            logwrite -Logstring "Failed to delete Program files folder, the folder is not empty" -type Warning
            if (test-path "$appfolder\$Global:ScriptName.ps1")
                {Try{Remove-Item "$appfolder\$Global:ScriptName.ps1" -force
                    logwrite -Logstring "Success to remove script $($Global:ScriptName).ps1 from $($appfolder)." -type Info}
                catch {logwrite -Logstring "Failed to remove script $($Global:ScriptName).ps1 from $($appfolder)." -type Warning}
                }
            if (test-path "$appfolder\$IconFile")
                {Try{Remove-Item "$appfolder\$IconFile" -force
                    logwrite -Logstring "Success to remove script $($IconFile) from $($appfolder)." -type Info}
                catch {logwrite -Logstring "Failed to remove script $($IconFile) from $($appfolder)." -type Warning}
                }
            if (test-path "$appfolder\uninstall-$guid.bat")
                {Try{Remove-Item "$appfolder\uninstall-$guid.bat" -force
                    logwrite -Logstring "Success to remove script uninstall-$($guid).bat from $($appfolder)." -type Info}
                catch {logwrite -Logstring "Failed to remove script uninstall-$($guid).bat from $($appfolder)." -type Warning}
                }
            if (test-path "$appfolder\reinstall-$guid.bat")
                {Try{Remove-Item "$appfolder\reinstall-$guid.bat" -force
                    logwrite -Logstring "Success to remove script reinstall-$($guid).bat from $($appfolder)." -type Info}
                catch {logwrite -Logstring "Failed to remove script reinstall-$($guid).bat from $($appfolder)." -type Warning}
                }
            }
        else {
            Try {Get-ChildItem -Path "$Appfolder\\*" -Recurse | Remove-Item -Force -Recurse
                logwrite -Logstring "Success to remove the add remove program associeated files" -type Info}
            catch [Exception]{logwrite -Logstring "Failed to remove the add remove program associated files with error: $_" -type Warning}
            Try {Remove-Item $appfolder -Force -ErrorAction Stop
                logwrite -Logstring "Success to remove the add remove program folder" -type Info
            }
            catch [Exception] {logwrite -Logstring "Failed to remove the add remove program folder with error: $_" -type Warning}
        }
    }
}

    function Set-PBKKey{
        param(
            [string]$path,
            [string]$section,
            [string]$key,
            [string]$value
        )
    
        $edits = (Get-Content $path) -join "`r`n" -split '\s(?=\[.+?\])' | ForEach-Object{
            If($_ -match "\[$section\]"){
                $_ -replace "($key=)\w+", "$key=$value"
            } Else {
                $_
            }
        }
    
        -join $edits | Set-Content $path
    }
    
    Function Get-LoggedInUser {
 try {$username = Gwmi -Class Win32_ComputerSystem | select username | WHERE username -ne $NULL
       logwrite -Logstring "Success to enumerate Username from WMI to $($username)." -type info}
       catch [Exception] {logwrite -Logstring "Failed to enumerate Username from WMI, user may be logged on over Remote Desktop. $_" -type Warning}
        # The VPN connection is created for the end user logged on to the computer. Enumeration of currently logged on user SID
    if (!$username){
    Try {New-PSDrive HKU Registry HKEY_USERS -ErrorAction Continue | out-null
           logwrite -Logstring "Success to create a psdrive to HKU"}
       Catch{logwrite -Logstring "Failed to create a psdrive to HKU with error: $_" -type Error}
        try {
            $users = query user /server:localhost
            $Users = $Users | ForEach-Object {(($_.trim() -replace ">" -replace "(?m)^([A-Za-z0-9]{3,})\s+(\d{1,2}\s+\w+)", '$1  none  $2' -replace "\s{2,}", "," -replace "none", $null))} | ConvertFrom-Csv
            foreach ($User in $Users){
                if ($User.STATE -eq "Active")
                {
                $RDPUser = $User.username}
                }
               logwrite -Logstring "Success to enumerate Username from registry RDP sessions to $($username)." -type info}
           catch [Exception] {logwrite -Logstring "Failed to enumerate Username from registry RDP sessions with error: $_" -type Error}

        $hkeyUsersSubkeys = Get-ChildItem -Path HKU:\ -Recurse -Depth 2| where name -like "*Volatile Environment"
        foreach ($userkey in $hkeyUsersSubkeys) {
            $userkey = $userkey -replace "HKEY_USERS\\", "HKU:\" 
            if (((Get-ItemProperty -Path $Userkey)."username") -eq $RDPUser)
               {$DomainName = (Get-ItemProperty -Path $Userkey)."userdomain"
                $UserName = "$DomainName\$RDPUser"
            }
        }
    }
    else {$username = $username.username.tostring()}    

    try {
        $domain, $logonname = $username.tostring().split('\') 
        $objuser = New-Object System.Security.Principal.NTAccount($username)
        $sid = $objuser.Translate([System.Security.Principal.SecurityIdentifier])
        $SidValue = $sid.Value
           logwrite -Logstring "Success to enumerate Username: $($logonname) and SID: $($SidValue)" -type info
        }
           catch [Exception] {logwrite -Logstring "Failed to enumerate Username and SID with error $_" -type Error}
        return $logonname, $SidValue
    }

#endregion

#region ---------------------------------------------------[[Script Execution]------------------------------------------------------
logwrite -Logstring "Starting script $($Global:ScriptName) with installtype: $($InstallType) option set" -type Start

    # Check if existing Always On VPN config version exist in Add Remove Program registry
if(Test-Path $AppKey){
        Try{[version]$CurrentVersion = (Get-ItemProperty -Path $AppKey -Name DisplayVersion -ErrorAction SilentlyContinue).DisplayVersion
        logwrite -Logstring "Success to get Currentversion from registry, Currentversion is $($CurrentVersion)" -type Info}
    catch{logwrite -Logstring "Failed to get Currentversion from registry, setting 0.0.0.0 as version" -type Info
            [version]$currentversion = "0.0.0.0"}}
else {logwrite -Logstring "Skipped to get Currentversion from registry due to not exist, setting 0.0.0.0 as version" -type Info
        [version]$currentversion = "0.0.0.0"}
    
# Check if existing Always On VPN config version is older than script version or if script run with ReInstall or UnInstall Option
    if ([version]$CurrentVersion -lt [version]$ConfigVersion -or $InstallType -eq "Reinstall"-or $InstallType -eq "Uninstall")
        {
    logwrite -Logstring "Success to start execute script with Installed version: $($currentversion), Script version: $($configversion), Installtype: $($installtype)" -type Info

    # To create device tunnel or all users tunnel the script needs to run as System. To create user tunnel the script needs to run in user context as system or admin
    if (($XMLVPNProfile.ChildNodes.devicetunnel -eq "true" -or $AllUserProfile) -and ($InstallType -eq "install" -or $installtype -eq "reinstall")){
        if ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18"){$SidValue = "S-1-5-18";logwrite -Logstring "Success to verify credentials, The script is running as admin with the SYSTEM credentials" -type Info}
        else {logwrite -Logstring "Failed to verify credentials, The script is running as admin but must run as System" -type Error}}
    else{
        $logonname, $sidvalue = Get-LoggedInUser
        if ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18"){logwrite -Logstring "Success to verify credentials, The script is running as admin with the SYSTEM credentials" -type Info}
        elseif ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq $SidValue){logwrite -Logstring "Success to verify credentials, The script is running as admin with the current user credentials" -type Info}
        else {logwrite -Logstring "Failed to verify credentials, The script is running as admin but with wrong credentials. Must run as admin with the logged on user credentials, or run as System" -type Error}
        } 
            
                # Set WAP Push Service to start automatically 
        enable-Service $servicename $serviceTimeout $serviceRetry

    #Connect CSP over WMI, The Best way to create and delete Always on VPN is via CSP over WMI Bridge. 
            try {
                $session = New-CimSession
        if ($XMLVPNProfile.ChildNodes.devicetunnel -ne "true"){
                    $options = New-Object Microsoft.Management.Infrastructure.Options.CimOperationOptions
                    $options.SetCustomOption("PolicyPlatformContext_PrincipalContext_Type", "PolicyPlatform_UserContext", $false)
                    $options.SetCustomOption("PolicyPlatformContext_PrincipalContext_Id", "$SidValue", $false)
                    }
        logwrite -Logstring "Success to connect CSP over WMI bridge"}
    catch [Exception] {logwrite -Logstring "Failed to connect CSP over WMI bridge with error: $_" -type Error}

    #If there is an existing VPN tunnel with the same name already deployed, It must be disconnected 
    try {rasdial $profilename /disconnect |out-null
        logwrite -Logstring "Success to disconnect VPN Tunnel $($profilename)" -type Info}
    catch [Exception] {logwrite -Logstring "Failed to disconnect VPN tunnel $($profilename)" -type Info}
    if (!([string]::IsNullOrWhitespace($Oldprofilename))){
        try {rasdial $Oldprofilename /disconnect |out-null
            logwrite -Logstring "Success to disconnect VPN Tunnel $($Oldprofilename)" -type Info}
        catch [Exception] {logwrite -Logstring "Failed to disconnect VPN tunnel $($Oldprofilename)" -type Info}
        }

    #If there is an existing VPN tunnel with the same name already deployed, It must be removed before creating a new config. 
        try {
        if ($XMLVPNProfile.ChildNodes.devicetunnel -eq "true" -or $AllUserProfile)
                {$deleteInstances = $session.EnumerateInstances($namespaceName, $className)}
            else{$deleteInstances = $session.EnumerateInstances($namespaceName, $className, $options)}
        logwrite -Logstring "Success to enumerate existing VPN Tunnels with CSP over WMI" -type Info
            }
    catch [Exception] {logwrite -Logstring "Failed to enumerate existing VPN Tunnels with CSP over WMI" -type Info}

    if (@($deleteInstances).count -gt 0){
          	foreach ($deleteInstance in $deleteInstances){
            	$InstanceId = $deleteInstance.InstanceID
            logwrite -Logstring "Success to enumerate VPN Tunnel $($instanceid) with CSP over WMI" -type Info
                if ($InstanceId -like $OldprofilenameEscaped -or $InstanceId -eq $ProfileNameEscaped){
                        try {if ($XMLVPNProfile.ChildNodes.devicetunnel -eq "true")
                            {$session.DeleteInstance($namespaceName, $deleteInstance)}
                    else{$session.DeleteInstance($namespaceName, $deleteInstance, $options)}
                    logwrite -Logstring "Success to delete VPN Tunnel $($instanceid) with CSP over WMI" -type Info
                	} 
                catch [Exception] {logwrite -Logstring "Failed to delete VPN Tunnel $($instanceid) with CSP over WMI with error: $_" -type warning}
              	} 
            else {logwrite -Logstring "Skipped to delete VPN Tunnel $($instanceid) with CSP over WMI, out of scope" -type Info}
       		    }
            }
    else {logwrite -Logstring "Skipped to delete VPN Tunnels with CSP over WMI, No VPN Tunnel found"}

    #Windows has had some bugs regarding removal of device tunnels, trying to remove also with pPowerShell. 
		    if ($deleteInstance = get-vpnconnection -alluserconnection -name "$profilename" -ErrorAction SilentlyContinue){
         	    try {$deleteInstance| remove-vpnconnection -force
            logwrite -Logstring "Success to delete VPN Tunnel $($profilename) with PowerShell" -type Info}
        catch [Exception] {logwrite -Logstring "Failed to delete VPN Tunnel $($profilename) with PowerShell with error: $_" -type warning}}
            elseif ($deleteInstance = get-vpnconnection -name "$profilename" -ErrorAction SilentlyContinue){
                try {$deleteInstance| remove-vpnconnection -force
            logwrite -Logstring "Success to delete VPN Tunnel $($profilename) with PowerShell" -type Info}
        catch [Exception] {logwrite -Logstring "Failed to delete VPN Tunnel $($profilename) with PowerShell with error: $_" -type warning}}
    else {logwrite -Logstring "Skipped to delete VPN Tunnel $($profilename) with PowerShell, no VPN tunnel exist" -type Info}
    if (!([string]::IsNullOrWhitespace($Oldprofilename))){
        if ($deleteInstance = get-vpnconnection -alluserconnection -name "$oldprofilename" -ErrorAction SilentlyContinue){
                try {$deleteInstance| remove-vpnconnection -force
                logwrite -Logstring "Success to delete old VPN Tunnel $($oldprofilename) with PowerShell" -type Info}
            catch [Exception] {logwrite -Logstring "Failed to delete old VPN Tunnel $($oldprofilename) with PowerShell with error: $_" -type warning}}
           elseif ($deleteInstance = get-vpnconnection -name "$oldprofilename" -ErrorAction SilentlyContinue){
               try {$deleteInstance| remove-vpnconnection -force
                logwrite -Logstring "Success to delete old VPN Tunnel $($oldprofilename) with PowerShell" -type Info}
            catch [Exception] {logwrite -Logstring "Failed to delete old VPN Tunnel $($oldprofilename) with PowerShell with error: $_" -type warning}}
        else {logwrite -Logstring "Skipped to delete old VPN Tunnel $($oldprofilename) with PowerShell, no VPN tunnel exist" -type Info}
        }
        
    # Remove old MDM tracked setting with VPN tunnel Name
    Try {$MDMSettings = Get-ChildItem -Path $MDMPath -Recurse -Depth 3 | get-itemproperty | where { $_  -match  "$ProfileNameEscaped"}
        logwrite -Logstring "Success to get MDM Tracking from registry" -type Info}
    Catch [Exception]{logwrite -Logstring "Failed to get MDM Tracking from registry with error: $_" -type warning;$MDMsettings=$null}
            If ($MDMsettings) {Try {$MDMsettings | Remove-Item -Force
        logwrite -Logstring "Success to delete MDM Tracking from registry" -type Info}
        catch [Exception]{logwrite -Logstring "Failed to delete MDM Tracking from registry with error: $_" -type warning}}
    Else {logwrite -Logstring "Skipped to delete MDM Tracking from registry, does not exist"}

    # Remove old VPN NetworkList Profiles with VPN tunnel Name
    Try {$NetworkProfile = Get-Childitem -Path $NetworkProfilesPath | Where {(Get-ItemPropertyValue $_.PsPath -Name Description) -eq $ProfileName}
            logwrite -Logstring "Success to get NetworkList from registry" -type Info}
    Catch [Exception]{logwrite -Logstring "Failed to get NetworkList from registry with error: $_" -type warning;$NetworkProfile=$null}
            If ($NetworkProfile) {Try {$NetworkProfile | Remove-Item -Force
        logwrite -Logstring "Success to delete NetworkList from registry" -type Info}
        catch [Exception]{logwrite -Logstring "Failed to delete NetworkList from registry with error: $_" -type warning}}
    Else {logwrite -Logstring "Skipped to delete NetworkList from registry, does not exist"}
    
    # Remove old VPN Autoconnect and other info in registry with VPN tunnel Name
            if ($XMLVPNProfile.ChildNodes.devicetunnel -eq "true")
        { #Device tunnel registry hive
        If (test-path $DeviceTunnelInfoPath) {
            Try {Remove-Item $DeviceTunnelInfoPath -Force
                logwrite -Logstring "Success to delete reghive $($DeviceTunnelInfoPath) from registry" -type Info}
            catch [Exception]{logwrite -Logstring "Failed to delete reghive $($DeviceTunnelInfoPath) from registry with error: $_" -type warning}}
        Else {logwrite -Logstring "Skipped to delete reghive $($DeviceTunnelInfoPath) from registry, reghive does not exist" -type Info}   
            }
            else
        {# User tunnel registry settings
        Try {[string[]]$DisabledProfiles = Get-ItemPropertyValue -Path $UserTunnelInfoPath -Name AutoTriggerDisabledProfilesList -ErrorAction SilentlyContinue
                logwrite -Logstring "Success to get AutoTriggerDisabledProfilesList from registry" -type Info}
        Catch [Exception]{logwrite -Logstring "Failed to get AutoTriggerDisabledProfilesList from registry with error: $_" -type warning;$DisabledProfiles=$null}
                If ($DisabledProfiles) {
                    $DisabledProfilesList = [Ordered]@{}
                    $DisabledProfiles | ForEach-Object { $DisabledProfilesList.Add("$($_.ToLower())", $_) }
                    If ($DisabledProfilesList.Contains($ProfileName)) {
                        $DisabledProfilesList.Remove($ProfileName)
                        try{Set-ItemProperty -Path $UserTunnelInfoPath -Name AutoTriggerDisabledProfilesList -Value $DisabledProfilesList.Values
                logwrite -Logstring "Success to remove AutoTriggerDisabledProfilesList from registry" -type Info}
                Catch [Exception]{logwrite -Logstring "Failed to remove AutoTriggerDisabledProfilesList from registry with error: $_" -type warning}
                        }
                    }
        Else {logwrite -Logstring "Skipped to remove AutoTriggerDisabledProfilesList from registry, key does not exist"}
                }  
        
                # Create the new Always on VPN connection. This uses CSP over WMI bridge
        if ($InstallType -eq "install" -or $installtype -eq "reinstall"){
            try {
                $NewInstance = New-Object Microsoft.Management.Infrastructure.CimInstance $ClassName, $NamespaceName
                $Property = [Microsoft.Management.Infrastructure.CimProperty]::Create('ParentID', "$nodeCSPURI", 'String', 'Key')
                $NewInstance.CimInstanceProperties.Add($Property)
                $Property = [Microsoft.Management.Infrastructure.CimProperty]::Create('InstanceID', "$ProfileNameEscaped", 'String', 'Key')
                $NewInstance.CimInstanceProperties.Add($Property)
                $Property = [Microsoft.Management.Infrastructure.CimProperty]::Create('ProfileXML', "$VPNProfileXML", 'String', 'Property')
                $NewInstance.CimInstanceProperties.Add($Property)
                if ($XMLVPNProfile.ChildNodes.devicetunnel -eq "true")
                    {$vpnObject = $Session.CreateInstance($NamespaceName, $NewInstance)}
                    else{$vpnObject = $session.CreateInstance($namespaceName, $newInstance, $options)}
            logwrite -Logstring "Success to create VPN Profile $($ProfileName)" -type Info
                }
        catch [Exception] {logwrite -Logstring "Failed to create VPN Profile $($ProfileName) with error: $_" -type Error}

    #Getting Phonebook (PBX) file for the created vpn tunnel
    if ($XMLVPNProfile.ChildNodes.devicetunnel -eq "true" -or $AllUserProfile)
        {$AutoTriggerProfilePhonebookPath = $DeviceTunnelInfoPath
        $RasPhone = "C:\ProgramData\Microsoft\Network\Connections\Pbk\rasphone.pbk"}
    else {$AutoTriggerProfilePhonebookPath = $UserTunnelInfoPath
        Try{$UserProfilePath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$SidValue"  -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
            $RasPhone = "$UserProfilePath\Appdata\Roaming\Microsoft\Network\Connections\Pbk\rasphone.pbk"
            logwrite -Logstring "Success to enumerate UserProfilePath for logged on user to: $($UserProfilePath)" -type Info}
        catch [Exception]{logwrite -Logstring "Failed to enumerate UserProfilePath for logged on user with error: $_" -type warning}        
        }   
    if(Test-Path $AutoTriggerProfilePhonebookPath){
        Try{$RasPhone = (Get-ItemProperty -Path $AutoTriggerProfilePhonebookPath -Name AutoTriggerProfilePhonebookPath -ErrorAction SilentlyContinue).AutoTriggerProfilePhonebookPath
            logwrite -Logstring "Success to enumerate Path for PBX file from registry to: $($RasPhone)" -type Info}
        catch{logwrite -Logstring "Failed to enumerate Path for PBX file from registry, using default path" -type warning}
            }    

        IF(Test-Path $RasPhone){
            logwrite -Logstring "Success to Find PBX file on path $($RasPhone)" -type info
            # Change VPN tunnel protocol 
            try{Set-PBKKey $RasPhone $ProfileName "VpnStrategy" $VpnStrategy
                logwrite -Logstring "Success to change VpnStrategy in PBK to $($VpnStrategy)." -type Info} 
            catch [Exception] {logwrite -Logstring "Failed to change VpnStrategy in PBK with error: $_" -type Warning}

                # Change VPN mobility setting 
            try{Set-PBKKey $RasPhone $ProfileName "DisableMobility" $DisableMobility
                logwrite -Logstring "Success to change DisableMobility in PBK to $($DisableMobility)." -type Info} 
            catch [Exception] {logwrite -Logstring "Failed to change DisableMobility in PBK with error: $_" -type Warning}

    #Setting Phonebook entry settings if not supported by ProfileXML
    $WinInsider = 23403
    If (((Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name Currentbuild).Currentbuild) -lt $WinInsider){
        logwrite -Logstring "Success to verify Windows older than Windows 11 iDeveloper build $($WinInsider) is running, settings will be applied to PBX file" -type Info
  
            # Change IPv4 VPN tunnel adapter priority for better DNS resolution
            try{Set-PBKKey $RasPhone $ProfileName "IpInterfaceMetric" $RasNicMetric
                logwrite -Logstring "Success to change RasNicMetric in PBK to $($RasNicMetric)." -type Info} 
            catch [Exception] {logwrite -Logstring "Failed to change RasNicMetric in PBK with error: $_" -type Warning}

            # Change IPv4 VPN tunnel adapter priority for better DNS resolution
            try{Set-PBKKey $RasPhone $ProfileName "Ipv6InterfaceMetric" $RasNicMetricIPv6
                logwrite -Logstring "Success to change RasNicMetric IPV6 in PBK to $($RasNicMetricIPv6)." -type Info} 
            catch [Exception] {logwrite -Logstring "Failed to change RasNicMetric IPV6 in PBK with error: $_" -type Warning}

            # Change timeout for Network Outage time in VPN mobility 
            try{Set-PBKKey $RasPhone $ProfileName "NetworkOutageTime" $NetworkOutageTime
                logwrite -Logstring "Success to change NetworkOutageTime in PBK to $($NetworkOutageTime)." -type Info} 
                catch [Exception] {logwrite -Logstring "Failed to change NetworkOutageTime in PBK with error: $_" -type Warning}

            # Change use RAS credentials to cache VPN credentials or not
            try{Set-PBKKey $RasPhone $ProfileName "UseRasCredentials" $UseRasCredentials
                logwrite -Logstring "Success to change UseRasCredentials in PBK to $($UseRasCredentials)." -type Info} 
            catch [Exception] {logwrite -Logstring "Failed to change UseRasCredentials in PBK with error: $_" -type Warning}
    }
                    }    
        else {logwrite -Logstring "Failed to Find PBX file on path $($RasPhone)" -type warning}

                #Add regkey for a more reliable DNS registration
            try {New-ItemProperty -Path 'HKLM:SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\' -Name DisableNRPTForAdapterRegistration -PropertyType DWORD -Value 1 -Force | Out-null
            logwrite -Logstring "Success to create regkey DisableNRPTForAdapterRegistration for a more reliable DNS registration" -type Info}
        catch [Exception]{logwrite -Logstring "Failed to create regkey DisableNRPTForAdapterRegistration for a more reliable DNS registration with error: $_" -type Warning}

                # Register or unregister in Add Remove Programs for Version and uninstallation info
            if ($AddRemoveProgramEnabled) {Add-AddRemovePrograms $ProfileName $ConfigVersion $AppGuid $AppPublisher $AppIcon $AppFolder $AddRemoveProgramUninstall $AddRemoveProgramModify}

                # Connect the vpn
                try {rasdial $profilename | out-null
            logwrite -Logstring "Success to trigger VPN Tunnel $($profilename) to connect" -type Info}
        catch [Exception] {logwrite -Logstring "Success to trigger VPN Tunnel $($profilename) to connect with error: $_" -type warning}
            }

            # Remove Always On VPN config version in registry if installtype is Uninstall
        if ($InstallType -eq "UnInstall"){if ($AddRemoveProgramEnabled) {Remove-AddRemovePrograms $ProfileName $ConfigVersion $AppGuid $appfolder}}
    }
else {logwrite -Logstring "Skipped to start execute script with Installed version: $($currentversion), Script version: $($configversion), Installtype: $($installtype)" -type Info}

Set-StrictMode -Off
logwrite -Logstring "Script ended" -type End
#endregion