#requires -Version 5.1
<#
.SYNOPSIS
  Back up the applications on an OpenShift cluster as clean manifests that can
  be restored onto a NEW cluster (for example a rebuilt SNO).

.DESCRIPTION
  For every namespace it saves the objects that make up an application
  (Deployments, DeploymentConfigs, StatefulSets, Services, Routes, ConfigMaps,
  Secrets, PVC definitions, ServiceAccounts, Roles, RoleBindings, ImageStreams,
  BuildConfigs, HPAs, PDBs, NetworkPolicies, quotas) as JSON, one file per kind,
  numbered so that restoring in filename order creates things in a sensible
  order.

  WHAT MAKES THIS DIFFERENT FROM `oc get -o yaml`: a raw dump cannot be applied
  to another cluster. Every object carries a uid, resourceVersion and status
  that the new cluster refuses or ignores, Services carry a cluster-assigned IP,
  PVCs name a volume that will not exist there, Routes carry a generated host
  from the OLD cluster's domain, and the platform's own objects (token Secrets,
  the default/builder/deployer service accounts, the injected CA ConfigMaps)
  are recreated by every new namespace anyway. This removes all of that and
  leaves what a person wrote.

  READ-ONLY. It only runs `oc get` and `oc whoami`; it changes nothing on the
  cluster.

  WHAT IT DOES NOT BACK UP (it says so again at the end):
    * The DATA inside persistent volumes. See the data section of the summary.
    * Container images that exist only in the cluster's internal registry.
    * Cluster configuration such as the OAuth/htpasswd users, certificates,
      operators and the cluster's own storage setup.

.PARAMETER Namespaces
  Namespaces to back up. Default: every namespace that is not part of the
  platform (openshift-*, kube-*, default, openshift).

.PARAMETER OutDir
  Where to write. Default: ocp-backup-<date>-<time> in the current folder. It
  must not already exist.

.PARAMETER SkipSecrets
  Leave Secrets out. By default they ARE included, because an application that
  restores without its Secrets does not start - but the files then contain
  credentials. See the warning in the summary.

.EXAMPLE
  oc login https://api.ocp-sno.site-a.vcf.lab:6443 -u kubeadmin
  .\backup-ocp-apps.ps1

.EXAMPLE
  .\backup-ocp-apps.ps1 -Namespaces demo-ui,rackhouse,freshcart -OutDir D:\backups\sno1
#>

