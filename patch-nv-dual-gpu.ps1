<#
.SYNOPSIS
  One-click setup of a GeForce GPU (RTX 2060) next to a Tesla/Quadro datacenter
  GPU (Tesla V100) on ONE Windows machine, under ONE datacenter driver.

.DESCRIPTION
  Windows loads exactly ONE nvlddmkm.sys kernel module per system. A Tesla card
  is served only by the datacenter driver branch; a GeForce card is not listed
  in the datacenter INF, so Windows leaves it in Code 31/43 (or binds it to an
  old Game Ready package whose nvlddmkm.sys version conflicts with the loaded
  one). This tool keeps the working datacenter driver and teaches its INF to
  claim the GeForce hardware ID:

    1. copy the live WHQL datacenter driver package out of the DriverStore
    2. add the GeForce hardware ID to the same INF section as a same-chip-family
       datacenter card (Turing T4 donor for the RTX 2060) + add the [Strings] entry
    3. rebuild the .cat catalog (WDK makecat) under the exact name the INF expects
    4. sign the catalog with a local two-level chain: self-signed CA root
       (CA=true, published to Root/TrustedPublisher/CA) -> leaf cert (CA=false,
       EKU Kernel Mode Code Signing + Code Signing, published to TrustedPublisher)
    5. enable test signing (required: a self-signed catalog can never satisfy
       Microsoft's kernel driver signature enforcement)
    6. reboot, then pnputil /add-driver ... /install + verify

  The tool is self-driving: the .cmd launcher elevates, Prep phase patches and
  reboots, a one-shot SYSTEM scheduled task finishes the install after reboot.

.PARAMETER Phase
  Prep     - patch + sign + testsigning + reboot (default)
  Install  - runs automatically after reboot
  Verify   - show both GPUs, driver version, error codes
  Revert   - remove modded package + certs, testsigning off
  DryRun   - locate source package and patch the INF into a temp dir only;
             no certs, no bcdedit, no scheduled task, no reboot

.EXAMPLE
  .\patch-nv-dual-gpu.cmd
  powershell -File .\patch-nv-dual-gpu.ps1 -Phase DryRun
  powershell -File .\patch-nv-dual-gpu.ps1 -Phase Revert

.NOTES
  UNSUPPORTED by NVIDIA and Microsoft. Create a restore point first.
  V100-class (Volta) is frozen on the 580 driver branch; a future GeForce-only
  driver update can break this setup.
#>

[CmdletBinding()]
param(
  [ValidateSet('Prep','Install','Verify','Revert','DryRun')]
  [string]$Phase = 'Prep',

  # GeForce card to enable (RTX 2060 on this box)
  [string]$TargetHwid = 'PCI\VEN_10DE&DEV_1F03&SUBSYS_886D1043',
  [string]$TargetName = 'NVIDIA GeForce RTX 2060',

  # Datacenter card of the same chip family already present in the INF
  # (Turing Tesla T4 -> TU106, same silicon family as RTX 2060)
  [string]$DonorHwid  = 'DEV_1EB8',

  # Marker of the live datacenter package (Tesla V100)
  [string]$AnchorHwid = 'DEV_1DB6',

  [string]$WorkDir = 'E:\AI\nv_dualgpu',
  [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'
$CA_SUBJECT   = 'CN=Hermes Test Root CA'
$LEAF_SUBJECT = 'CN=Hermes NV Mod Signing'
$TASK_NAME    = 'HermesNvDualGpuInstall'

function Write-Step($m) { Write-Host "=== $m ===" -ForegroundColor Cyan }

function Need-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Not elevated. Use patch-nv-dual-gpu.cmd (it self-elevates).'
  }
}

function Find-WdkTool([string]$name) {
  $hit = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter $name -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -like '*\x64\*' } | Select-Object -First 1
  if ($hit) { return $hit.FullName }
  return $null
}

function Get-HwidParts([string]$hwid) {
  $ven = if ($hwid -match 'VEN_([0-9A-Fa-f]{4})') { $matches[1].ToUpper() } else { '10DE' }
  $dev = if ($hwid -match 'DEV_([0-9A-Fa-f]{4})') { $matches[1].ToUpper() } else { throw "No DEV_ in HWID '$hwid'" }
  $sub = if ($hwid -match 'SUBSYS_([0-9A-Fa-f]{8})') { $matches[1].ToUpper() } else { $null }
  return @{ Ven=$ven; Dev=$dev; Sub=$sub }
}

