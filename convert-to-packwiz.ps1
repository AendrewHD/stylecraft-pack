<#
  convert-to-packwiz.ps1
  Turns existing mods folders (Prism client instance + server) into a packwiz pack.

  - Looks up every jar on Modrinth by SHA1 hash and adds the exact same version.
  - Jars not on Modrinth: tries CurseForge (packwiz curseforge detect).
  - Anything left stays as a plain .jar in mods\ (served from your repo).
  - If you pass -ServerMods, each mod's side is set from where it was found:
      in both folders -> "both", only client -> "client", only server -> "server".

  Run it inside the pack folder AFTER "packwiz init":
    powershell -ExecutionPolicy Bypass -File .\convert-to-packwiz.ps1 `
      -ClientMods "C:\Users\Andre\AppData\Roaming\PrismLauncher\instances\GeilFrame Dev\minecraft\mods" `
      -ServerMods "C:\Users\Andre\Downloads\server-mods"
#>
param(
    [Parameter(Mandatory = $true)] [string]$ClientMods,
    [string]$ServerMods,
    [string]$PackDir = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PackDir

if (-not (Test-Path 'pack.toml')) { throw "pack.toml not found in $PackDir - run 'packwiz init' first." }
if (-not (Get-Command packwiz -ErrorAction SilentlyContinue)) { throw "packwiz.exe not found in PATH (or in this folder)." }

function Get-Jars([string]$dir, [string]$tag) {
    if (-not $dir) { return @() }
    if (-not (Test-Path -LiteralPath $dir)) { throw "Folder not found: $dir" }
    Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -eq '.jar' } | ForEach-Object {
        [pscustomobject]@{
            Path   = $_.FullName
            Name   = $_.Name
            Sha1   = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA1).Hash.ToLower()
            Source = $tag
        }
    }
}

Write-Host "Hashing jars..."
$all = @(Get-Jars $ClientMods 'client') + @(Get-Jars $ServerMods 'server')
Write-Host ("  {0} jars found" -f $all.Count)

# --- Modrinth lookup by hash (one request) ---
Write-Host "Looking up hashes on Modrinth..."
$hashes = @($all | ForEach-Object { $_.Sha1 } | Select-Object -Unique)
$body = @{ hashes = $hashes; algorithm = 'sha1' } | ConvertTo-Json -Depth 3
$mr = Invoke-RestMethod -Method Post -Uri 'https://api.modrinth.com/v2/version_files' `
    -Body $body -ContentType 'application/json' -UserAgent 'geilframe-packwiz-convert/1.0'

# --- Group jars into projects ---
$projects = [ordered]@{}
foreach ($j in $all) {
    $hit = $mr.PSObject.Properties[$j.Sha1]
    $key = if ($hit) { 'mr:' + $hit.Value.project_id } else { 'file:' + $j.Name }
    if (-not $projects.Contains($key)) {
        $projects[$key] = [pscustomobject]@{ Key = $key; Client = $false; Server = $false; Jars = @(); Version = $null }
    }
    $p = $projects[$key]
    if ($j.Source -eq 'client') { $p.Client = $true } else { $p.Server = $true }
    $p.Jars += $j
    # Prefer the server's version if the two folders differ
    if ($hit -and (-not $p.Version -or $j.Source -eq 'server')) { $p.Version = $hit.Value }
}

function Get-Side($p) {
    if ($p.Client -and $p.Server) { 'both' } elseif ($p.Server) { 'server' } else { 'client' }
}

$sideByMrId = @{}
$sideByFile = @{}
New-Item -ItemType Directory -Force -Path 'mods' | Out-Null

# --- Add Modrinth mods ---
$mrProjects = @($projects.Values | Where-Object { $_.Version })
$i = 0
foreach ($p in $mrProjects) {
    $i++
    $projId = $p.Version.project_id
    $sideByMrId[$projId] = Get-Side $p
    $already = Select-String -Path 'mods\*.pw.toml' -Pattern "mod-id = `"$projId`"" -SimpleMatch -List -ErrorAction SilentlyContinue
    if ($already) {
        Write-Host ("[{0}/{1}] already in pack (added as dependency): {2}" -f $i, $mrProjects.Count, $p.Jars[0].Name)
        continue
    }
    Write-Host ("[{0}/{1}] Modrinth: {2}" -f $i, $mrProjects.Count, $p.Jars[0].Name)
    & packwiz modrinth add --project-id $projId --version-id $p.Version.id -y | Out-Host
}