[CmdletBinding()]
param(
    [string[]]$Namespaces,
    [string]$OutDir,
    [switch]$SkipSecrets
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# ---------------------------------------------------------------------------
# What is backed up, and in what order it must be created when restoring.
# The two-digit prefix IS the order: a Secret before the Deployment that mounts
# it, a PVC before the pod that claims it, a Route after its Service.
# ---------------------------------------------------------------------------
$Kinds = @(
    @{ Oc = 'resourcequotas';                          Prefix = '05'; Name = 'resourcequota' },
    @{ Oc = 'limitranges';                             Prefix = '06'; Name = 'limitrange' },
    @{ Oc = 'serviceaccounts';                         Prefix = '10'; Name = 'serviceaccount' },
    @{ Oc = 'configmaps';                              Prefix = '20'; Name = 'configmap' },
    @{ Oc = 'secrets';                                 Prefix = '21'; Name = 'secret' },
    @{ Oc = 'persistentvolumeclaims';                  Prefix = '30'; Name = 'pvc' },
    @{ Oc = 'roles.rbac.authorization.k8s.io';         Prefix = '40'; Name = 'role' },
    @{ Oc = 'rolebindings.rbac.authorization.k8s.io';  Prefix = '41'; Name = 'rolebinding' },
    @{ Oc = 'imagestreams.image.openshift.io';         Prefix = '50'; Name = 'imagestream' },
    @{ Oc = 'buildconfigs.build.openshift.io';         Prefix = '51'; Name = 'buildconfig' },
    @{ Oc = 'services';                                Prefix = '60'; Name = 'service' },
    @{ Oc = 'deployments.apps';                        Prefix = '70'; Name = 'deployment' },
    @{ Oc = 'statefulsets.apps';                       Prefix = '71'; Name = 'statefulset' },
    @{ Oc = 'daemonsets.apps';                         Prefix = '72'; Name = 'daemonset' },
    @{ Oc = 'deploymentconfigs.apps.openshift.io';     Prefix = '73'; Name = 'deploymentconfig' },
    @{ Oc = 'cronjobs.batch';                          Prefix = '74'; Name = 'cronjob' },
    @{ Oc = 'routes.route.openshift.io';               Prefix = '80'; Name = 'route' },
    @{ Oc = 'ingresses.networking.k8s.io';             Prefix = '81'; Name = 'ingress' },
    @{ Oc = 'horizontalpodautoscalers.autoscaling';    Prefix = '90'; Name = 'hpa' },
    @{ Oc = 'poddisruptionbudgets.policy';             Prefix = '91'; Name = 'pdb' },
    @{ Oc = 'networkpolicies.networking.k8s.io';       Prefix = '92'; Name = 'networkpolicy' }
)

$PlatformSccs = @('anyuid', 'hostaccess', 'hostmount-anyuid', 'hostnetwork', 'hostnetwork-v2',
    'machine-api-termination-handler', 'node-exporter', 'nonroot', 'nonroot-v2', 'privileged',
    'restricted', 'restricted-v2', 'restricted-v3', 'hostpath-provisioner', 'nonroot-v3',
    'hostmount-anyuid-v2', 'insights-runtime-extractor-scc', 'privileged-v2')

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Test-Prop($o, [string]$name) {
    return ($null -ne $o) -and ($null -ne $o.PSObject.Properties[$name])
}

function Remove-Prop($o, [string[]]$names) {
    if ($null -eq $o) { return }
    foreach ($n in $names) {
        if ($null -ne $o.PSObject.Properties[$n]) { $o.PSObject.Properties.Remove($n) }
    }
}

function Remove-Annotations($meta, [string[]]$exact, [string[]]$prefixes) {
    if (-not (Test-Prop $meta 'annotations') -or $null -eq $meta.annotations) { return }
    foreach ($p in @($meta.annotations.PSObject.Properties.Name)) {
        $hit = $exact -contains $p
        foreach ($pre in $prefixes) { if ($p.StartsWith($pre)) { $hit = $true } }
        if ($hit) { $meta.annotations.PSObject.Properties.Remove($p) }
    }
    if (@($meta.annotations.PSObject.Properties).Count -eq 0) { Remove-Prop $meta @('annotations') }
}

# Native stderr is NOT an error in Windows PowerShell 5.1 (the same trap that
# broke the KubeShift setup script): judge `oc` by its exit code.
function Invoke-OcJson([string[]]$OcArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & oc @OcArgs 2>$null } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { return $null }
    $text = ($out -join "`n")
    if (-not $text.Trim()) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Save-Json([string]$path, $obj) {
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 100), $Utf8NoBom)
}

# ---------------------------------------------------------------------------
# Deciding what to leave out, and cleaning what stays
# ---------------------------------------------------------------------------

# Why an object is NOT backed up, or $null when it is. Each is something the new
# cluster makes for itself, or something owned by another object that will
# recreate it.
function Get-SkipReason($o, [string]$kind) {
    $m = $o.metadata
    if (Test-Prop $m 'ownerReferences') {
        foreach ($r in @($m.ownerReferences)) {
            if ($r.controller) { return "managed by $($r.kind)/$($r.name)" }
        }
    }
    switch ($kind) {
        'secret' {
            if ($o.type -eq 'kubernetes.io/service-account-token') { return 'service-account token (regenerated)' }
            if ($o.type -eq 'kubernetes.io/dockercfg') { return 'registry credential for a service account (regenerated)' }
            if ($m.name -match '-(dockercfg|token)-') { return 'generated by the platform' }
        }
        'configmap' {
            if ($m.name -in @('kube-root-ca.crt', 'openshift-service-ca.crt')) { return 'injected into every namespace' }
        }
        'serviceaccount' {
            if ($m.name -in @('default', 'builder', 'deployer', 'pipeline')) { return 'created with every namespace' }
        }
        'rolebinding' {
            if ($m.name.StartsWith('system:')) { return 'created by the platform' }
        }
    }
    return $null
}