function Find-SourcePackage {
  # Live datacenter package = nv_disp*.inf that contains the Tesla anchor and
  # does NOT already contain the target GeForce device id.
  Write-Step 'Locate live datacenter driver package'
  $targetDev = (Get-HwidParts $TargetHwid).Dev
  $root = 'C:\Windows\System32\DriverStore\FileRepository'
  foreach ($d in (Get-ChildItem $root -Directory | Where-Object { $_.Name -like 'nv_disp*' })) {
    $inf = Get-ChildItem $d.FullName -Filter 'nv_disp*.inf' | Select-Object -First 1
    if (-not $inf) { continue }
    $txt = Get-Content $inf.FullName -Raw
    if ($txt -match [regex]::Escape($AnchorHwid) -and $txt -notmatch "DEV_$targetDev") {
      Write-Host ("  source: " + $d.Name)
      return [pscustomobject]@{ Dir=$d.FullName; Inf=$inf.FullName }
    }
  }
  throw "No datacenter package containing $AnchorHwid found. Is the datacenter driver (580 branch) installed?"
}

function Patch-Inf([string]$srcInf, [string]$dstInf) {
  Write-Step 'Patch INF: GeForce HWID -> donor (same-family) section'
  $p = Get-HwidParts $TargetHwid
  # NVIDIA token convention: NVIDIA_DEV.<dev>.<subsys-device>.<subsys-vendor>
  # SUBSYS_886D1043 -> subsys-device 886D, subsys-vendor 1043.
  if ($p.Sub) {
    $subDev = $p.Sub.Substring(0,4)
    $subVen = $p.Sub.Substring(4,4)
    $token = "NVIDIA_DEV.$($p.Dev).$subDev.$subVen"
  } else {
    $token = "NVIDIA_DEV.$($p.Dev)"
  }
  $lines = Get-Content $srcInf
  $out = New-Object System.Collections.Generic.List[string]
  $section = $null
  foreach ($L in $lines) {
    $out.Add($L)
    if (-not $section -and $L -match [regex]::Escape($DonorHwid) -and $L -match '=\s*(Section\d+)\s*,') {
      $section = $matches[1]
      $out.Add("%$token% = $section, $TargetHwid")
    }
  }
  if (-not $section) { throw "Donor $DonorHwid not found in $srcInf - pick a -DonorHwid of the same chip family." }
  $res = New-Object System.Collections.Generic.List[string]
  $added = $false
  foreach ($L in $out) {
    $res.Add($L)
    if (-not $added -and $L.Trim() -match '^\[Strings\]') { $res.Add("$token = `"$TargetName`""); $added = $true }
  }
  if (-not $added) { throw '[Strings] section not found.' }
  [IO.File]::WriteAllText($dstInf, ($res -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
  Write-Host ("  section=$section  token=$token")
  Write-Host ("  device: %$token% = $section, $TargetHwid")
  return $section
}

function New-TestCertChain {
  Write-Step 'Create test certificate chain (CA root -> KMCS leaf)'
  foreach ($st in 'My','Root','TrustedPublisher','CA') {
    $s = New-Object System.Security.Cryptography.X509Certificates.X509Store($st,'LocalMachine')
    $s.Open('ReadWrite')
    foreach ($c in @($s.Certificates | Where-Object { $_.Subject -eq $CA_SUBJECT -or $_.Subject -eq $LEAF_SUBJECT })) {
      $s.Remove($c) | Out-Null
    }
    $s.Close()
  }
  $ca = New-SelfSignedCertificate -CertStoreLocation 'Cert:\LocalMachine\My' -Type Custom `
        -Subject $CA_SUBJECT -FriendlyName 'HermesTestRootCA' `
        -KeyUsage CertSign,CrlSign,DigitalSignature -KeyExportPolicy Exportable `
        -HashAlgorithm SHA256 -KeyLength 2048 -NotAfter (Get-Date).AddYears(5) `
        -TextExtension @('2.5.29.19={text}CA=true')
  $leaf = New-SelfSignedCertificate -CertStoreLocation 'Cert:\LocalMachine\My' -Type Custom `
        -Subject $LEAF_SUBJECT -FriendlyName 'HermesNVModLeaf' -Signer $ca `
        -KeyUsage DigitalSignature -KeyExportPolicy Exportable `
        -HashAlgorithm SHA256 -KeyLength 2048 -NotAfter (Get-Date).AddYears(5) `
        -TextExtension @('2.5.29.19={text}CA=false','2.5.29.37={text}1.3.6.1.4.1.311.10.3.5,1.3.6.1.5.5.7.3.3')

  $caPub = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,$ca.RawData)
  foreach ($st in 'Root','TrustedPublisher','CA') {
    $s = New-Object System.Security.Cryptography.X509Certificates.X509Store($st,'LocalMachine')
    $s.Open('ReadWrite'); $s.Add($caPub); $s.Close()
  }
  $leafPub = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,$leaf.RawData)
  $tp = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher','LocalMachine')
  $tp.Open('ReadWrite'); $tp.Add($leafPub); $tp.Close()

  Write-Host ("  CA   : " + $ca.Thumbprint)
  Write-Host ("  LEAF : " + $leaf.Thumbprint)
}

function Build-Sign-Catalog([string]$pkgDir) {
  Write-Step 'Rebuild and sign the catalog'
  $inf = Get-ChildItem $pkgDir -Filter 'nv_disp*.inf' | Select-Object -First 1
  $catName = $null
  foreach ($L in (Get-Content $inf.FullName)) {
    if ($L -match '^\s*CatalogFile\s*=\s*(\S+)') { $catName = $matches[1].Trim(); break }
  }
  if (-not $catName) { $catName = 'NV_DISP.CAT' }
  Get-ChildItem $pkgDir -Filter '*.cat' | Remove-Item -Force

  $makecat = Find-WdkTool 'makecat.exe'
  if (-not $makecat) { throw 'makecat.exe not found. Install the Windows Driver Kit (WDK 10).' }

  $rel = Get-ChildItem $pkgDir -Recurse -File |
         Where-Object { $_.Extension -notin '.cat','.pfx','.cdf' } |
         ForEach-Object { $_.FullName.Substring($pkgDir.Length + 1) }
  $cdf  = "[CatalogHeader]`r`nName=$catName`r`nPublicVersion=0x1`r`nEncodingType=SPC_LINK`r`n`r`n[CatalogFiles]`r`n"
  $cdf += ($rel | ForEach-Object { "<hash>$_=$_" }) -join "`r`n"
  $cdfPath = Join-Path $pkgDir 'nv_dualgpu.cdf'
  [IO.File]::WriteAllText($cdfPath, $cdf, [Text.Encoding]::ASCII)

  Push-Location $pkgDir
  try { & $makecat $cdfPath 2>&1 | Select-Object -Last 1 | ForEach-Object { Write-Host ("  makecat: " + $_) } }
  finally { Pop-Location }

  $catPath = Join-Path $pkgDir $catName
  if (-not (Test-Path $catPath)) { throw "makecat did not produce $catName" }

  $leaf = Get-ChildItem 'Cert:\LocalMachine\My' | Where-Object { $_.Subject -eq $LEAF_SUBJECT } | Select-Object -First 1
  if (-not $leaf) { throw 'Leaf certificate missing.' }
  $r = Set-AuthenticodeSignature -FilePath $catPath -Certificate $leaf
  Write-Host ("  catalog=$catName signature=" + $r.Status)
  if ($r.Status -ne 'Valid') { throw "Catalog signing failed: $($r.StatusMessage)" }
  return $inf.FullName
}

function Set-HvciCheck {
  Write-Step 'Check kernel integrity settings'
  $hvci = $null
  try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace 'root\Microsoft\Windows\Security' -ErrorAction Stop
    $hvci = $dg.KernelModeCodeIntegrityPolicyEnforcementStatus
    Write-Host ("  KernelModeCodeIntegrity (0=off,2=on): " + $hvci)
  } catch { Write-Host '  DeviceGuard query unavailable' }
  $ts = (bcdedit | Select-String 'testsigning') -ne $null
  Write-Host ("  testsigning currently: " + [bool]$ts)
  if ($hvci -eq 2) {
    Write-Warning 'Memory integrity / HVCI is ON: test-signed drivers cannot load. Turn it off (Windows Security -> Core isolation) or this will fail.'
  }
}

function Register-PostRebootTask {
  Write-Step 'Register one-shot post-reboot install task (SYSTEM)'
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $script = $PSCommandPath
  $tr = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$script`" -Phase Install"
  schtasks /create /tn $TASK_NAME /tr $tr /sc ONSTART /ru SYSTEM /rl HIGHEST /f |
    Out-String -Stream | ForEach-Object { Write-Host ("  " + $_) }
}

function Do-DryRun {
  Need-Admin
  $src = Find-SourcePackage
  $tmp = Join-Path $env:TEMP ('nv_dualgpu_dryrun_' + (Get-Date -Format yyyyMMddHHmmss))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $dst = Join-Path $tmp (Split-Path $src.Inf -Leaf)
  Patch-Inf $src.Inf $dst | Out-Null
  Write-Step 'DryRun done (nothing installed)'
  Write-Host ("  patched INF preview at: " + $dst)
  Select-String -Path $dst -Pattern ('DEV_' + (Get-HwidParts $TargetHwid).Dev) | ForEach-Object { Write-Host ("  " + $_.Line.Trim()) }
}

function Do-Prep {
  Need-Admin
  Set-HvciCheck
  $src = Find-SourcePackage
  Write-Step 'Copy package to work directory'
  if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
  New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
  Copy-Item (Join-Path $src.Dir '*') $WorkDir -Recurse -Force
  Write-Host ("  workdir: " + $WorkDir)

  Patch-Inf $src.Inf (Join-Path $WorkDir (Split-Path $src.Inf -Leaf)) | Out-Null
  New-TestCertChain
  Build-Sign-Catalog $WorkDir | Out-Null

  Write-Step 'Enable test signing'
  bcdedit /set testsigning on | Out-Null
  Write-Host '  testsigning = on (applies after reboot)'

  Register-PostRebootTask

  if (-not $NoReboot) {
    Write-Step 'Rebooting in 10 seconds'
    shutdown /r /t 10 /c "Hermes dual-GPU driver: enabling test signing"
  } else {
    Write-Host '  -NoReboot: reboot manually; the scheduled task finishes the install at boot.'
  }
}

function Block-WuaDriverReplace {
  Write-Step 'Protect the setup from Windows Update driver replacement'
  # Documented, reversible policy: Windows Update must not deliver display drivers.
  # Without this, WUA can silently replace the datacenter driver with a Game Ready
  # branch and put the Tesla card into Code 43.
  $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  if (-not (Test-Path $pol)) { New-Item -Path $pol -Force | Out-Null }
  Set-ItemProperty -Path $pol -Name 'ExcludeWUDriversInQualityUpdate' -Value 1 -Type DWord -Force
  Write-Host '  ExcludeWUDriversInQualityUpdate = 1 (revert: set to 0 or delete)'
  Write-Host '  Alternative scope-friendly option: hide only this driver with the "Show or hide updates" tool (wushowhide).'
}

function Do-Install {
  Need-Admin
  Write-Step 'Install phase (post-reboot)'
  $inf = Get-ChildItem $WorkDir -Filter 'nv_disp*.inf' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $inf) { throw "Work package not found in $WorkDir" }
  pnputil /add-driver $inf.FullName /install 2>&1 | Out-String -Stream | ForEach-Object { Write-Host ("  " + $_) }
  pnputil /scan-devices | Out-Null
  schtasks /delete /tn $TASK_NAME /f 2>&1 | Out-Null
  Write-Host '  task removed'
  Block-WuaDriverReplace
  Do-Verify
}

function Do-Verify {
  Need-Admin
  Write-Step 'Verification'
  Get-CimInstance Win32_VideoController |
    Where-Object { $_.Name -match 'NVIDIA' } |
    Select-Object Name,DriverVersion,ConfigManagerErrorCode,Status | Format-Table -AutoSize
  nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv
  Write-Host ("  testsigning: " + [bool]((bcdedit | Select-String 'testsigning') -ne $null))
}

function Get-ModdedPublishedNames([string]$targetDev) {
  # Published INF copies live in C:\Windows\INF as oemN.inf. Scanning their text is
  # locale-independent (pnputil output labels are localized) and exact.
  $names = @()
  foreach ($f in (Get-ChildItem 'C:\Windows\INF' -Filter 'oem*.inf' -ErrorAction SilentlyContinue)) {
    $txt = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $txt) { continue }
    if ($txt -notmatch 'nv_disp') { continue }
    if ($txt -match "DEV_$targetDev") { $names += $f.Name }
  }
  return $names
}

function Do-Revert {
  Need-Admin
  Write-Step 'Revert: remove modded packages'
  $targetDev = (Get-HwidParts $TargetHwid).Dev
  $pubs = Get-ModdedPublishedNames $targetDev
  if ($pubs.Count -eq 0) { Write-Host ('  no published package references DEV_' + $targetDev) }
  foreach ($pub in $pubs) {
    Write-Host ("  pnputil /delete-driver $pub /uninstall /force")
    pnputil /delete-driver $pub /uninstall /force 2>&1 | Out-String -Stream | ForEach-Object { Write-Host ("    " + $_) }
  }
  Write-Step 'Remove test certificates'
  foreach ($st in 'My','Root','TrustedPublisher','CA') {
    $s = New-Object System.Security.Cryptography.X509Certificates.X509Store($st,'LocalMachine')
    $s.Open('ReadWrite')
    foreach ($c in @($s.Certificates | Where-Object { $_.Subject -eq $CA_SUBJECT -or $_.Subject -eq $LEAF_SUBJECT })) {
      $s.Remove($c) | Out-Null
    }
    $s.Close()
  }
  Write-Step 'Disable test signing'
  bcdedit /set testsigning off | Out-Null
  Write-Host '  testsigning = off. Reboot, then install the official GeForce driver for the card.'
}

switch ($Phase.ToLower()) {
  'prep'    { Do-Prep }
  'install' { Do-Install }
  'verify'  { Do-Verify }
  'revert'  { Do-Revert }
  'dryrun'  { Do-DryRun }
}
