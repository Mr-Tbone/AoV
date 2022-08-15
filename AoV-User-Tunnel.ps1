<#PSScriptInfo
.SYNOPSIS
    Script for Always On VPN 
 
.DESCRIPTION
    This script will configure Always On VPN connection for the User 
    The script uses CSP over WMI to configure the VPN profile
    The script needs to be run in the targeted end user context. Either with end user elevated as admin or as "nt authority\system"
        
.EXAMPLE
   .\AoV-User-Tunnel.ps1
    Will configure Always On VPN configuration for the User with settings in the modifyable region. 

   .\AoV-User-Tunnel.ps1 -InstallType ReInstall
    Will reconfigure Always On VPN configuration for the User with settings in the modifyable region. 

   .\AoV-User-Tunnel.ps1 -InstallType UnInstall
    Will remove Always On VPN configuration for the User with settings in the modifyable region.

.NOTES
    Written by Mr-Tbone (Tbone Granheden) Coligo AB
    torbjorn.granheden@coligo.se

.VERSION
    1.3

.RELEASENOTES
    1.0 2022-02-18 Initial Build
    1.1 2022-07-17 Solved a problem with uninstall device tunnel from Add Remove Programs
    1.2 2022-07-18 Solved Windows 11 problems with CSP over WMI. No blank DNS server list allowed
    1.3 2022-08-15 Fixed Version check

.AUTHOR
    Tbone Granheden 
    @MrTbone_se

.COMPANYNAME 
    Coligo AB

.GUID 
    00000000-0000-0000-0000-000000000000

.COPYRIGHT
    Feel free to use this, But would be grateful if My name is mentioned in Notes 

.CHANGELOG
    1.0.2202.1 - Initial Version
    1.0.2207.1 - Solved a problem with uninstall device tunnel from Add Remove Programs
    1.0.2207.2 - Solved Windows 11 problems with CSP over WMI. No blank DNS server list allowed       
    1.0.2208.1 - Fixed Version Check       
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
[version]$ConfigVersion   = "1.0.2208.1" #Increment when changing config, stored in registry to check if new config is needed. syntax: 1.1.YYMM.Version (1.1.2001.1)
$AddRemoveProgramEnabled  = $True        #$true register an App in Add Remove Programs for version and uninstall, $false skip registration in Add Remove Programs
$MinWinBuild              = 17763        #17763 will require Windows 1809 to execute

#Log settings
$Global:GuiLogEnabled   = $False       #$true for test of script in manual execution
$Global:EventlogEnabled = $True        #Creates an event log in Event viewer Application log
$Global:FileLogEnabled  = $False       #Creates a file log for troubleshooting
$Global:FileLogPath     = "$env:TEMP"  #Path to the file log
$Global:FileLogPurge    = $True        #Purge logs if $True
$Global:FileLogHistory  = 10           #Purge and keep this amount of logs

#Always on VPN PBK settings
$RasNicMetric       = "3"   #Ras NIC ipv4 interface priority metric for a custom better DNS and nic priority. (0 = Default, 3 = Recommended)
$RasNicMetricIPv6   = "3"   #Ras NIC ipv4 interface priority metric for a custom better DNS and nic priority. (0 = Default, 3 = Recommended)
$VpnStrategy        = "8"   #Ras default protocol: 5 = Only SSTP,6 = SSTP first,7 = Only IKEv2,8 = IKEv2 first,14 = IKEv2 firstthen SSTP (6 = Default, 8 = Recommended)
$DisableMobility    = "0"   #VPN reconnect after network outage: 0 = Enabled, 1= Disabled (0 = Default, 0 = Recommended) 
$NetworkOutageTime  = "0"   #VPN reconnect timeout in seconds: '60', '120', '300', '600', '1200', '1800' (0 = default (1800 = 30 min), 0 = recommended)
$UseRasCredentials  = "1"   #VPN reuses RAS credentials to connect to internal resourses with SSO (1 = Default, 1 = Recommended)
   
# Always on VPN connection XML settings
$Oldprofilename = ''        #Optional, Cleanup of old connections with another name for example: "AoV-Usertunnel*". To delete none, enter: '' 
$ProfileName    = "$company AoV User Tunnel" #Name of the VPN profile to create
$ProfileXML     = '  
<VPNProfile>
<DeviceTunnel>false</DeviceTunnel>                              <!--Create Device Tunnel-->
<AlwaysOn>true</AlwaysOn>                                       <!--Make the tunnel Always on-->
<RememberCredentials>true</RememberCredentials>                 <!--Remeber credentials from last successfule connection-->
<TrustedNetworkDetection>coligo.se</TrustedNetworkDetection>    <!--Do not connect when on this network-->
<DnsSuffix>Coligo.se</DnsSuffix>                                <!--The DNS suffix for the VPN NIC-->
<RegisterDNS>false</RegisterDNS>                                <!--Register the VPN IP in Company DNS-->
<DomainNameInformation>                                         <!--NRPT and Trigger VPN to connect if using any of the listed adresses-->
    <DomainName>.coligo.se</DomainName>                         <!--NRPT domain to trigger this rule-->
    <DnsServers>10.10.10.4</DnsServers>                         <!--NRPT DNS to use when doing lookups on that domain. (Cannot be blank in Win 11)-->
    <AutoTrigger>true</AutoTrigger>                             <!--NRPT Auto connect VPN if using the domain name-->