# Strips what the cluster wrote and what will not exist on another one.
function Convert-ForBackup($o, [string]$kind) {
    Remove-Prop $o @('status')
    $m = $o.metadata
    Remove-Prop $m @('uid', 'resourceVersion', 'generation', 'creationTimestamp', 'selfLink',
        'managedFields', 'ownerReferences', 'deletionTimestamp', 'deletionGracePeriodSeconds', 'finalizers')
    Remove-Annotations $m @('kubectl.kubernetes.io/last-applied-configuration', 'deployment.kubernetes.io/revision') `
        @('pv.kubernetes.io/', 'volume.kubernetes.io/', 'volume.beta.kubernetes.io/', 'openshift.io/sa.scc.')

    switch ($kind) {
        'namespace' {
            Remove-Prop $o @('spec')
            if (Test-Prop $m 'labels') { Remove-Prop $m.labels @('kubernetes.io/metadata.name') }
        }
        'service' {
            # The cluster picks these; another cluster's range differs.
            Remove-Prop $o.spec @('clusterIP', 'clusterIPs', 'ipFamilies', 'ipFamilyPolicy', 'healthCheckNodePort')
        }
        'pvc' {
            # Names a volume that will not exist on the new cluster.
            Remove-Prop $o.spec @('volumeName')
        }
        'route' {
            # A host the OLD cluster generated belongs to the old cluster's
            # domain. Removing it lets the new one generate its own; a host a
            # person chose is kept.
            $generated = $false
            if ((Test-Prop $m 'annotations') -and ($m.annotations.PSObject.Properties['openshift.io/host.generated'])) {
                $generated = ($m.annotations.'openshift.io/host.generated' -eq 'true')
            }
            if ($generated) { Remove-Prop $o.spec @('host') }
            Remove-Annotations $m @('openshift.io/host.generated') @()
        }
        'serviceaccount' {
            # Lists the old cluster's generated secrets, which will not exist.
            Remove-Prop $o @('secrets')
            if (Test-Prop $o 'imagePullSecrets') {
                $kept = @($o.imagePullSecrets | Where-Object { $_.name -notmatch '-dockercfg-' })
                if ($kept.Count -eq 0) { Remove-Prop $o @('imagePullSecrets') } else { $o.imagePullSecrets = $kept }
            }
        }
        'deploymentconfig' {
            # The digest the old cluster last rolled out; meaningless on a new one.
            if ($o.spec.triggers) {
                foreach ($t in @($o.spec.triggers)) {
                    if ($t.imageChangeParams) { Remove-Prop $t.imageChangeParams @('lastTriggeredImage') }
                }
            }
        }
    }
    # The pod template's own timestamp (always null in a live object).
    if ($o.spec -and $o.spec.template -and $o.spec.template.metadata) {
        Remove-Prop $o.spec.template.metadata @('creationTimestamp')
    }
    if ($o.spec -and $o.spec.jobTemplate) {
        Remove-Prop $o.spec.jobTemplate.metadata @('creationTimestamp')
        if ($o.spec.jobTemplate.spec.template.metadata) {
            Remove-Prop $o.spec.jobTemplate.spec.template.metadata @('creationTimestamp')
        }
    }
    return $o
}

# Images in the cluster's own registry: they do not exist anywhere else.
function Get-InternalImages($o) {
    $text = $o | ConvertTo-Json -Depth 100 -Compress
    $found = @()
    foreach ($mt in [regex]::Matches($text, '"(?:image|dockerImageReference)"\s*:\s*"([^"]*(?:image-registry\.openshift-image-registry\.svc|default-route-openshift-image-registry)[^"]*)"')) {
        $found += $mt.Groups[1].Value
    }
    return $found
}

# ---------------------------------------------------------------------------
# The backup
# ---------------------------------------------------------------------------

function Invoke-Backup {
    if (-not (Get-Command oc -ErrorAction SilentlyContinue)) {
        throw "oc is not on PATH. Add the folder holding oc.exe to PATH, or run this from it."
    }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $who = & oc whoami 2>$null
    $whoCode = $LASTEXITCODE
    $server = & oc whoami --show-server 2>$null
    $ErrorActionPreference = $prev
    if ($whoCode -ne 0) { throw "You are not logged in to a cluster. Run: oc login <api-url> -u <user>" }

    if (-not $OutDir) { $OutDir = Join-Path (Get-Location) ("ocp-backup-" + (Get-Date -Format 'yyyyMMdd-HHmm')) }
    if (Test-Path $OutDir) { throw "$OutDir already exists. Pick a new folder so one backup can never overwrite another." }
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $OutDir 'cluster') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $OutDir 'info') | Out-Null

    Write-Host ""
    Write-Host "  Backing up from $server as $who" -ForegroundColor Cyan

    if (-not $Namespaces) {
        $all = Invoke-OcJson @('get', 'namespaces', '-o', 'json')
        if ($null -eq $all) { throw "Could not list namespaces. Name them with -Namespaces." }
        $Namespaces = @($all.items | ForEach-Object { $_.metadata.name } |
            Where-Object { $_ -notmatch '^(openshift|kube)(-|$)' -and $_ -ne 'default' } | Sort-Object)
    }
    Write-Host "  Namespaces: $($Namespaces -join ', ')"
    Write-Host ""

    $counts = @{}; $skipped = @(); $warnings = @(); $images = @(); $pvcs = @(); $missing = @()

    foreach ($ns in $Namespaces) {
        $nsDir = Join-Path $OutDir $ns
        New-Item -ItemType Directory -Force $nsDir | Out-Null

        $nsObj = Invoke-OcJson @('get', 'namespace', $ns, '-o', 'json')
        if ($null -eq $nsObj) { $missing += $ns; Write-Host "  [skip] $ns not found or not readable" -ForegroundColor Yellow; continue }
        $clean = Convert-ForBackup $nsObj 'namespace'
        Save-Json (Join-Path $nsDir '00-namespace.json') $clean

        $line = @()
        foreach ($k in $Kinds) {
            if ($SkipSecrets -and $k.Name -eq 'secret') { continue }
            $list = Invoke-OcJson @('get', $k.Oc, '-n', $ns, '-o', 'json')
            if ($null -eq $list -or @($list.items).Count -eq 0) { continue }

            $keep = @()
            foreach ($item in @($list.items)) {
                $reason = Get-SkipReason $item $k.Name
                if ($reason) { $skipped += "$ns  $($k.Name)/$($item.metadata.name)  - $reason"; continue }
                if ($k.Name -eq 'pvc') {
                    $pvcs += "$ns  $($item.metadata.name)  $($item.spec.resources.requests.storage)  class=$($item.spec.storageClassName)"
                }
                $internal = Get-InternalImages $item
                foreach ($img in $internal) { $images += "$ns  $($k.Name)/$($item.metadata.name)  $img" }
                $keep += (Convert-ForBackup $item $k.Name)
            }
            if ($keep.Count -eq 0) { continue }

            $out = [pscustomobject]@{ apiVersion = 'v1'; kind = 'List'; items = @($keep) }
            Save-Json (Join-Path $nsDir ("{0}-{1}.json" -f $k.Prefix, $k.Name)) $out
            $counts[$k.Name] = [int]$counts[$k.Name] + $keep.Count
            $line += "$($keep.Count) $($k.Name)"
        }
        Write-Host ("  {0,-24} {1}" -f $ns, ($line -join ', '))
    }

    # --- Cluster-wide pieces that applications depend on ------------------------
    $crbs = Invoke-OcJson @('get', 'clusterrolebindings', '-o', 'json')
    if ($crbs) {
        $mine = @($crbs.items | Where-Object {
                -not $_.metadata.name.StartsWith('system:') -and
                (@($_.subjects) | Where-Object { $_.namespace -and ($Namespaces -contains $_.namespace) })
            } | ForEach-Object { Convert-ForBackup $_ 'clusterrolebinding' })
        if ($mine.Count -gt 0) {
            Save-Json (Join-Path $OutDir 'cluster\clusterrolebindings.json') ([pscustomobject]@{ apiVersion = 'v1'; kind = 'List'; items = @($mine) })
            Write-Host ("  {0,-24} {1} cluster role binding(s) for these namespaces' accounts" -f '(cluster-wide)', $mine.Count)
        }
    }
    $sccs = Invoke-OcJson @('get', 'securitycontextconstraints', '-o', 'json')
    if ($sccs) {
        $custom = @($sccs.items | Where-Object { $PlatformSccs -notcontains $_.metadata.name } |
            ForEach-Object { Convert-ForBackup $_ 'scc' })
        if ($custom.Count -gt 0) {
            Save-Json (Join-Path $OutDir 'cluster\scc-custom.json') ([pscustomobject]@{ apiVersion = 'v1'; kind = 'List'; items = @($custom) })
            Write-Host ("  {0,-24} {1} custom SCC(s): {2}" -f '(cluster-wide)', $custom.Count, (($custom | ForEach-Object { $_.metadata.name }) -join ', '))
        }
    }

    # --- Reference only: what the new cluster has to offer ------------------------
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    (& oc get storageclass 2>$null | Out-String) | Set-Content (Join-Path $OutDir 'info\storageclasses-on-old-cluster.txt') -Encoding UTF8
    $ErrorActionPreference = $prev

    # --- The summary --------------------------------------------------------------
    $s = New-Object System.Collections.Generic.List[string]
    $s.Add("OPENSHIFT APPLICATION BACKUP")
    $s.Add("Taken        : $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    $s.Add("From cluster : $server")
    $s.Add("As user      : $who")
    $s.Add("Namespaces   : $($Namespaces -join ', ')")
    $s.Add("")
    $s.Add("BACKED UP")
    foreach ($k in ($counts.Keys | Sort-Object)) { $s.Add(("  {0,-18} {1}" -f $k, $counts[$k])) }
    if ($missing.Count) { $s.Add(""); $s.Add("NOT FOUND / NOT READABLE: $($missing -join ', ')") }
    $s.Add("")
    $s.Add("LEFT OUT ON PURPOSE (the new cluster makes these itself, or another object recreates them)")
    if ($skipped.Count) { foreach ($x in $skipped) { $s.Add("  $x") } } else { $s.Add("  nothing") }
    $s.Add("")
    $s.Add("!! 1. VOLUME DATA IS NOT IN THIS BACKUP")
    if ($pvcs.Count) {
        $s.Add("   These claims existed. Their definitions are saved; what is INSIDE them is not:")
        foreach ($x in $pvcs) { $s.Add("     $x") }
        $s.Add("   Copy the data out before you delete the cluster, for example:")
        $s.Add("     oc get pods -n <ns>                           # find a pod that mounts the claim")
        $s.Add("     oc exec -n <ns> <pod> -- ls <mount path>      # see what is there")
        $s.Add("     oc rsync -n <ns> <pod>:<mount path>/ .\data\<ns>\<claim>\")
        $s.Add("   Or install OADP (Velero) with an S3 bucket OUTSIDE the cluster and back the namespace up with it.")
    } else { $s.Add("   No persistent volume claims were found.") }
    $s.Add("")
    $s.Add("!! 2. IMAGES IN THE CLUSTER'S OWN REGISTRY ARE NOT IN THIS BACKUP")
    if ($images.Count) {
        $s.Add("   These objects pull from the internal registry. They will fail on a new cluster unless the images")
        $s.Add("   are copied somewhere first (oc image mirror, or skopeo copy), or rebuilt:")
        foreach ($x in ($images | Sort-Object -Unique)) { $s.Add("     $x") }
    } else { $s.Add("   Nothing pulls from the internal registry - the images come from registries that outlive the cluster.") }
    $s.Add("")
    $s.Add("!! 3. SECRETS")
    if ($SkipSecrets) { $s.Add("   Secrets were left out (-SkipSecrets). Recreate them on the new cluster before the applications start.") }
    else {
        $s.Add("   Secrets ARE in this backup, as base64 - which is encoding, not protection. Treat this whole folder")
        $s.Add("   as a credential: keep it off shared drives and out of Git, or encrypt it.")
    }
    $s.Add("")
    $s.Add("!! 4. NOT COVERED: cluster configuration")
    $s.Add("   Users (htpasswd / OAuth), the cluster's certificates and DNS, installed operators and the storage")
    $s.Add("   setup are not here. If an application needs an operator (for example a database operator), install")
    $s.Add("   it on the new cluster first.")
    $s.Add("")
    $s.Add("TO RESTORE onto the new cluster:")
    $s.Add("   oc login <new-api-url> -u kubeadmin")
    $s.Add("   oc get storageclass                      # compare with info\storageclasses-on-old-cluster.txt")
    $s.Add("   .\restore-ocp-apps.ps1 -BackupDir `"$OutDir`" -StorageClass <class on the new cluster> -HoldWorkloads")
    $s.Add("   ...copy the volume data back in, then:")
    $s.Add("   .\restore-ocp-apps.ps1 -BackupDir `"$OutDir`" -Release")
    [IO.File]::WriteAllLines((Join-Path $OutDir 'BACKUP-SUMMARY.txt'), $s, $Utf8NoBom)

    Write-Host ""
    Write-Host "  Saved to: $OutDir" -ForegroundColor Green
    Write-Host "  Read BACKUP-SUMMARY.txt there - it lists what is NOT covered." -ForegroundColor Green
    if ($pvcs.Count)   { Write-Host "  !! $($pvcs.Count) volume claim(s): their DATA is not included. Copy it out before deleting the cluster." -ForegroundColor Yellow }
    if ($images.Count) { Write-Host "  !! $($images.Count) object(s) use images from the internal registry." -ForegroundColor Yellow }
    if (-not $SkipSecrets) { Write-Host "  !! The folder contains Secrets. Keep it private." -ForegroundColor Yellow }
}

# Run unless this file was dot-sourced (which is how the cleaning rules are tested).
if ($MyInvocation.InvocationName -ne '.') { Invoke-Backup }
