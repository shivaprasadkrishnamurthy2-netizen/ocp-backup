#requires -Version 5.1
<#
.SYNOPSIS
  Restore applications saved by backup-ocp-apps.ps1 onto a (new) OpenShift cluster.

.DESCRIPTION
  Applies the saved manifests namespace by namespace, in filename order, which is
  the dependency order: namespace, quotas, service accounts, ConfigMaps, Secrets,
  PVCs, RBAC, image streams, Services, workloads, Routes, autoscalers.

  THE ORDER FOR AN APPLICATION THAT KEEPS DATA:
    1. Restore with -HoldWorkloads. Everything is created, but every workload is
       held at 0 replicas, so nothing starts against an EMPTY volume and writes
       to it.
    2. Copy the volume data in (oc rsync).
    3. Restore again with -Release. Workloads go back to the replica counts they
       had when backed up.
  An application with no data can be restored in one go, with neither switch.

  It only APPLIES objects, with `oc apply`: it creates what is missing and
  updates what the backup describes. It never deletes anything.

.PARAMETER BackupDir
  The folder backup-ocp-apps.ps1 wrote.

.PARAMETER Namespaces
  Only these namespaces from the backup. Default: all of them.

.PARAMETER StorageClass
  Put every PVC on this StorageClass. Use it when the new cluster's class has a
  different name from the old one (`oc get storageclass` on both). Without it
  each PVC asks for the class it had before, and stays Pending if the new
  cluster has none of that name.

.PARAMETER HoldWorkloads
  Create Deployments, StatefulSets, DeploymentConfigs at 0 replicas (and
  CronJobs suspended), remembering the real numbers.

.PARAMETER Release
  Scale held workloads back to their remembered replica counts. Restores nothing.

.EXAMPLE
  .\restore-ocp-apps.ps1 -BackupDir .\ocp-backup-20261102-1030 -StorageClass lvms-vg1 -HoldWorkloads
  .\restore-ocp-apps.ps1 -BackupDir .\ocp-backup-20261102-1030 -Release
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BackupDir,
    [string[]]$Namespaces,
    [string]$StorageClass,
    [switch]$HoldWorkloads,
    [switch]$Release
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

#: The annotation that remembers a held workload's real replica count.
$HeldAnnotation = 'ocp-backup/original-replicas'

function Invoke-Oc([string[]]$OcArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & oc @OcArgs 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Text = $out.Trim() }
}