</DomainNameInformation>
<DomainNameInformation>                                         <!--NRPT exclude your VPN server from suffix rule above -->
    <DomainName>vpn.coligo.se</DomainName>
    <DnsServers>1.1.1.1,8.8.8.8</DnsServers>                    <!--Using public DNS (Cannot be blank in Win 11)-->
    <AutoTrigger>true</AutoTrigger>                     
</DomainNameInformation>
    <NativeProfile>    
    <Servers>vpn.coligo.se</Servers>                            <!--VPN Server Address-->
    <NativeProtocolType>Automatic</NativeProtocolType>          <!--VPN Connection Protocol-->
    <RoutingPolicyType>SplitTunnel</RoutingPolicyType>          <!--VPN with SplitTunnel or ForcedTunnel-->
    <Authentication>                                            <!--VPN Authentication Method-->
            <UserMethod>Eap</UserMethod>
            <Configuration>
                <EapHostConfig xmlns="http://www.microsoft.com/provisioning/EapHostConfig">
                    <EapMethod><Type xmlns="http://www.microsoft.com/provisioning/EapCommon">13</Type>
                        <VendorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorId>
                        <VendorType xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorType>
                        <AuthorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</AuthorId>
                    </EapMethod>
                    <Config xmlns="http://www.microsoft.com/provisioning/EapHostConfig">
                        <Eap xmlns="http://www.microsoft.com/provisioning/BaseEapConnectionPropertiesV1">
                            <Type>13</Type>
                            <EapType xmlns="http://www.microsoft.com/provisioning/EapTlsConnectionPropertiesV1">
                                <CredentialsSource>
                                    <CertificateStore>
                                        <SimpleCertSelection>true</SimpleCertSelection>
                                    </CertificateStore>
                                </CredentialsSource>
                                <ServerValidation>
                                    <DisableUserPromptForServerValidation>true</DisableUserPromptForServerValidation>
                                    <ServerNames>NPS1.coligo.se;NPS2.coligo.se</ServerNames>
                                    <TrustedRootCA>66 99 9f 3b 10 5d 75 1c f4 6e 20 dd f2 60 69 fe 87 99 00 82 </TrustedRootCA>
                                </ServerValidation>
                                <DifferentUsername>false</DifferentUsername>
                                <PerformServerValidation xmlns="http://www.microsoft.com/provisioning/EapTlsConnectionPropertiesV2">true</PerformServerValidation>
                                <AcceptServerName xmlns="http://www.microsoft.com/provisioning/EapTlsConnectionPropertiesV2">true</AcceptServerName>
                                <TLSExtensions xmlns="http://www.microsoft.com/provisioning/EapTlsConnectionPropertiesV2">
                                    <FilteringInfo xmlns="http://www.microsoft.com/provisioning/EapTlsConnectionPropertiesV3">
                                        <CAHashList Enabled="true">
                                            <IssuerHash>66 99 9f 3b 10 5d 75 1c f4 6e 20 dd f2 60 69 fe 87 99 00 82 </IssuerHash>
                                        </CAHashList>
                                    </FilteringInfo>
                                </TLSExtensions>
                            </EapType>
                        </Eap>
                    </Config>
                </EapHostConfig>
            </Configuration>
        </Authentication>
        <CryptographySuite>                                 <!--VPN Algorithms used-->
        <AuthenticationTransformConstants>SHA256128</AuthenticationTransformConstants>
        <CipherTransformConstants>AES128</CipherTransformConstants>
        <EncryptionMethod>AES128</EncryptionMethod>
        <IntegrityCheckMethod>SHA256</IntegrityCheckMethod>
        <DHGroup>Group14</DHGroup>
        <PfsGroup>PFS2048</PfsGroup>
    </CryptographySuite>
    <DisableClassBasedDefaultRoute>true</DisableClassBasedDefaultRoute>     <!--VPN use Custom Routes if set to true-->
    </NativeProfile>
    <Route><Address>10.0.0.0</Address><PrefixSize>8</PrefixSize><Metric>0</Metric></Route> <!--VPN Custom Routes-->
</VPNProfile>'
#endregion

#region ---------------------------------------------------[Set global script settings]--------------------------------------------
Set-StrictMode -Version Latest
#endregion