# --- Everything else: copy jar in, let CurseForge detect try ---
$others = @($projects.Values | Where-Object { -not $_.Version })
foreach ($p in $others) {
    $j = $p.Jars | Where-Object { $_.Source -eq 'server' } | Select-Object -First 1
    if (-not $j) { $j = $p.Jars[0] }
    Copy-Item -LiteralPath $j.Path -Destination (Join-Path 'mods' $j.Name) -Force
    $sideByFile[$j.Name] = Get-Side $p
}
if ($others.Count -gt 0) {
    Write-Host ("Trying CurseForge for {0} jars not found on Modrinth..." -f $others.Count)
    & packwiz curseforge detect -y | Out-Host
}

# --- Set sides + clean up jars that now have a metafile ---
$metaFilenames = @{}
Get-ChildItem -LiteralPath 'mods' -Filter '*.pw.toml' -File | ForEach-Object {
    $t = [IO.File]::ReadAllText($_.FullName)
    $fn = $null
    if ($t -match '(?m)^filename = "([^"]+)"') { $fn = $Matches[1]; $metaFilenames[$fn] = $true }

    if ($ServerMods) {
        $side = $null
        if ($t -match 'mod-id = "([^"]+)"' -and $sideByMrId.ContainsKey($Matches[1])) { $side = $sideByMrId[$Matches[1]] }
        elseif ($fn -and $sideByFile.ContainsKey($fn)) { $side = $sideByFile[$fn] }
        if ($side) {
            if ($t -match '(?m)^side = ') {
                $t = $t -replace '(?m)^side = "[^"]*"', "side = `"$side`""
            } else {
                $t = $t -replace '(?m)^(filename = .*)$', "`$1`nside = `"$side`""
            }
            [IO.File]::WriteAllText($_.FullName, $t)   # UTF-8 without BOM
        }
    }
}
Get-ChildItem -LiteralPath 'mods' -Filter '*.jar' -File | Where-Object { $metaFilenames.ContainsKey($_.Name) } |
    Remove-Item -Force

& packwiz refresh | Out-Host

# --- Report ---
$raw = @(Get-ChildItem -LiteralPath 'mods' -File | Where-Object { $_.Extension -eq '.jar' })
$report = @()
$report += "Jars scanned:          $($all.Count)"
$report += "Modrinth projects:     $($mrProjects.Count)"
$report += "Not on Modrinth:       $($others.Count)"
$report += "Left as raw jars:      $($raw.Count)  (not on Modrinth or CurseForge - committed to git, installed on BOTH sides)"
$report += ""
$report += "Raw jars:"
$raw | ForEach-Object { $report += "  $($_.Name)   [found on: $($sideByFile[$_.Name])]" }
$report += ""
$report += "Mods found only on the server (side = server):"
$projects.Values | Where-Object { $_.Server -and -not $_.Client } | ForEach-Object { $report += "  $($_.Jars[0].Name)" }
$report += ""
$report += "Mods found only on the client (side = client):"
$projects.Values | Where-Object { $_.Client -and -not $_.Server } | ForEach-Object { $report += "  $($_.Jars[0].Name)" }
$report | Set-Content -Path 'convert-report.txt' -Encoding utf8
$report | Out-Host
Write-Host "`nDone. Review convert-report.txt, then commit."
