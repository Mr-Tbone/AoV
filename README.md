# Always On VPN in Add Remove Programs with PowerShell

I have done lots of Always On VPN implementations. I mostly try to use Intune configuration profile, but sometimes it´s not possible. So many customers also need an additional way of deploying the configuration. So I have done a quite complex PowerShell script for deploying AoV. My last addition to the script is to add the connection in Add Remove Programs. Quite useful, so why not share with others that need it. 

The script uses the technique described by Microsoft on Docs: Configure Windows 10 client Always On VPN connections but I have added some nice functions. This technique uses CSP over WMI to add the VPN in a similar way as Intune. The device tunnel script must be run under System context to successfully build a device tunnel that connect as System before login.

Windows 11 has some issues with the CSP and VPN_v2. So this script will fail on some older Windows 11 versions.

# Reinstall/Uninstall

The script has three modes: Install, Reinstall and Uninstall. The default is Install, it will install the VPN if missing and update if an old version. If run on a computer with same version it will exit without actions. But what if the VPN has some error and you need to manually update the config. Then it can be reinstalled with the Reinstall switch. And if the VPN connection needs to be removed, just use the uninstall option.

#region ---------------------------------------------------[Script Parameters]-------------------------------------
Param(

    [Parameter(HelpMessage = 'Enter Install, ReInstall or UnInstall.')]    
    [validateset("Install", "ReInstall", "UnInstall")][string]$InstallType = "Install"
)
#endregion

# Modifiable Variables

I have some modifiable variables to customize the deployment and VPN configuration. The VPN connection itself is formed in the default XML way. Had some ideas on using variables, but Always On VPN is often formed in that way, so this is probably the easiest way of customizing. Make sure you go through this part and customize it for your environment.

#region ---------------------------------------------------[Modifiable Parameters and defaults]--------------------
#Customizations
$Company = "Coligo"    #Used in VPN ProfileName and registry keys

#Version info
[version]$ConfigVersion   = "1.0.2202.1" #Increment when changing config, stored in registry to check if new config is needed. syntax: 1.1.YYMM.Version (1.1.2001.1)
$AddRemoveProgramEnabled  = $True        #$true register an App in Add Remove Programs for version and uninstall, $false skip registration in Add Remove Programs
$MinWinBuild              = 17763        #17763 will require Windows 1809 to execute

#Log settings
$Global:GuiLogEnabled   = $False       #$true for test of script in manual execution
....

# Add Remove Programs

As mentioned before the script will also register in Add Remove Programs with it´s name and version. This is quite nice, then it can be inventoried as any other application installed. This info is also used if the script is updated with a new version or if it is running in reinstall mode. The most tricky part with this was the uninstall part. I have not been able to completely uninstall the device tunnel from add remove programs. The uninstallation will run under the logged in user context and needs to be run in System context. Will continue to search for a solution for this.

# Logging

I have built my own logging function that will write to GUI, Event Viewer or File. Whatever the customer prefer. I use the same function it in many of my scripts and it works really good on all targets so far. The GUI logging is mostly used when testing the script, if disabled it will run silent.

# INI file update

The script also searches for the INI file (rasphone.pbk) that the VPN connection created. This INI file can sometimes end up in other location than default. Thereby I use some regkeys to try find the path so I can edit the correct file. I have added the settings that sometimes need optimization for Always On VPN.
