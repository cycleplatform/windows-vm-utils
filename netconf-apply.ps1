# ============================================================
# Cycle Windows VM Helpers
# *Netconf Apply*
# 
# Applies cloud-init "network-config" to Windows NICs
# Tested with PowerShell 5 on Windows Server 2025
#
# Copyright (c) 2025 Petrichor Holdings, Inc. (Cycle)
# ============================================================

$version = Get-Content "version.txt" -Raw
Write-Host "Cycle Netconf Apply"
Write-Host "Version: $version"

Write-Host "[Cycle] Applying network configuration..."

# ----------------------------------------------------------------------
# 1. Locate config-drive
# ----------------------------------------------------------------------
$cd = Get-CimInstance Win32_LogicalDisk |
      Where-Object { $_.DriveType -eq 5 -and $_.VolumeName -match "cidata|config-2" }

if (-not $cd) {
    Write-Error "[Cycle] Could not find config-drive."
    exit 1
}

$cfgPath = Join-Path $cd.DeviceID "network-config"

if (-not (Test-Path $cfgPath)) {
    Write-Error "[Cycle] network-config not found on $($cd.DeviceID)"
    exit 1
}

Write-Host "[Cycle] Found network-config on drive $($cd.DeviceID)"

# ----------------------------------------------------------------------
# 2. Minimal YAML parser
# ----------------------------------------------------------------------
function Convert-YamlSimple {
    param([string]$Yaml)

    $lines = $Yaml -split "`n"
    $root  = @{}
    $stack = @(@{ obj = $root; indent = -1 })

    foreach ($raw in $lines) {
        $line = $raw.Replace("`r","")
        if ($line.Trim() -eq "" -or $line.Trim().StartsWith("#")) { continue }

        $indent = ($line.Length - $line.TrimStart().Length)
        $trim   = $line.Trim()

        while ($stack[-1].indent -ge $indent) {
            $stack = $stack[0..($stack.Count - 2)]
        }

        $parent = $stack[-1].obj

        if ($trim -match "^- (.+)$") {
            $val = $matches[1]

            if (-not $parent["_list"]) {
                $parent["_list"] = New-Object System.Collections.ArrayList
            }

            if ($val -match "^([^:]+):\s+(.+)$") {
                $obj = @{}
                $obj[$matches[1]] = $matches[2]
                $parent["_list"].Add($obj) | Out-Null
                $stack += ,@{ obj = $obj; indent = $indent }
            }
            else {
                $parent["_list"].Add($val) | Out-Null
            }
            continue
        }

        if ($trim -match "^([^:]+):\s*$") {
            $key = $matches[1]
            $obj = @{}
            $parent[$key] = $obj
            $stack += ,@{ obj = $obj; indent = $indent }
            continue
        }

        if ($trim -match "^([^:]+):\s+(.+)$") {
            $parent[$matches[1]] = $matches[2]
            continue
        }
    }

    function Fixup($node) {
        foreach ($k in @($node.Keys)) {
            if ($node[$k] -is [System.Collections.IDictionary]) {
                Fixup $node[$k]
                if ($node[$k].Contains("_list")) {
                    $node[$k] = $node[$k]["_list"]
                }
            }
        }
    }

    Fixup $root
    return $root
}

function Normalize-Mac($m) {
    if (-not $m) { return "" }
    return ($m -replace "-", ":" -replace "\.", ":" ).ToLower()
}

# ----------------------------------------------------------------------
# 3. Load YAML
# ----------------------------------------------------------------------
$yamlText = Get-Content $cfgPath -Raw
$cfg      = Convert-YamlSimple $yamlText
$ethernets = $cfg["ethernets"]

Write-Host "[Cycle] NICs in YAML:"
foreach ($k in $ethernets.Keys) {
    $m = $ethernets[$k]["match"]["macaddress"]
    $n = $ethernets[$k]["set-name"]
    Write-Host "  Key=$k  MAC=$m  Name=$n"
}

# ----------------------------------------------------------------------
# 4. Single-phase rename using MAC only
# ----------------------------------------------------------------------