function Set-Annotation($o, [string]$key, [string]$value) {
    if ($null -eq $o.metadata.PSObject.Properties['annotations'] -or $null -eq $o.metadata.annotations) {
        $o.metadata | Add-Member -NotePropertyName annotations -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $o.metadata.annotations | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force
}

# Applies the restore-time changes to one saved List, in place.
# Pure (no cluster calls), so the rules can be checked on their own.
function Convert-ForRestore($list, [string]$file, [string]$storageClass, [bool]$hold) {
    foreach ($o in @($list.items)) {
        switch ($o.kind) {
            'PersistentVolumeClaim' {
                if ($storageClass) {
                    if ($null -eq $o.spec.PSObject.Properties['storageClassName']) {
                        $o.spec | Add-Member -NotePropertyName storageClassName -NotePropertyValue $storageClass
                    } else { $o.spec.storageClassName = $storageClass }
                }
            }
            { $_ -in @('Deployment', 'StatefulSet', 'DeploymentConfig') } {
                if ($hold) {
                    $was = if ($null -ne $o.spec.PSObject.Properties['replicas']) { [int]$o.spec.replicas } else { 1 }
                    Set-Annotation $o $HeldAnnotation ([string]$was)
                    if ($null -eq $o.spec.PSObject.Properties['replicas']) {
                        $o.spec | Add-Member -NotePropertyName replicas -NotePropertyValue 0
                    } else { $o.spec.replicas = 0 }
                }
            }
            'CronJob' {
                if ($hold) {
                    Set-Annotation $o $HeldAnnotation 'cronjob'
                    if ($null -eq $o.spec.PSObject.Properties['suspend']) {
                        $o.spec | Add-Member -NotePropertyName suspend -NotePropertyValue $true
                    } else { $o.spec.suspend = $true }
                }
            }
        }
    }
    return $list
}

function Invoke-Restore {
    if (-not (Get-Command oc -ErrorAction SilentlyContinue)) { throw "oc is not on PATH." }
    if (-not (Test-Path $BackupDir)) { throw "$BackupDir does not exist." }
    $who = Invoke-Oc @('whoami')
    if (-not $who.Ok) { throw "You are not logged in. Run: oc login <new-cluster-api-url> -u <user>" }
    $server = (Invoke-Oc @('whoami', '--show-server')).Text

    $nsDirs = @(Get-ChildItem $BackupDir -Directory | Where-Object { $_.Name -notin @('cluster', 'info') })
    if ($Namespaces) { $nsDirs = @($nsDirs | Where-Object { $Namespaces -contains $_.Name }) }
    if ($nsDirs.Count -eq 0) { throw "No namespaces to restore in $BackupDir." }

    Write-Host ""
    Write-Host "  Target cluster: $server  (as $($who.Text))" -ForegroundColor Cyan
    Write-Host "  Namespaces    : $(($nsDirs | ForEach-Object Name) -join ', ')"
    Write-Host ""

    if ($Release) {
        foreach ($d in $nsDirs) {
            $ns = $d.Name
            foreach ($kind in @('deployments.apps', 'statefulsets.apps', 'deploymentconfigs.apps.openshift.io')) {
                $r = Invoke-Oc @('get', $kind, '-n', $ns, '-o', 'json')
                if (-not $r.Ok) { continue }
                foreach ($item in @(($r.Text | ConvertFrom-Json).items)) {
                    $held = $item.metadata.annotations.$HeldAnnotation
                    if ($null -eq $held -or $held -notmatch '^\d+$') { continue }
                    $n = $item.metadata.name
                    $s = Invoke-Oc @('scale', "$kind/$n", '-n', $ns, "--replicas=$held")
                    $null = Invoke-Oc @('annotate', "$kind/$n", '-n', $ns, "$HeldAnnotation-")
                    Write-Host ("  {0,-22} {1,-34} -> {2} replica(s)  {3}" -f $ns, "$($item.kind)/$n", $held, $(if ($s.Ok) { 'ok' } else { $s.Text }))
                }
            }
            $r = Invoke-Oc @('get', 'cronjobs.batch', '-n', $ns, '-o', 'json')
            if ($r.Ok) {
                foreach ($item in @(($r.Text | ConvertFrom-Json).items)) {
                    if ($item.metadata.annotations.$HeldAnnotation -ne 'cronjob') { continue }
                    $n = $item.metadata.name
                    $null = Invoke-Oc @('patch', "cronjob/$n", '-n', $ns, '-p', '{"spec":{"suspend":false}}')
                    $null = Invoke-Oc @('annotate', "cronjob/$n", '-n', $ns, "$HeldAnnotation-")
                    Write-Host ("  {0,-22} {1,-34} -> resumed" -f $ns, "CronJob/$n")
                }
            }
        }
        Write-Host ""
        Write-Host "  Workloads released. Watch them start:  oc get pods -A | findstr /v openshift" -ForegroundColor Green
        return
    }

    # Cluster-wide pieces first: an SCC has to exist before a pod that needs it.
    $custom = Join-Path $BackupDir 'cluster\scc-custom.json'
    if (Test-Path $custom) {
        $r = Invoke-Oc @('apply', '-f', $custom)
        Write-Host "  custom SCCs            $(if ($r.Ok) { 'applied' } else { $r.Text })"
    }

    $failures = @()
    $temp = Join-Path $env:TEMP ("ocp-restore-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $temp | Out-Null
    try {
        foreach ($d in $nsDirs) {
            $ns = $d.Name
            foreach ($f in (Get-ChildItem $d.FullName -Filter *.json | Sort-Object Name)) {
                $list = [IO.File]::ReadAllText($f.FullName, $Utf8NoBom) | ConvertFrom-Json
                # The namespace file is one object, the others are Lists.
                if ($list.kind -ne 'List') { $list = [pscustomobject]@{ apiVersion = 'v1'; kind = 'List'; items = @($list) } }
                $list = Convert-ForRestore $list $f.Name $StorageClass ([bool]$HoldWorkloads)

                $tmp = Join-Path $temp ("{0}-{1}" -f $ns, $f.Name)
                [IO.File]::WriteAllText($tmp, ($list | ConvertTo-Json -Depth 100), $Utf8NoBom)
                $r = Invoke-Oc @('apply', '-f', $tmp)
                $label = $f.BaseName
                if ($r.Ok) {
                    Write-Host ("  {0,-22} {1}" -f $ns, $label)
                } else {
                    $failures += "$ns / $label : $($r.Text)"
                    Write-Host ("  {0,-22} {1}  FAILED" -f $ns, $label) -ForegroundColor Red
                }
                if ($f.Name -eq '00-namespace.json' -and $r.Ok) {
                    for ($i = 0; $i -lt 30; $i++) {
                        if ((Invoke-Oc @('get', 'namespace', $ns)).Ok) { break }
                        Start-Sleep -Seconds 1
                    }
                }
            }
        }
        $crb = Join-Path $BackupDir 'cluster\clusterrolebindings.json'
        if (Test-Path $crb) {
            $r = Invoke-Oc @('apply', '-f', $crb)
            Write-Host "  cluster role bindings  $(if ($r.Ok) { 'applied' } else { $r.Text })"
        }
    } finally {
        Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    if ($failures.Count) {
        Write-Host "  $($failures.Count) file(s) did not apply:" -ForegroundColor Red
        $failures | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        Write-Host "  Fix the cause (often a missing StorageClass, operator or image) and run the same command again -" -ForegroundColor Yellow
        Write-Host "  applying is safe to repeat." -ForegroundColor Yellow
    } else {
        Write-Host "  Restored." -ForegroundColor Green
    }
    if ($HoldWorkloads) {
        Write-Host "  Workloads are HELD at 0 replicas. Copy the volume data in, then run with -Release." -ForegroundColor Yellow
    }
    Write-Host "  Check:  oc get pods -A | findstr /v openshift     and     oc get pvc -A"
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Restore }