#region ---------------------------------------------------[Static Variables]------------------------------------------------------
#Log File Info
$startTime = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$Global:ScriptName = ([io.fileinfo]$MyInvocation.MyCommand.Definition).BaseName
$Global:ScriptPath =  $MyInvocation.MyCommand.Path
$logFile = $Global:FileLogPath + "\" + $Global:ScriptName + "-" + $startTime + ".log"
$Global:Eventlog = @()
#WMI Classes
$nodeCSPURI = "./Vendor/MSFT/VPNv2"
$namespaceName = "root\cimv2\mdm\dmmap"
$className = "MDM_VPNv2_01"
#VPN related variables
$servicename = "dmwappushservice"
#XML cleanup
$ProfileNameEscaped = $Profilename -replace ' ', '%20'
$OldprofilenameEscaped = $Oldprofilename -replace ' ', '%20'
$ProfileXML = $ProfileXML -replace '<', '&lt;'
$ProfileXML = $ProfileXML -replace '>', '&gt;'
$ProfileXML = $ProfileXML -replace '"', '&quot;'
#Apps and version settings
$AppPublisher   = $company                              # The publisher of the application in Add Remove Programs
$AppFolder      = "$Env:Programfiles\$company"          # The folder for uninstallation scripts
$AppGuid  = "{65FD0F16-91BE-4346-BDA4-24BAAA2344E2}"    # Application GUID used in Add Remove Programs
$MDMPath = "HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked"
$NetworkProfilesPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles\'
$AlwaysOnInfo = 'HKLM:\SYSTEM\CurrentControlSet\Services\RasMan\config'
$AppKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$appguid"
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
    [Int32] $timeoutSeconds
    )
    $service = Get-Service $serviceName
    if ( -not $service ) {logwrite -Logstring "The service $($servicename) was not found in system." -type Error}

    if ( $service.Status -eq [ServiceProcess.ServiceControllerStatus]::Running ) {
        logwrite -Logstring "The service $($servicename) is already running in system." -type Info
        return}

    if ( $service.Starttype -eq "Disabled"){
        try {Set-Service $service.Name -StartupType Automatic}
        catch {logwrite -Logstring "The service $($servicename) could not be set to start automatically. $_" -type Warning}
        }
        $timeSpan = New-Object Timespan 0,0,$timeoutSeconds
        try {
            $service.Start()
            $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, $timeSpan)
            }
        catch [Management.Automation.MethodInvocationException],[ServiceProcess.TimeoutException] {
            logwrite -Logstring "The service $($servicename) could not be started. $_" -type Error}
    logwrite -Logstring "The service $($servicename) has started successfully" -type Info
    return
}