function Wait-ForRename($targetName, $ifIndex) {
    for ($i = 0; $i -lt 20; $i++) {
        $nic = Get-NetAdapter -ErrorAction SilentlyContinue |
               Where-Object { $_.ifIndex -eq $ifIndex }

        if ($nic -and $nic.Name -eq $targetName) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

Write-Host ""
Write-Host "[Cycle] Starting single-phase renaming..."
Write-Host ""

foreach ($key in $ethernets.Keys) {

    $targetMac = Normalize-Mac $ethernets[$key]["match"]["macaddress"]
    $finalName = $ethernets[$key]["set-name"]

    $nic = Get-NetAdapter | Where-Object {
        (Normalize-Mac $_.MacAddress) -eq $targetMac
    }

    if (-not $nic) {
        Write-Error "[Error] Could not find NIC with MAC $targetMac"
        continue
    }

    if ($nic.Name -eq $finalName) {
        Write-Host "[Cycle] NIC with MAC $targetMac is already named $finalName"
        continue
    }

    Write-Host "[Cycle] Renaming NIC ifIndex=$($nic.ifIndex) MAC=$targetMac to $finalName"
    Rename-NetAdapter -Name $nic.Name -NewName $finalName -ErrorAction Stop

    if (-not (Wait-ForRename $finalName $nic.ifIndex)) {
        Write-Error "[Error] Rename verification failed for ifIndex $($nic.ifIndex)"
        continue
    }

    Write-Host "[Cycle] Verified rename of ifIndex $($nic.ifIndex) to $finalName"
}

Write-Host ""
Write-Host "[Cycle] Renaming done. Starting IP configuration..."
Write-Host ""

# ----------------------------------------------------------------------
# 5. IP configuration
# ----------------------------------------------------------------------

function PrefixToMask([int]$prefix) {
    $mask = [uint32]0
    for ($i = 0; $i -lt $prefix; $i++) { $mask = $mask -bor (1 -shl (31 - $i)) }
    $b = [BitConverter]::GetBytes([UInt32]$mask)
    return ($b[3],$b[2],$b[1],$b[0] -join ".")
}

foreach ($key in $ethernets.Keys) {

    $entry     = $ethernets[$key]
    $finalName = $entry["set-name"]
    $quoted    = '"' + $finalName + '"'

    Write-Host ""
    Write-Host "[Cycle] Configuring $finalName..."

    # Reset IPv4 DHCP
    Write-Host "  [Action] Reset IPv4 to DHCP"
    netsh interface ip set address name=$quoted source=dhcp

    # Reset IPv6
    Write-Host "  [Action] Reset IPv6 stack"
    netsh interface ipv6 reset | Out-Null

    # IPs
    foreach ($addr in $entry["addresses"]) {
        $parts = $addr -split "/"
        $ip    = $parts[0]
        $pre   = [int]$parts[1]

        if ($ip -like "*:*") {
            Write-Host "  [Action] Add IPv6 address $ip/$pre"
            netsh interface ipv6 add address $quoted $ip/$pre
        }
        else {
            $mask = PrefixToMask $pre
            Write-Host "  [Action] Add IPv4 address $ip mask=$mask"
            netsh interface ip add address $quoted $ip $mask
        }
    }

    # Routes
    foreach ($r in $entry["routes"]) {
        $to     = $r["to"]
        $via    = $r["via"]
        $metric = $r["metric"]

        if ($to -like "*:*") {
            if ($via -eq "::0") {
                Write-Host "  [Action] Add IPv6 route to=$to metric=$metric"
                netsh interface ipv6 add route $to $finalName metric=$metric
            } else {
                Write-Host "  [Action] Add IPv6 route to=$to via=$via metric=$metric"
                netsh interface ipv6 add route $to $finalName $via metric=$metric
            }
        }
        else {
            if ($via -eq "0.0.0.0") {
                Write-Host "  [Action] Add IPv4 route to=$to via=0.0.0.0 metric=$metric"
                netsh interface ip add route $to $finalName 0.0.0.0 metric=$metric
            } else {
                Write-Host "  [Action] Add IPv4 route to=$to via=$via metric=$metric"
                netsh interface ip add route $to $finalName $via metric=$metric
            }
        }
    }

    # DNS (split IPv4/IPv6)
    if ($entry["nameservers"] -and $entry["nameservers"]["addresses"]) {

        $dns4 = @()
        $dns6 = @()

        foreach ($dns in $entry["nameservers"]["addresses"]) {
            if ($dns -like "*:*") { $dns6 += $dns }
            else { $dns4 += $dns }
        }

        if ($dns4.Count -gt 0) {
            Write-Host "  [Action] Set primary IPv4 DNS to $($dns4[0])"
            netsh interface ip set dns name=$quoted static $dns4[0] primary

            for ($i = 1; $i -lt $dns4.Count; $i++) {
                Write-Host "  [Action] Add IPv4 DNS server $($dns4[$i])"
                netsh interface ip add dns name=$quoted $dns4[$i] index=($i+1)
            }
        }

        if ($dns6.Count -gt 0) {
            Write-Host "  [Action] Set primary IPv6 DNS to $($dns6[0])"
            netsh interface ipv6 set dnsservers $finalName static $dns6[0] primary

            for ($i = 1; $i -lt $dns6.Count; $i++) {
                Write-Host "  [Action] Add IPv6 DNS server $($dns6[$i])"
                netsh interface ipv6 add dnsservers $finalName $dns6[$i] validate=no
            }
        }
    }

    # MTU
    if ($entry["mtu"]) {
        Write-Host "  [Action] Set MTU to $($entry["mtu"])"
        netsh interface ipv4 set subinterface $quoted mtu=$($entry["mtu"]) store=persistent
    }
}

Write-Host ""
Write-Host "[Cycle] Network configuration applied successfully."