Function Add-AddRemovePrograms($DisplayName, $Version, $guid, $Publisher, $icon, $AppFolder){  

    logwrite -Logstring "Adding entry in Add remove programs for Always on VPN" -type Info
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
    $IconPath = "$appfolder\$IconName.ico"  
     if(!(Test-Path $AppFolder )){
        Try {New-Item -ItemType Directory -Path $AppFolder  -Force
            logwrite -Logstring "Creating program files path for uninstall script" -type Info}
        catch [Exception]{logwrite -Logstring "Cannot Creating program files path for uninstall script with error: $_" -type Warning}}
    Try {$Content = [System.Convert]::FromBase64String($icon)
        Set-Content -Path $IconPath -Value $content -Encoding Byte
        logwrite -Logstring "Copy icon to program files path" -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Copy icon to program files path with error: $_" -type Warning}

    try {copy-item $Global:ScriptPath "$AppFolder\$Global:ScriptName.ps1" -force | Out-null
        logwrite -Logstring "Copy current executing script to program files path for uninstall" -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Copy current executing script to program files path for uninstall with error: $_" -type Warning}
    $Uninstallcmd1 | Out-File -FilePath $UninstallBAT -Encoding ascii -Force
    $Uninstallcmd2 | Out-File -FilePath $UninstallBAT -Encoding ascii -Append
    Try{IF(!(Get-PSDrive HKCR -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) {New-PSDrive -PSProvider Registry -Name HKCR -Root  HKEY_CLASSES_ROOT | Out-Null}
                logwrite -Logstring "Connected to HKCR registry." -type Info}
            Catch{logwrite -Logstring "Cannot connect to HKCR registry" -type Warning}
 
    logwrite -Logstring "Adding registry entrys to Add Remove Programs for Always on VPN" -type Info   
    IF(!(Test-Path $AddRemKey)){
        Try {New-Item -Path $AddRemKey -Force | Out-Null
            logwrite -Logstring "Created Registry Path $($AddRemKey) in registry." -type Info}
        catch{logwrite -Logstring "Cannot create Registry Path $($AddRemKey) in registry" -type Warning}
        }    
    try {New-ItemProperty -Path $AddRemKey -Name DisplayName -PropertyType String -Value $displayname -Force | Out-null
        logwrite -Logstring "Created Registry key DisplayName for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key DisplayName for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $AddRemKey -Name DisplayVersion -PropertyType String -Value $Version -Force | Out-null
        logwrite -Logstring "Created Registry key DisplayVersion for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key DisplayVersion for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $AddRemKey -Name VersionMajor -PropertyType String -Value $Version.major -Force | Out-null
        logwrite -Logstring "Created Registry key VersionMajor for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key VersionMajor for Add Remove Programs with error: $_" -type Warning} 
        try {New-ItemProperty -Path $AddRemKey -Name VersionMinor -PropertyType String -Value $Version.minor -Force | Out-null
        logwrite -Logstring "Created Registry key VersionMinor for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key VersionMinor for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $AddRemKey -Name UninstallString -PropertyType String -Value $UninstallString -Force | Out-null
        logwrite -Logstring "Created Registry key UninstallString for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key UninstallString for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $AddRemKey -Name UninstallPath -PropertyType String -Value $UninstallString -Force | Out-null
        logwrite -Logstring "Created Registry key UninstallPath for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key UninstallPath for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $AddRemKey -Name Publisher -PropertyType String -Value $Publisher -Force | Out-null
        logwrite -Logstring "Created Registry key Publisher for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key Publisher for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $AddRemKey -Name Displayicon -PropertyType String -Value $IconPath -Force | Out-null
        logwrite -Logstring "Created Registry key DisplayIcon for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key DisplayIcon for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $AddRemKey -Name Comments -PropertyType String -Value $Displayname -Force | Out-null
        logwrite -Logstring "Created Registry key Comments for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key Comments for Add Remove Programs with error: $_" -type Warning}   
    try {New-ItemProperty -Path $AddRemKey -Name InstallLocation -PropertyType String -Value "c:\windows\vclogs" -Force | Out-null
        logwrite -Logstring "Created Registry key InstallLocation for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key InstallLocation for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $AddRemKey -Name NoModify -PropertyType dword -Value 1 -Force | Out-null
        logwrite -Logstring "Created Registry key NoModify for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key NoModify for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $AddRemKey -Name NoRepair -PropertyType dword -Value 1 -Force | Out-null
        logwrite -Logstring "Created Registry key NoRepair for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key NoRepair for Add Remove Programs with error: $_" -type Warning}

    IF(!(Test-Path $ProductsKey)){
        Try {New-Item -Path $ProductsKey -Force | Out-Null
            logwrite -Logstring "Created Registry Path $($ProductsKey) in registry." -type Info}
         catch{logwrite -Logstring "Cannot create Registry Path $($ProductsKey) in registry" -type Warning}
         }
    try {New-ItemProperty -Path $ProductsKey -Name ProductName -PropertyType String -Value $DisplayName -Force | Out-null
        logwrite -Logstring "Created Registry key ProductName for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key ProductName for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name ProductIcon -PropertyType String -Value $IconPath -Force | Out-null
        logwrite -Logstring "Created Registry key ProductIcon for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key ProductIcon for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name AdvertiseFlags -PropertyType dword -Value 388 -Force | Out-null
        logwrite -Logstring "Created Registry key AdvertiseFlags for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key AdvertiseFlags for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name Assignment -PropertyType dword -Value 1 -Force | Out-null
        logwrite -Logstring "Created Registry key Assignment for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key Assignment for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name AuthorizedLUAApp -PropertyType dword -Value 0 -Force | Out-null
        logwrite -Logstring "Created Registry key AuthorizedLUAApp for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key AuthorizedLUAApp for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name Clients -PropertyType MultiString  -Value (':') -Force | Out-null
        logwrite -Logstring "Created Registry key Clients for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key Clients for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name DeploymentFlags -PropertyType dword -Value 3 -Force | Out-null
        logwrite -Logstring "Created Registry key DeploymentFlags for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key DeploymentFlags for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name InstanceType -PropertyType dword -Value 0 -Force | Out-null
        logwrite -Logstring "Created Registry key InstanceType for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key InstanceType for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey -Name Language -PropertyType dword -Value 1033 -Force | Out-null
        logwrite -Logstring "Created Registry key Language for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key Language for Add Remove Programs with error: $_" -type Warning}
    IF(!(Test-Path $ProductsKey\Sourcelist)){
        Try {New-Item -Path $ProductsKey\Sourcelist -Force | Out-Null
            logwrite -Logstring "Created Registry Path $($ProductsKey)\Sourcelist in registry." -type Info}
         catch{logwrite -Logstring "Cannot create Registry Path $($ProductsKey)\Sourcelist in registry" -type Warning}
         }
    try {New-ItemProperty -Path $ProductsKey\Sourcelist -Name LastUsedSource -PropertyType ExpandString -Value "n;1;$($appfolder)\" -Force | Out-null
        logwrite -Logstring "Created Registry key LastUsedSource for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key LastUsedSource for Add Remove Programs with error: $_" -type Warning}
    try {New-ItemProperty -Path $ProductsKey\Sourcelist -Name PackageName -PropertyType String -Value "uninstall-$($guid).bat" -Force | Out-null
        logwrite -Logstring "Created Registry key PackageName for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key PackageName for Add Remove Programs with error: $_" -type Warning}
    IF(!(Test-Path $ProductsKey\sourcelist\media)){
        Try {New-Item -Path $ProductsKey\Sourcelist\media -Force | Out-Null
            logwrite -Logstring "Created Registry Path $($ProductsKey)\Sourcelist\media in registry." -type Info}
         catch{logwrite -Logstring "Cannot create Registry Path $($ProductsKey)\Sourcelist\media in registry" -type Warning}
         }
    try {New-ItemProperty -Path $ProductsKey\Sourcelist\media -Name 1 -PropertyType String -Value ";" -Force | Out-null
        logwrite -Logstring "Created Registry key 1 for Add Remove Programs." -type Info}
    catch [Exception]{logwrite -Logstring "Cannot Created Registry key 1 for Add Remove Programs with error: $_" -type Warning}
    IF(!(Test-Path $ProductsKey\Sourcelist\Net)){
        Try {New-Item -Path $ProductsKey\Sourcelist\Net -Force | Out-Null
            logwrite -Logstring "Created Registry Path $($ProductsKey)\Sourcelist\net in registry." -type Info}
         catch{logwrite -Logstring "Cannot create Registry Path $($ProductsKey)\Sourcelist\net in registry" -type Warning}
         }
    try {New-ItemProperty -Path $ProductsKey\Sourcelist\Net -Name 1 -PropertyType ExpandString -Value "$($appfolder)\" -Force | Out-null
        logwrite -Logstring "Created Registry key 1 for Add Remove Programs." -type Info}
        catch [Exception]{logwrite -Logstring "Cannot Created Registry key 1 for Add Remove Programs with error: $_" -type Warning}

    remove-psdrive -name HKCR 
 }

 Function Remove-AddRemovePrograms($DisplayName, $Version, $guid, $AppFolder){  

    logwrite -Logstring "Removing entry in Add remove programs for Always on VPN" -type Info
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
                logwrite -Logstring "Connected to HKCR registry." -type Info}
            Catch{logwrite -Logstring "Cannot connect to HKCR registry" -type Warning}

    IF(Test-Path $AddRemKey){
        Try{Remove-Item -Path $AddRemKey -ErrorAction SilentlyContinue -Force | Out-null
            logwrite -Logstring "Removed Registry hive $($AddRemKey) from registry." -type Info}
        catch {logwrite -Logstring "Cannot remove Registry hive $($AddRemKey) from registry." -type Warning}
        }
    else{logwrite -Logstring "Registry key $($AddRemKey) does not exist in User registry, no need to remove." -type Warning}

    IF(Test-Path $ProductsKey){
        Try{Remove-Item -Path $ProductsKey -ErrorAction SilentlyContinue -Force -Recurse | Out-null
            logwrite -Logstring "Removed Registry hive $($ProductsKey) from registry." -type Info}
        catch {logwrite -Logstring "Cannot remove Registry hive $($ProductsKey) from registry." -type Warning}
        }
    else{logwrite -Logstring "Registry key $($ProductsKey) does not exist in User registry, no need to remove." -type Warning}

    if(Test-Path $AppFolder ){
        $Otherfiles = Get-ChildItem $AppFolder -recurse -exclude "$Global:ScriptName.ps1", "uninstall-$guid.bat", $Iconfile
        if ($otherfiles)
            {logwrite -Logstring "Program files folder not empty, cannot delete folder" -type Warning
            Try{Remove-Item "$appfolder\$Global:ScriptName.ps1" -force
                logwrite -Logstring "Removed script $($Global:ScriptName).ps1 from $($appfolder)." -type Info}
            catch {logwrite -Logstring "Cannot Remove script $($Global:ScriptName).ps1 from $($appfolder)." -type Warning}
            Try{Remove-Item "$appfolder\$IconFile" -force
                logwrite -Logstring "Removed script $($IconFile) from $($appfolder)." -type Info}
            catch {logwrite -Logstring "Cannot Remove script $($IconFile) from $($appfolder)." -type Warning}
            Try{Remove-Item "$appfolder\uninstall-$guid.bat" -force
                logwrite -Logstring "Removed script uninstall-$($guid).bat from $($appfolder)." -type Info}
            catch {logwrite -Logstring "Cannot Remove script uninstall-$($guid).bat from $($appfolder)." -type Warning}
            }
        else {Try {Get-ChildItem -Path "$Appfolder\\*" -Recurse | Remove-Item -Force -Recurse
                    Remove-Item $appfolder -force
            logwrite -Logstring "Removing program files path for uninstall script" -type Info}
        catch [Exception]{logwrite -Logstring "Cannot Remove program files path for uninstall script with error: $_" -type Warning}}}

        remove-psdrive -name HKCR 
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
    logwrite -Logstring "Enumerated Username to $($username)." -type info}
    catch [Exception] {logwrite -Logstring "Unable to get logged on Username. User may be logged on over Remote Desktop. $_" -type Warning}
        # The VPN connection is created for the end user logged on to the computer. Enumeration of currently logged on user SID
    if (!$username){
    Try {New-PSDrive HKU Registry HKEY_USERS -ErrorAction Continue | out-null
        logwrite -Logstring "Create psdrive to HKU"}
    Catch{logwrite -Logstring "Create psdrive to HKCU with error $_" -type Error}
        try {
            $users = query user /server:localhost
            $Users = $Users | ForEach-Object {(($_.trim() -replace ">" -replace "(?m)^([A-Za-z0-9]{3,})\s+(\d{1,2}\s+\w+)", '$1  none  $2' -replace "\s{2,}", "," -replace "none", $null))} | ConvertFrom-Csv
            foreach ($User in $Users){
                if ($User.STATE -eq "Active")
                {
                $RDPUser = $User.username}
                }
            logwrite -Logstring "Enumerated Username to $($username)." -type info}
        catch [Exception] {logwrite -Logstring "Unable to get logged on Username from RDP sessions. Script cannot continue. $_" -type Error}

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
    logwrite -Logstring "Enumerated Username to $($username)." -type info

    try {
        $domain, $logonname = $username.tostring().split('\') 
        $objuser = New-Object System.Security.Principal.NTAccount($username)
        $sid = $objuser.Translate([System.Security.Principal.SecurityIdentifier])
        $SidValue = $sid.Value
        }
        catch [Exception] {logwrite -Logstring "Unable to get user SID from Username. Script cannot continue. $_" -type Error}
        return $logonname, $SidValue
    }


#endregion

#region ---------------------------------------------------[[Script Execution]------------------------------------------------------
logwrite -Logstring "Starting script $($Global:ScriptName) with $($InstallType) option set" -type Start

            # Verify Minimum Windows Version
logwrite -Logstring "Make sure script is only executed on a required minimum version of Windows 10" -type Info
If (((Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name Currentbuild).Currentbuild) -ge $MinWinBuild){
    logwrite -Logstring "Windows 10 is running a compatible version" -type Info

            # Check Always On VPN config version in Add Remove Program registry
    logwrite -Logstring "Getting the current config version from registry" -type Info
    IF(Test-Path $AppKey){
        Try{[version]$CurrentVersion = (Get-ItemProperty -Path $AppKey -Name DisplayVersion -ErrorAction SilentlyContinue).DisplayVersion
            logwrite -Logstring "Currentversion from registry is $($CurrentVersion)" -type Info}
        catch{logwrite -Logstring "Unable to read Currentversion from registry, setting 0.0.0.0 as version" -type Info
            [version]$currentversion = "0.0.0.0"}}
    else {logwrite -Logstring "Currentversion is missing in registry, setting 0.0.0.0 as version" -type Info
        [version]$currentversion = "0.0.0.0"}

    if ([version]$CurrentVersion -lt [version]$ConfigVersion -or $InstallType -eq "Reinstall"-or $InstallType -eq "Uninstall"){
        logwrite -Logstring "Always On VPN is installed with version: $($currentversion), script has version: $($configversion), installtype is $($installtype)," -type Info

                # The VPN connection is created for the end user logged on to the computer. Enumeration of currently logged on user SID
                # To be able to create a connection for the end user, the script needs to run as System or as admin with the logged on user credentials
                $logonname, $sidvalue = Get-LoggedInUser
                if ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18"){logwrite -Logstring "The script is running as admin with the SYSTEM credentials" -type Info}
                elseif ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq $SidValue){logwrite -Logstring "The script is running as admin with the current user credentials" -type Info}
                else {logwrite -Logstring "The script is running as admin but with wrong credentials. Must run as admin with the logged on user credentials, or run as System" -type Error}

                # Set WAP Push Service to start automatically 
        enable-Service $servicename 10

                # The VPN is created and deleted via CSP over WMI Bridge. 
        logwrite -Logstring "Connect CSP over WMI Bridge" -type Info
        try {
            $session = New-CimSession
            $options = New-Object Microsoft.Management.Infrastructure.Options.CimOperationOptions
            $options.SetCustomOption("PolicyPlatformContext_PrincipalContext_Type", "PolicyPlatform_UserContext", $false)
            $options.SetCustomOption("PolicyPlatformContext_PrincipalContext_Id", "$SidValue", $false)
            logwrite -Logstring "Connected CSP over WMI bridge"}
        catch [Exception] {
            logwrite -Logstring "Unable to connect CSP over WMI bridge. $_" -type Error}

                # If there is an existing VPN tunnel with the same name already deployed, It must be removed before creating a new config. 
                try {rasdial $Oldprofilename /disconnect |out-null
                    logwrite -Logstring "VPN Tunnel $($Oldprofilename) Disconnected" -type Info}
                catch [Exception] {logwrite -Logstring "VPN Tunnel $($Oldprofilename) failed to Disconnect" -type Info}
                try {rasdial $profilename /disconnect |out-null
                    logwrite -Logstring "VPN Tunnel $($profilename) Disconnected" -type Info}
                catch [Exception] {logwrite -Logstring "VPN Tunnel $($profilename) failed to Disconnect" -type Info}
        
                try {$deleteInstances = $session.EnumerateInstances($namespaceName, $className, $options)}
        catch [Exception] {logwrite -Logstring "No existing User Tunnel was found." -type Info}
        if (-not (test-path variable:deleteinstances)){
        	foreach ($deleteInstance in $deleteInstances){
            	$InstanceId = $deleteInstance.InstanceID
                logwrite -Logstring "User Tunnel $($instanceid) exist on device" -type Info
                if ($InstanceId -like $OldprofilenameEscaped -or $InstanceId -eq $ProfileNameEscaped){
                	try {$session.DeleteInstance($namespaceName, $deleteInstance, $options)}
                    catch [Exception] {logwrite -Logstring "Unable to remove existing User Tunnel $($InstanceId): $_" -type Error}
                	logwrite -Logstring "User Tunnel $($InstanceId) Removed" -type Info
                	} 
                else {logwrite -Logstring "Ignoring existing VPN User Tunnel $($InstanceId)" -type Info}
       		    }
            }
            else {logwrite -Logstring "No existing VPN Tunnel existed for CSP over WMI, trying Powershell" -type Info
		    if ($deleteInstance = get-vpnconnection -alluserconnection -name "$profilename" -ErrorAction SilentlyContinue){
         	    try {$deleteInstance| remove-vpnconnection -force
                    logwrite -Logstring "VPN Device Tunnel $($profilename) Removed" -type Info}
                catch [Exception] {logwrite -Logstring "Unable to remove existing VPN Tunnel $($profilename) with powershell: $_" -type Error}}
            elseif ($deleteInstance = get-vpnconnection -name "$profilename" -ErrorAction SilentlyContinue){
                try {$deleteInstance| remove-vpnconnection -force
                    logwrite -Logstring "VPN User Tunnel $($profilename) Removed" -type Info}
                catch [Exception] {logwrite -Logstring "Unable to remove existing VPN Tunnel $($profilename) with powershell: $_" -type Error}}
            else {logwrite -Logstring "No existing VPN Tunnel with same name existed for Powershell" -type Info}
            if ($oldprofilename -and ($deleteInstance = get-vpnconnection -alluserconnection -name "$oldprofilename" -ErrorAction SilentlyContinue)){
                try {$deleteInstance| remove-vpnconnection -force
                   logwrite -Logstring "VPN Device Tunnel $($oldprofilename) Removed" -type Info}
               catch [Exception] {logwrite -Logstring "Unable to remove existing VPN Tunnel $($oldprofilename) with powershell: $_" -type Error}}
           elseif ($deleteInstance = get-vpnconnection -name "$oldprofilename" -ErrorAction SilentlyContinue){
               try {$deleteInstance| remove-vpnconnection -force
                   logwrite -Logstring "VPN User Tunnel $($oldprofilename) Removed" -type Info}
               catch [Exception] {logwrite -Logstring "Unable to remove existing VPN Tunnel $($oldprofilename) with powershell: $_" -type Error}}
           else {logwrite -Logstring "No existing VPN Tunnel with old name existed for Powershell" -type Info}
            }

            # Remove old MDM tracked setting
        Try {$MDMSettings = Get-ChildItem -Path $MDMPath -Recurse -Depth 3 | get-itemproperty | where { $_  -match  "$ProfileNameEscaped"}}
        Catch {logwrite -Logstring "No old MDM Tracking found in registry";$MDMsettings=$null}
        If ($MDMsettings) {Try {$MDMsettings | Remove-Item
            logwrite -Logstring "Found old MDM Tracking, removed from registry" -type Info}
            catch{logwrite -Logstring "Found old MDM Tracking, unable to remove from registry" -type warning}}
        Else {logwrite -Logstring "No old MDM Tracking found in registry"}

            # Remove old VPN NetworkList Profiles
        Try {$NetworkProfile = Get-Childitem -Path $NetworkProfilesPath | Where {(Get-ItemPropertyValue $_.PsPath -Name Description) -eq $ProfileName}}
        Catch {logwrite -Logstring "No old NetworkList found in registry";$NetworkProfile=$null}
        If ($NetworkProfile) {Try {$NetworkProfile | Remove-Item
            logwrite -Logstring "Found old NetworkList, removed from registry" -type Info}
            catch{logwrite -Logstring "Found old NetworkList, unable to remove from registry" -type warning}}
        Else {logwrite -Logstring "No old NetworkList found in registry"}

            # Remove old VPN fron disabled autoconnect list
            Try {[string[]]$DisabledProfiles = Get-ItemPropertyValue -Path $AlwaysOnInfo -Name AutoTriggerDisabledProfilesList -ErrorAction SilentlyContinue}
        Catch {logwrite -Logstring "No old disabled autoconnect VPN found in registry";$DisabledProfiles=$null}
        If ($DisabledProfiles) {
            $DisabledProfilesList = [Ordered]@{}
            $DisabledProfiles | ForEach-Object { $DisabledProfilesList.Add("$($_.ToLower())", $_) }
            If ($DisabledProfilesList.Contains($ProfileName)) {
                $DisabledProfilesList.Remove($ProfileName)
                try{Set-ItemProperty -Path $AlwaysOnInfo -Name AutoTriggerDisabledProfilesList -Value $DisabledProfilesList.Values
                    logwrite -Logstring "Removed old disabled autoconnect VPN from registry" -type Info}
                Catch {logwrite -Logstring "Failed to Remove old disabled autoconnect VPN from registry"}
            }
        }
        Else {logwrite -Logstring "No old disabled autoconnect VPN found in registry"}
        
                # Create the new Always on VPN connection. This uses CSP over WMI bridge
        if ($InstallType -eq "install" -or $installtype -eq "reinstall"){
            try {
                $NewInstance = New-Object Microsoft.Management.Infrastructure.CimInstance $ClassName, $NamespaceName
                $Property = [Microsoft.Management.Infrastructure.CimProperty]::Create('ParentID', "$nodeCSPURI", 'String', 'Key')
                $NewInstance.CimInstanceProperties.Add($Property)
                $Property = [Microsoft.Management.Infrastructure.CimProperty]::Create('InstanceID', "$ProfileNameEscaped", 'String', 'Key')
                $NewInstance.CimInstanceProperties.Add($Property)
                $Property = [Microsoft.Management.Infrastructure.CimProperty]::Create('ProfileXML', "$ProfileXML", 'String', 'Property')
                $NewInstance.CimInstanceProperties.Add($Property)
                $session.CreateInstance($namespaceName, $newInstance, $options)
                logwrite -Logstring "Created VPN Profile $($ProfileNameEscaped) named $($ProfileName)." -type Info
                }
            catch [Exception] {logwrite -Logstring "Unable to create VPN Profile $($ProfileNameEscaped) named $($ProfileName) with error: $_" -type Error}

            IF(Test-Path $AlwaysOnInfo){
                Try{$RasPhone = (Get-ItemProperty -Path $AlwaysOnInfo -Name AutoTriggerProfilePhonebookPath -ErrorAction SilentlyContinue).AutoTriggerProfilePhonebookPath
                    logwrite -Logstring "Found Path for PBX file: $($RasPhone)" -type Info}
                catch{logwrite -Logstring "Unable to Find Path for PBX file, setting default" -type warning
                    $RasPhone = "C:\ProgramData\Microsoft\Network\Connections\Pbk\rasphone.pbk"}
                    }    
                else {logwrite -Logstring "Unable to Find Path for PBX file, setting default" -type warning
                    $RasPhone = "C:\ProgramData\Microsoft\Network\Connections\Pbk\rasphone.pbk"}
            IF(Test-Path $RasPhone){
                    # Change VPN tunnel adapter priority for better DNS resolution
                try{Set-PBKKey $RasPhone $ProfileName "IpInterfaceMetric" $RasNicMetric
                    logwrite -Logstring "Change RasNicMetric in PBK to $($RasNicMetric)." -type Info} 
                catch [Exception] {logwrite -Logstring "Unable to change RasNicMetric in PBK with error: $_" -type Warning}
                try{Set-PBKKey $RasPhone $ProfileName "Ipv6InterfaceMetric" $RasNicMetricIPv6
                    logwrite -Logstring "Change RasNicMetric IPV6 in PBK to $($RasNicMetricIPv6)." -type Info} 
                catch [Exception] {logwrite -Logstring "Unable to change RasNicMetric IPV6 in PBK with error: $_" -type Warning}

                # Change VPN tunnel protocol 
                try{Set-PBKKey $RasPhone $ProfileName "VpnStrategy" $VpnStrategy
                    logwrite -Logstring "Change VpnStrategy in PBK to $($VpnStrategy)." -type Info} 
                catch [Exception] {logwrite -Logstring "Unable to change VpnStrategy in PBK with error: $_" -type Warning}

                 # Change VPN mobility setting 
                try{Set-PBKKey $RasPhone $ProfileName "DisableMobility" $DisableMobility
                    logwrite -Logstring "Change DisableMobility in PBK to $($DisableMobility)." -type Info} 
                catch [Exception] {logwrite -Logstring "Unable to change DisableMobility in PBK with error: $_" -type Warning}

                # Change VPN mobility timeout 
                try{Set-PBKKey $RasPhone $ProfileName "NetworkOutageTime" $NetworkOutageTime
                    logwrite -Logstring "Change NetworkOutageTime in PBK to $($NetworkOutageTime)." -type Info} 
                    catch [Exception] {logwrite -Logstring "Unable to change NetworkOutageTime in PBK with error: $_" -type Warning}

                # Change VPN reuse of credentials
                try{Set-PBKKey $RasPhone $ProfileName "UseRasCredentials" $UseRasCredentials
                   logwrite -Logstring "Change UseRasCredentials in PBK to $($UseRasCredentials)." -type Info} 
                catch [Exception] {logwrite -Logstring "Unable to change UseRasCredentials in PBK with error: $_" -type Warning}
                }
            else {logwrite -Logstring "Unable to Find PBX file" -type warning}

                #Add regkey for a more reliable DNS registration
            try {New-ItemProperty -Path 'HKLM:SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\' -Name DisableNRPTForAdapterRegistration -PropertyType DWORD -Value 1 -Force | Out-null
                logwrite -Logstring "Created Registry key DisableNRPTForAdapterRegistration for a more reliable DNS registration." -type Info}
            catch [Exception]{logwrite -Logstring "Cannot create Registry key DisableNRPTForAdapterRegistration with error: $_" -type Warning}
                # Register or unregister in Add Remove Programs for Version and uninstallation info
            if ($AddRemoveProgramEnabled) {Add-AddRemovePrograms $ProfileName $ConfigVersion $AppGuid $AppPublisher $AppIcon $AppFolder}
                # Connect the vpn
                try {rasdial $profilename | out-null
                    logwrite -Logstring "VPN Tunnel $($profilename) connected" -type Info}
                catch [Exception] {logwrite -Logstring "VPN Tunnel $($profilename) failed to connect" -type Info}
            }
            # Remove Always On VPN config version in registry if installtype is Uninstall
        if ($InstallType -eq "UnInstall"){if ($AddRemoveProgramEnabled) {Remove-AddRemovePrograms $ProfileName $ConfigVersion $AppGuid $appfolder}}
    }
    else {logwrite -Logstring "Always On VPN is already running version $($currentversion) and need no update to scriptversion $($configversion)" -type Info}
}
else {logwrite -Logstring "Windows 10 is not running a compatible version" -type Warning}

Set-StrictMode -Off
logwrite -Logstring "Script finished successfully" -type End
#endregion
