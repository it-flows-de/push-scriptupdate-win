#Requires -Version 5.1
<#
.SYNOPSIS
    Release helper for PowerShell scripts that have their own GitHub repo.
.DESCRIPTION
    Checks the working copy, raises the version, commits, pushes the branch, creates
    and verifies a signed tag and pushes that tag.
    Run it in the top directory of the working copy of the script to release. Exactly
    one *.ps1 must be in that directory; its name is the script name. The repo is named
    like the script, optionally with a suffix (for example push-scriptupdate-win). For
    an existing repo the name is taken from origin, for a new repo the script asks.
    Author:     flo.alt@it-flows.de
    Date:       2026-11-19
    Requires:   Windows PowerShell 5.1, git >= 2.34 with SSH signing set up (signing
                key, allowed_signers, noreply commit mail); runs as a normal user on the
                development PC (push access to GitHub needed)
    Exit codes: 0 ok | 1 error | 2 invalid selection | 3 config | 5 check failed |
                6 aborted by user | 7 git operation failed
.PARAMETER DryRun
    Run all checks and show the plan, change nothing.
.EXAMPLE
    push-scriptupdate.ps1 -DryRun
.EXAMPLE
    push-scriptupdate.ps1
#>
[CmdletBinding()]
param(
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Version               = '1.0.0'
$RequiredConfigVersion = 1

# The only paths derived in the script: its own directory and, by convention,
# the config next to it. Every other path comes from the config.
$ScriptDir  = $PSScriptRoot
$ScriptName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$ConfigFile = Join-Path $ScriptDir "$ScriptName.config"

# --- Exit codes ---
$ExitOk     = 0
$ExitError  = 1
$ExitUsage  = 2
$ExitConfig = 3
$ExitCheck  = 5
$ExitAbort  = 6
$ExitGit    = 7

# --- Patterns for the version lines (layout as in the script template) ---
$PatVersion   = '^\$Version[ \t]*=[ \t]*''(\d+\.\d+\.\d+)'''
$PatReqConfig = '^\$RequiredConfigVersion[ \t]*=[ \t]*(\d+)'
$PatConfigVer = '^[ \t]*ConfigVersion[ \t]*=[ \t]*(\d+)'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# --- Run state (used by the rollback and the flows) ---
$script:GitExit      = 0
$script:RepoDir      = $PWD.ProviderPath
$script:TargetScript = ''
$script:TargetName   = ''
$script:RepoName     = ''
$script:Patterns     = @()
$script:Branch       = ''
$script:TagMsg       = ''
$script:BackupDir    = ''
$script:SwitchedFrom = ''
$script:Committed    = $false
$script:Staged       = $false
$script:CreatedGit   = $false

#--- Output helpers -----------------------------------------------------------

# Print a section headline
function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text =="
}

# Abort with a defined exit code (picked up in the catch block)
function Stop-Script {
    param([int]$Code, [string]$Message)
    $ex = New-Object System.Exception($Message)
    $ex.Data['ExitCode'] = $Code
    throw $ex
}

# Ask a yes/no question. Enter selects the default. Returns $true on yes.
function Confirm-Action {
    param([string]$Prompt, [bool]$DefaultYes = $true)
    $hint = '[y/N]'
    if ($DefaultYes) { $hint = '[Y/n]' }
    $answer = "$(Read-Host "$Prompt $hint")".Trim().ToLower()
    if (-not $answer) { return $DefaultYes }
    return ($answer -eq 'y' -or $answer -eq 'yes')
}

# Ask a yes/no question (default yes) and abort the run on anything but yes
function Assert-Confirmed {
    param([string]$Prompt)
    if (-not (Confirm-Action $Prompt $true)) { Stop-Script $ExitAbort 'Aborted.' }
}

# Ask for a commit or tag message. PowerShell cannot pre-fill an editable input,
# so the typed text is appended to $Prefix and Enter accepts $Default (if given).
# Empty input without a default and a bare prefix like "Fix:" are rejected.
function Read-Message {
    param([string]$Prompt, [string]$Prefix, [string]$Default)
    while ($true) {
        $hint = ''
        if ($Default) { $hint = " [Enter = '$Default']" }
        elseif ($Prefix) { $hint = " (text after '$($Prefix.Trim())')" }
        $text = "$(Read-Host "$Prompt$hint")".Trim()
        if (-not $text) {
            if ($Default) { return $Default }
            Write-Host 'The message must not be empty.'
            continue
        }
        if ($Prefix -and ($text -notmatch '^(Fix|Add|Breaking):')) { $text = $Prefix + $text }
        if ($text -match '^(Fix|Add|Breaking):\s*$') {
            Write-Host 'Please describe the change after the prefix.'
            continue
        }
        return $text
    }
}

#--- Git helpers --------------------------------------------------------------

# Run git, return stdout lines; stderr is shown. The exit code is in $script:GitExit.
# The local ErrorActionPreference keeps stderr text of native commands harmless.
function Invoke-Git {
    param([string[]]$GitArgs)
    $ErrorActionPreference = 'Continue'
    $out = & git @GitArgs
    $script:GitExit = $LASTEXITCODE
    $out
}

# Run git quietly: stderr is discarded. Used for probes. Exit code in $script:GitExit.
function Invoke-GitQuiet {
    param([string[]]$GitArgs)
    $ErrorActionPreference = 'Continue'
    $out = & git @GitArgs 2>$null
    $script:GitExit = $LASTEXITCODE
    $out
}

# Read one git config value, empty string if it is not set
function Get-GitConfig {
    param([string]$Key)
    $v = @(Invoke-GitQuiet 'config', '--get', $Key) | Select-Object -First 1
    if ($null -eq $v) { return '' }
    return "$v".Trim()
}

# Return $true if the current directory is inside a git work tree
function Test-InRepo {
    [void](Invoke-GitQuiet 'rev-parse', '--is-inside-work-tree')
    return ($script:GitExit -eq 0)
}

# Return $true if an ssh-agent holds at least one key
function Test-AgentHasKey {
    if (-not (Get-Command ssh-add -ErrorAction SilentlyContinue)) { return $false }
    $ErrorActionPreference = 'Continue'
    [void](& ssh-add -l 2>$null)
    return ($LASTEXITCODE -eq 0)
}

# Newest release tag (vX.Y.Z), empty string if there is none
function Get-LastTag {
    $t = @(Invoke-GitQuiet 'tag', '-l', 'v*', '--sort=-v:refname') | Select-Object -First 1
    if ($null -eq $t) { return '' }
    return "$t".Trim()
}

# Remote URL for a repo name, built from the template in the config
function Get-RemoteUrl {
    param([string]$Name)
    return $Config['RemoteUrlTemplate'].Replace('{org}', $Config['GithubOrg']).Replace('{name}', $Name)
}

# True if $Name is a valid repo name for the target script: the script name itself or
# the script name plus a suffix (e.g. push-scriptupdate-win). This keeps the release
# from going to a repo that belongs to another script.
function Test-RepoName {
    param([string]$Name)
    if ($Name -cnotmatch '^[A-Za-z0-9._-]+$') { return $false }
    if ($Name -ceq $script:TargetName) { return $true }
    return $Name.StartsWith("$($script:TargetName)-", [System.StringComparison]::Ordinal)
}

# Repo name taken from the URL of origin, using RemoteUrlTemplate (the text before and
# after {name} must match). Empty string if origin does not fit the template.
function Get-RepoNameFromOrigin {
    param([string]$Origin)
    $tpl    = $Config['RemoteUrlTemplate'].Replace('{org}', $Config['GithubOrg'])
    $pos    = $tpl.IndexOf('{name}')
    $prefix = $tpl.Substring(0, $pos)
    $suffix = $tpl.Substring($pos + 6)
    if ($Origin.Length -le ($prefix.Length + $suffix.Length)) { return '' }
    if (-not $Origin.StartsWith($prefix, [System.StringComparison]::Ordinal)) { return '' }
    if (-not $Origin.EndsWith($suffix, [System.StringComparison]::Ordinal)) { return '' }
    return $Origin.Substring($prefix.Length, $Origin.Length - $prefix.Length - $suffix.Length)
}

#--- File helpers -------------------------------------------------------------

# First capture group of a pattern in a text, $null if there is no match
function Get-TextVar {
    param([string]$Text, [string]$Pattern)
    $m = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# First capture group of a pattern in a file, $null if there is no match
function Get-FileVar {
    param([string]$Path, [string]$Pattern)
    return (Get-TextVar ([System.IO.File]::ReadAllText($Path)) $Pattern)
}

# Replace the first match of a pattern in a file (line endings stay as they are)
function Update-FileText {
    param([string]$Path, [string]$Pattern, [string]$Replacement)
    $text = [System.IO.File]::ReadAllText($Path)
    $re = New-Object System.Text.RegularExpressions.Regex($Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    [System.IO.File]::WriteAllText($Path, $re.Replace($text, $Replacement, 1), $Utf8NoBom)
}

# Return $true if a file looks binary (NUL byte in the first 8000 bytes)
function Test-BinaryFile {
    param([string]$Path)
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 8000
        $n = $fs.Read($buf, 0, $buf.Length)
        for ($i = 0; $i -lt $n; $i++) {
            if ($buf[$i] -eq 0) { return $true }
        }
        return $false
    }
    finally {
        $fs.Dispose()
    }
}

# Abort unless the file contains only ASCII (rule for scripts and configs, avoids
# encoding problems in Windows PowerShell 5.1)
function Assert-AsciiFile {
    param([string]$Path, [string]$Hint = '', [int]$Code = 5)
    $bad = $false
    foreach ($b in [System.IO.File]::ReadAllBytes($Path)) {
        if ($b -gt 127) { $bad = $true; break }
    }
    if (-not $bad) { return }
    $lineNo = 0
    $where = ''
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $lineNo++
        if ($line -match '[^\x00-\x7F]') { $where = " (first at line $lineNo)"; break }
    }
    $msg = "$([System.IO.Path]::GetFileName($Path)) contains non-ASCII characters or a BOM$where. Scripts and configs must be ASCII only. $Hint"
    Stop-Script $Code ($msg.Trim())
}

# Abort unless nobody except you, SYSTEM and Administrators may write the config.
# SIDs are used because account names are localized.
function Assert-ConfigAcl {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-Script $ExitConfig "Missing file: $Path"
    }
    $me        = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowed   = @('S-1-5-18', 'S-1-5-32-544', $me)   # SYSTEM, Administrators, you
    $writeMask = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteAttributes, WriteExtendedAttributes, Delete, ChangePermissions, TakeOwnership'
    foreach ($ace in (Get-Acl -LiteralPath $Path).Access) {
        if ($ace.AccessControlType -ne 'Allow') { continue }
        try {
            $sid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            $sid = "$($ace.IdentityReference)"
        }
        if ($allowed -contains $sid) { continue }
        if (($ace.FileSystemRights -band $writeMask) -ne 0) {
            Stop-Script $ExitConfig "Unsafe permissions on ${Path}: $($ace.IdentityReference) may write. Only you, SYSTEM and Administrators may write the config."
        }
    }
}

# Save the two files this script may modify, so an abort can restore them
function Backup-Files {
    $script:BackupDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $script:BackupDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $script:RepoDir $script:TargetScript) -Destination $script:BackupDir
    Copy-Item -LiteralPath (Join-Path $script:RepoDir "$($script:TargetName).config.example") -Destination $script:BackupDir
}

# Undo local changes made by this script if the run stops before the commit:
# restore the backed-up files, unstage, remove a .git created by this run and switch
# back to the original branch. Does nothing once the commit exists.
function Invoke-Rollback {
    if ($script:Committed) { return }
    try {
        if ($script:BackupDir -and (Test-Path -LiteralPath $script:BackupDir)) {
            Copy-Item -LiteralPath (Join-Path $script:BackupDir $script:TargetScript) -Destination (Join-Path $script:RepoDir $script:TargetScript) -Force
            $example = "$($script:TargetName).config.example"
            Copy-Item -LiteralPath (Join-Path $script:BackupDir $example) -Destination (Join-Path $script:RepoDir $example) -Force
            Remove-Item -LiteralPath $script:BackupDir -Recurse -Force
            $script:BackupDir = ''
            Write-Host 'File changes made by this run were reverted.'
        }
        if ($script:CreatedGit) {
            Remove-Item -LiteralPath (Join-Path $script:RepoDir '.git') -Recurse -Force
            $script:CreatedGit = $false
            $script:Staged = $false
            Write-Host 'The local .git created by this run was removed again.'
        }
        elseif ($script:Staged) {
            [void](Invoke-GitQuiet 'reset', '-q')
            $script:Staged = $false
        }
        if ($script:SwitchedFrom) {
            [void](Invoke-GitQuiet 'switch', '-q', $script:SwitchedFrom)
            Write-Host "Switched back to branch $($script:SwitchedFrom)."
            $script:SwitchedFrom = ''
        }
    }
    catch {
        [Console]::Error.WriteLine("ERROR: The rollback failed: $($_.Exception.Message)")
    }
}

#--- Checks -------------------------------------------------------------------

# Check git version, signing setup and commit mail on this PC
function Test-Preflight {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Stop-Script $ExitCheck 'git is not installed.'
    }
    $line = "$(@(Invoke-GitQuiet '--version') | Select-Object -First 1)"
    if (-not ($line -match 'git version (\d+(\.\d+){1,3})')) {
        Stop-Script $ExitCheck "Cannot read the git version from '$line'."
    }
    $gitVersion = [version]($Matches[1])
    if ($gitVersion -lt [version]$Config['MinGitVersion']) {
        Stop-Script $ExitCheck "git $gitVersion is too old (at least $($Config['MinGitVersion']) required)."
    }
    if ((Get-GitConfig 'gpg.format') -ne 'ssh') {
        Stop-Script $ExitCheck "git config gpg.format is not 'ssh' (SSH tag signing is not set up, see your internal howtos)."
    }
    if (-not (Get-GitConfig 'user.signingkey')) {
        Stop-Script $ExitCheck 'git config user.signingkey is not set.'
    }
    if ((Get-GitConfig 'tag.gpgSign') -ne 'true') {
        Stop-Script $ExitCheck "git config tag.gpgSign is not 'true'."
    }
    $allowed = Get-GitConfig 'gpg.ssh.allowedSignersFile'
    if ($allowed.StartsWith('~')) { $allowed = $HOME + $allowed.Substring(1) }
    if (-not $allowed -or -not (Test-Path -LiteralPath $allowed -PathType Leaf)) {
        Stop-Script $ExitCheck "gpg.ssh.allowedSignersFile is not set or the file is missing (needed for 'git tag -v')."
    }
    $domain = "$($Config['CommitMailDomain'])"
    if ($domain) {
        $mail = Get-GitConfig 'user.email'
        if (-not $mail.EndsWith("@$domain", [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-Script $ExitCheck "Commit mail '$mail' is not an @$domain address (the mail is public in the history)."
        }
    }
    if (-not (Get-GitConfig 'gpg.ssh.program')) {
        Write-Host "Note: gpg.ssh.program is not set. Git may ask for the passphrase when signing even though the key is in the ssh-agent (see your internal howtos)."
    }
    if (-not (Test-AgentHasKey)) {
        Write-Host 'Note: no key in the ssh-agent. You will be asked for the passphrase when signing.'
    }
}

# Find the one *.ps1 file in the current directory; its name is the script/repo name
function Find-Target {
    $files = @(Get-ChildItem -LiteralPath $script:RepoDir -File | Where-Object { $_.Extension -eq '.ps1' })
    if ($files.Count -eq 0) {
        Stop-Script $ExitCheck 'No *.ps1 in the current directory. Run this in the directory of the script.'
    }
    if ($files.Count -gt 1) {
        Stop-Script $ExitCheck 'More than one *.ps1 in the current directory, exactly one is expected.'
    }
    $script:TargetScript = $files[0].Name
    $script:TargetName   = $files[0].BaseName
}

# List all files that would be part of the repo (paths relative to the repo directory)
function Get-RepoFiles {
    if (Test-InRepo) {
        return @(Invoke-GitQuiet '-c', 'core.quotepath=off', 'ls-files', '--cached', '--others', '--exclude-standard')
    }
    $base = $script:RepoDir.TrimEnd('\')
    return @(Get-ChildItem -LiteralPath $script:RepoDir -Recurse -File |
        Where-Object { $_.Name -notlike '*.config' -and $_.Name -notlike '*.secrets' -and $_.Name -ne 'last-successful' } |
        ForEach-Object { $_.FullName.Substring($base.Length).TrimStart('\') })
}

# Search the repo files for the customer patterns, print the hits, return $true if any
function Find-CustomerData {
    $hit = $false
    foreach ($rel in (Get-RepoFiles)) {
        $full = Join-Path $script:RepoDir "$rel"
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        if (Test-BinaryFile $full) { continue }
        foreach ($p in $script:Patterns) {
            foreach ($m in @(Select-String -LiteralPath $full -Pattern $p -SimpleMatch)) {
                Write-Host ('{0}:{1}: {2}' -f $rel, $m.LineNumber, $m.Line.Trim())
                $hit = $true
            }
        }
    }
    return $hit
}

# Abort if a text (commit or tag message) contains one of the customer patterns
function Assert-NoCustomerText {
    param([string]$Text)
    foreach ($p in $script:Patterns) {
        if ($Text.IndexOf($p, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Stop-Script $ExitCheck "The message contains '$p'. Customer data does not belong in the public history."
        }
    }
}

# Check the repo files: required files, .gitignore, versions, syntax, customer data
function Test-RepoFiles {
    $example     = "$($script:TargetName).config.example"
    $scriptPath  = Join-Path $script:RepoDir $script:TargetScript
    $examplePath = Join-Path $script:RepoDir $example

    foreach ($f in @($script:TargetScript, '.gitignore', 'README.md', 'INSTALL.md', $example)) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:RepoDir $f) -PathType Leaf)) {
            Stop-Script $ExitCheck "Missing file: $f"
        }
    }
    $ignore = @([System.IO.File]::ReadAllLines((Join-Path $script:RepoDir '.gitignore')) | ForEach-Object { $_.Trim() })
    foreach ($pat in @('*.config', '*.secrets')) {
        if ($ignore -notcontains $pat) { Stop-Script $ExitCheck ".gitignore does not contain '$pat'." }
    }

    # Config and secrets must never be tracked
    if (Test-InRepo) {
        $tracked = @(@(Invoke-GitQuiet 'ls-files', '--cached') | Where-Object { $_ -match '\.(config|secrets)$|(^|/)last-successful$' })
        if ($tracked.Count -gt 0) {
            Stop-Script $ExitCheck 'A config, secrets or marker file is tracked in Git (git rm --cached ...).'
        }
    }

    # Versions in the script and the config example
    $ver = Get-FileVar $scriptPath $PatVersion
    if (-not $ver) {
        Stop-Script $ExitCheck ("The line `$Version = 'x.y.z' was not found in {0}." -f $script:TargetScript)
    }
    $scriptCfg  = Get-FileVar $scriptPath $PatReqConfig
    $exampleCfg = Get-FileVar $examplePath $PatConfigVer
    if (-not $scriptCfg) {
        Stop-Script $ExitCheck ("The line `$RequiredConfigVersion = N was not found in {0}." -f $script:TargetScript)
    }
    if ($scriptCfg -ne $exampleCfg) {
        Stop-Script $ExitCheck "RequiredConfigVersion ($scriptCfg) and ConfigVersion in $example ($exampleCfg) do not match."
    }

    # ASCII only, syntax (and PSScriptAnalyzer errors, if installed)
    Assert-AsciiFile $scriptPath
    Assert-AsciiFile $examplePath
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        foreach ($e in $parseErrors) {
            [Console]::Error.WriteLine(('  line {0}: {1}' -f $e.Extent.StartLineNumber, $e.Message))
        }
        Stop-Script $ExitCheck "Syntax error in $($script:TargetScript)."
    }
    if (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue) {
        $problems = @(Invoke-ScriptAnalyzer -Path $scriptPath -Severity Error)
        if ($problems.Count -gt 0) {
            foreach ($p in $problems) {
                [Console]::Error.WriteLine(('  line {0}: {1}' -f $p.Line, $p.Message))
            }
            Stop-Script $ExitCheck "PSScriptAnalyzer reports errors in $($script:TargetScript)."
        }
    }

    # Customer data must not appear in a public repo
    if ($script:Patterns.Count -gt 0) {
        if (Find-CustomerData) {
            Stop-Script $ExitCheck 'Customer data found in the repo files (see above).'
        }
    }
    else {
        Write-Host 'Note: customer data check skipped (CustomerPatterns is empty).'
    }
    Write-Host 'File checks: ok'
}

#--- Version handling ---------------------------------------------------------

# Compute the next version: Get-NextVersion <current> <patch|minor|major>
function Get-NextVersion {
    param([string]$Current, [string]$Level)
    $p     = @($Current.Split('.') | ForEach-Object { [int]$_ })
    $major = $p[0]
    $minor = $p[1]
    $patch = $p[2]
    switch ($Level) {
        'patch' { $patch++ }
        'minor' { $minor++; $patch = 0 }
        'major' { $major++; $minor = 0; $patch = 0 }
    }
    return "$major.$minor.$patch"
}

# Write the new version into the script
function Set-ScriptVersion {
    param([string]$NewVersion)
    $path = Join-Path $script:RepoDir $script:TargetScript
    Update-FileText $path '^(\$Version[ \t]*=[ \t]*)''[^'']*''' ('${1}' + "'" + $NewVersion + "'")
}

# Write the new config version into the script and the config example
function Set-ConfigVersion {
    param([int]$NewVersion)
    $path    = Join-Path $script:RepoDir $script:TargetScript
    $example = Join-Path $script:RepoDir "$($script:TargetName).config.example"
    Update-FileText $path '^(\$RequiredConfigVersion[ \t]*=[ \t]*)\d+' ('${1}' + $NewVersion)
    Update-FileText $example '^([ \t]*ConfigVersion[ \t]*=[ \t]*)\d+' ('${1}' + $NewVersion)
}

#--- Git steps ----------------------------------------------------------------

# Run a git command that takes a message from a file (avoids quoting problems with
# native commands in Windows PowerShell). $GitArgs come before the message file, which
# is passed as the argument of -F; $Trailing (e.g. the tag name) comes last.
function Invoke-GitWithMessage {
    param([string[]]$GitArgs, [string]$Message, [string[]]$Trailing)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $Message + "`n", $Utf8NoBom)
        $all = @($GitArgs) + @('-F', $tmp)
        if ($Trailing) { $all += $Trailing }
        [void](Invoke-Git $all)
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Stage everything, show the result, ask, commit and push the branch.
# $Prefix is put before the typed commit message (Fix: / Add: / Breaking:), $Default is
# accepted with Enter (first commit), $SetUpstream adds -u to the push.
function Invoke-CommitAndPush {
    param([string]$Prefix, [string]$Default, [bool]$SetUpstream)
    [void](Invoke-Git 'add', '-A')
    if ($script:GitExit -ne 0) { Stop-Script $ExitGit 'git add failed.' }
    $script:Staged = $true
    Write-Step 'Changes'
    Invoke-Git 'status', '--short' | Out-Host
    if (Confirm-Action 'Show the full diff?' $false) {
        Invoke-Git '--no-pager', 'diff', '--cached' | Out-Host
    }
    Assert-Confirmed "Commit these changes and push $($script:Branch)?"
    $msg = Read-Message 'Commit message' $Prefix $Default
    Assert-NoCustomerText $msg
    $script:TagMsg = Read-Message 'Tag message (stored with the tag)' '' $msg
    Assert-NoCustomerText $script:TagMsg

    Invoke-GitWithMessage -GitArgs @('commit', '-q') -Message $msg
    if ($script:GitExit -ne 0) { Stop-Script $ExitGit 'git commit failed.' }
    $script:Committed = $true
    if ($script:BackupDir -and (Test-Path -LiteralPath $script:BackupDir)) {
        Remove-Item -LiteralPath $script:BackupDir -Recurse -Force
    }
    $script:BackupDir = ''

    $pushArgs = @('push')
    if ($SetUpstream) { $pushArgs += '-u' }
    $pushArgs += @('origin', $script:Branch)
    Invoke-Git $pushArgs | Out-Host
    if ($script:GitExit -ne 0) { Stop-Script $ExitGit "git push of $($script:Branch) failed." }
}

# Create the signed tag (if it does not exist yet), verify it locally and push only
# this tag
function Invoke-TagAndPush {
    param([string]$Tag)
    Write-Step "Tag $Tag"
    [void](Invoke-GitQuiet 'rev-parse', '-q', '--verify', "refs/tags/$Tag")
    if ($script:GitExit -ne 0) {
        if (-not $script:TagMsg) {
            $script:TagMsg = Read-Message 'Tag message' '' ''
            Assert-NoCustomerText $script:TagMsg
        }
        Invoke-GitWithMessage -GitArgs @('tag', '-s') -Message $script:TagMsg -Trailing @($Tag)
        if ($script:GitExit -ne 0) { Stop-Script $ExitGit 'Could not create the tag.' }
    }
    Invoke-Git 'tag', '-v', $Tag | Out-Host
    if ($script:GitExit -ne 0) {
        Stop-Script $ExitGit "The signature of $Tag is not valid. The tag was not pushed, remove it locally with: git tag -d $Tag"
    }
    if (-not (Confirm-Action "Signature ok. Push tag $Tag now?" $true)) {
        Stop-Script $ExitAbort "Aborted. The tag $Tag stays local, starting again continues the release."
    }
    Invoke-Git 'push', 'origin', $Tag | Out-Host
    if ($script:GitExit -ne 0) { Stop-Script $ExitGit "Push of $Tag failed." }
    Invoke-Git '--no-pager', 'tag', '-n', '-l', $Tag | Out-Host
    Write-Host "Done: $Tag is pushed."
}

# Continue an interrupted release: the version is raised and committed, but the tag is
# missing (commit pushed) or only exists locally. Returns $true if it handled the
# situation, $false if this is a normal new release.
function Resume-Release {
    param([string]$Current)
    $tag = "v$Current"
    $remoteTag = @(Invoke-Git 'ls-remote', '--tags', 'origin', "refs/tags/$tag")
    if ($script:GitExit -ne 0) { Stop-Script $ExitGit 'git ls-remote failed.' }
    if ($remoteTag.Count -gt 0) { return $false }
    [void](Invoke-GitQuiet 'rev-parse', '-q', '--verify', "refs/tags/$tag")
    if ($script:GitExit -eq 0) {
        Write-Host "The tag $tag exists locally but is not on GitHub yet."
    }
    else {
        $lastTag = Get-LastTag
        if ($lastTag) {
            $lastVersion = $lastTag.Substring(1)
            if ([version]$Current -lt [version]$lastVersion) { return $false }
            if ($Current -eq $lastVersion) { return $false }
        }
        if (@(Invoke-GitQuiet 'status', '--porcelain').Count -ne 0) { return $false }
        $ahead = @(Invoke-GitQuiet 'rev-list', '--count', "origin/$($script:Branch)..HEAD")
        if ($script:GitExit -ne 0 -or [int]$ahead[0] -ne 0) { return $false }
        Write-Host "Version $Current is committed and pushed, but not tagged yet."
    }
    if ($DryRun) {
        Write-Host "Dry-run: starting again would create or push the tag $tag."
        return $true
    }
    Assert-Confirmed "Continue release $tag now?"
    Invoke-TagAndPush $tag
    return $true
}

#--- Flows --------------------------------------------------------------------

# Existing repo: compare the local branch with the GitHub branches. If everything is
# the expected default branch, nothing is asked. Otherwise show the situation and let
# the user choose one of the branches that exist on GitHub.
function Select-Branch {
    $lb = @(Invoke-GitQuiet 'symbolic-ref', '-q', '--short', 'HEAD')
    if ($script:GitExit -ne 0 -or $lb.Count -eq 0) {
        Stop-Script $ExitCheck 'Detached HEAD, please switch to a branch first.'
    }
    $localBranch = "$($lb[0])".Trim()

    $symref = @(Invoke-Git 'ls-remote', '--symref', 'origin', 'HEAD')
    if ($script:GitExit -ne 0) { Stop-Script $ExitGit 'git ls-remote failed.' }
    $remoteDefault = ''
    foreach ($l in $symref) {
        if ("$l" -match '^ref:\s+refs/heads/(.+?)\s+HEAD\s*$') { $remoteDefault = $Matches[1] }
    }
    if (-not $remoteDefault) { Stop-Script $ExitCheck 'There is no branch on GitHub yet (empty repo?).' }
    if (($localBranch -ceq $remoteDefault) -and ($remoteDefault -ceq $Config['DefaultBranch'])) {
        $script:Branch = $localBranch
        return
    }

    Write-Step 'Branch'
    Write-Host "Local branch:          $localBranch"
    Write-Host "GitHub default branch: $remoteDefault"
    Write-Host "Expected (config):     $($Config['DefaultBranch'])"
    $heads = @(Invoke-Git 'ls-remote', '--heads', 'origin' | ForEach-Object { "$_" -replace '^.*refs/heads/', '' })
    if ($script:GitExit -ne 0) { Stop-Script $ExitGit 'git ls-remote failed.' }
    Write-Host 'Branches on GitHub:'
    for ($i = 0; $i -lt $heads.Count; $i++) {
        $note = ''
        if ($heads[$i] -ceq $remoteDefault) { $note += ' (GitHub default)' }
        if ($heads[$i] -ceq $localBranch) { $note += ' (active locally)' }
        Write-Host ('  [{0}] {1}{2}' -f ($i + 1), $heads[$i], $note)
    }
    if ($DryRun) {
        Stop-Script $ExitOk 'Dry-run: the branch would be asked here. The dry-run ends at this point.'
    }
    $choice = "$(Read-Host 'Which branch should the release run on? [number]')".Trim()
    $n = 0
    if (-not [int]::TryParse($choice, [ref]$n) -or $n -lt 1 -or $n -gt $heads.Count) {
        Stop-Script $ExitUsage 'Invalid selection.'
    }
    $script:Branch = $heads[$n - 1]
    if ($script:Branch -cne $localBranch) {
        [void](Invoke-GitQuiet 'show-ref', '-q', '--verify', "refs/heads/$($script:Branch)")
        if ($script:GitExit -eq 0) {
            [void](Invoke-Git 'switch', '-q', $script:Branch)
            if ($script:GitExit -ne 0) {
                Stop-Script $ExitGit "Switching to $($script:Branch) failed (local changes in the way?)."
            }
        }
        else {
            [void](Invoke-Git 'switch', '-q', '-c', $script:Branch, '--track', "origin/$($script:Branch)")
            if ($script:GitExit -ne 0) { Stop-Script $ExitGit "Switching to $($script:Branch) failed." }
        }
        $script:SwitchedFrom = $localBranch
        Write-Host "Now on branch $($script:Branch)."
    }
}

# New repository: start with v1.0.0
function Invoke-FlowNew {
    if (Test-InRepo) {
        Stop-Script $ExitCheck "There is already a Git repo here. Please choose 'existing repo'."
    }
    $name = "$(Read-Host "Repo name [$($script:TargetName)]")".Trim()
    if (-not $name) { $name = $script:TargetName }
    if (-not (Test-RepoName $name)) {
        Stop-Script $ExitUsage "Invalid repo name '$name'. Expected $($script:TargetName) or $($script:TargetName)-<suffix> (letters, digits, . _ -)."
    }
    $script:RepoName = $name
    $url = Get-RemoteUrl $name
    $web = "https://github.com/$($Config['GithubOrg'])/$name"
    $scriptPath = Join-Path $script:RepoDir $script:TargetScript
    $cur = Get-FileVar $scriptPath $PatVersion

    Write-Step "Plan: new repo $name"
    Write-Host "Remote:  $url"
    Write-Host "Version: 1.0.0 (tag v1.0.0), the script says $cur"
    if ($DryRun) {
        Write-Host 'Dry-run: nothing was changed.'
        Write-Host "Before the real run, create the EMPTY public repo: $web (no README, .gitignore or license)."
        return
    }

    Assert-Confirmed "README.md, INSTALL.md and $($script:TargetName).config.example are up to date?"
    Write-Host ''
    Write-Host 'NOW create the empty public repo on GitHub:'
    Write-Host "  $web"
    Write-Host "  (organisation $($Config['GithubOrg']), public, without README, .gitignore and license)"
    [void](Read-Host 'Press Enter when the repo is created')
    $refs = @(Invoke-Git 'ls-remote', $url)
    if ($script:GitExit -ne 0) { Stop-Script $ExitGit "Repo $url is not reachable (see the message above)." }
    if ($refs.Count -gt 0) { Stop-Script $ExitCheck "The repo $url is not empty." }

    Backup-Files
    if ($cur -ne '1.0.0') {
        Assert-Confirmed "The version in the script is $cur. Set it to 1.0.0?"
        Set-ScriptVersion '1.0.0'
    }
    $script:Branch = $Config['DefaultBranch']
    [void](Invoke-Git 'init', '-q', '-b', $script:Branch)
    if ($script:GitExit -ne 0) { Stop-Script $ExitGit 'git init failed.' }
    $script:CreatedGit = $true
    [void](Invoke-Git 'remote', 'add', 'origin', $url)
    if ($script:GitExit -ne 0) { Stop-Script $ExitGit 'git remote add failed.' }
    Invoke-CommitAndPush '' 'Initial version' $true
    Invoke-TagAndPush 'v1.0.0'
}

# Existing repository: raise the version
function Invoke-FlowExisting {
    if (-not (Test-InRepo)) {
        Stop-Script $ExitCheck "There is no Git repo here. Please choose 'new repo'."
    }
    $topLines = @(Invoke-GitQuiet 'rev-parse', '--show-toplevel')
    $top = (Resolve-Path -LiteralPath "$($topLines[0])").ProviderPath
    if ($top.TrimEnd('\') -ine $script:RepoDir.TrimEnd('\')) {
        Stop-Script $ExitCheck "Please run this in the top directory of the repo ($top)."
    }
    $origin = "$(@(Invoke-GitQuiet 'remote', 'get-url', 'origin') | Select-Object -First 1)".Trim()
    $name = Get-RepoNameFromOrigin $origin
    if (-not $name) {
        Stop-Script $ExitCheck "Remote 'origin' ($origin) does not match RemoteUrlTemplate."
    }
    if (-not (Test-RepoName $name)) {
        Stop-Script $ExitCheck "Remote 'origin' points to repo '$name', which does not fit the script '$($script:TargetName)' (expected $($script:TargetName) or $($script:TargetName)-<suffix>)."
    }
    $script:RepoName = $name
    [void](Invoke-Git 'fetch', '-q', 'origin', '--tags')
    if ($script:GitExit -ne 0) { Stop-Script $ExitGit 'git fetch failed.' }
    Select-Branch
    $behind = @(Invoke-GitQuiet 'rev-list', '--count', "HEAD..origin/$($script:Branch)")
    if ($script:GitExit -ne 0) { Stop-Script $ExitGit "git rev-list failed (does origin/$($script:Branch) exist?)." }
    if ([int]$behind[0] -ne 0) {
        Stop-Script $ExitCheck "origin/$($script:Branch) has newer commits. Run git pull first."
    }

    $scriptPath  = Join-Path $script:RepoDir $script:TargetScript
    $examplePath = Join-Path $script:RepoDir "$($script:TargetName).config.example"
    $cur = Get-FileVar $scriptPath $PatVersion
    if (Resume-Release $cur) { return }

    $lastTag = Get-LastTag
    if (-not $lastTag) { Stop-Script $ExitCheck 'No tag found. Is this a new repo?' }
    if ($cur -ne $lastTag.Substring(1)) {
        Stop-Script $ExitCheck "The version in the script ($cur) does not match the last tag ($lastTag). Do not change the version by hand, this script does it. If a release was interrupted: commit and push all other changes (or set them aside) first, then starting again continues the release."
    }
    [void](Invoke-GitQuiet 'diff', '--quiet', $lastTag)
    $noDiff = ($script:GitExit -eq 0)
    $dirty  = (@(Invoke-GitQuiet 'status', '--porcelain').Count -ne 0)
    if ($noDiff -and -not $dirty) { Stop-Script $ExitCheck "No changes since $lastTag." }

    Write-Step "Plan: $($script:TargetName), repo $name, branch $($script:Branch), last tag $lastTag"
    Write-Host 'Which level?'
    Write-Host '  [1] Patch  (bug fix)'
    Write-Host '  [2] Minor  (new feature, config unchanged)'
    Write-Host '  [3] Major  (config or behaviour incompatible)'
    $sel = "$(Read-Host 'Selection [1/2/3]')".Trim()
    switch ($sel) {
        '1' { $level = 'patch'; $prefix = 'Fix: ' }
        '2' { $level = 'minor'; $prefix = 'Add: ' }
        '3' { $level = 'major'; $prefix = 'Breaking: ' }
        default { Stop-Script $ExitUsage 'Invalid selection.' }
    }
    $new = Get-NextVersion $cur $level

    # Config version rules: a changed ConfigVersion always means a major release
    $cfgNow  = Get-FileVar $examplePath $PatConfigVer
    $tagText = (@(Invoke-GitQuiet 'show', "${lastTag}:$($script:TargetName).config.example")) -join "`n"
    $cfgTag  = Get-TextVar $tagText $PatConfigVer
    if (-not $cfgTag) { Stop-Script $ExitCheck "Cannot read ConfigVersion in $lastTag." }
    if (($cfgNow -ne $cfgTag) -and ($level -ne 'major')) {
        Stop-Script $ExitCheck "ConfigVersion was changed ($cfgTag -> $cfgNow). That is always a major release."
    }
    $newCfg = $null
    if (($level -eq 'major') -and ($cfgNow -eq $cfgTag)) { $newCfg = [int]$cfgNow + 1 }

    Write-Host "New version: $new (tag v$new)"
    if ($null -ne $newCfg) {
        Write-Host "ConfigVersion: $cfgNow -> $newCfg (script and .config.example)"
    }
    $remoteNew = @(Invoke-Git 'ls-remote', '--tags', 'origin', "refs/tags/v$new")
    if ($remoteNew.Count -gt 0) { Stop-Script $ExitCheck "Tag v$new already exists on GitHub." }
    [void](Invoke-GitQuiet 'rev-parse', '-q', '--verify', "refs/tags/v$new")
    if ($script:GitExit -eq 0) { Stop-Script $ExitCheck "Tag v$new already exists locally." }
    if ($DryRun) {
        Write-Host 'Dry-run: nothing was changed.'
        return
    }

    Assert-Confirmed "README.md, INSTALL.md and $($script:TargetName).config.example are up to date?"
    Backup-Files
    Set-ScriptVersion $new
    if ($null -ne $newCfg) { Set-ConfigVersion $newCfg }
    Invoke-CommitAndPush $prefix '' $false
    Invoke-TagAndPush "v$new"
}

#--- Main ---------------------------------------------------------------------

$exitCode = $ExitOk
try {
    # --- Load config (data only, nothing is executed) ---
    Assert-ConfigAcl $ConfigFile
    # Windows PowerShell 5.1 reads a file without BOM as ANSI, so umlauts would be garbled
    Assert-AsciiFile $ConfigFile "For a word with an umlaut use the part without it (e.g. 'ller' for a word like 'Mueller' written with an umlaut)." $ExitConfig
    try {
        $Config = Import-PowerShellDataFile -Path $ConfigFile
    }
    catch {
        Stop-Script $ExitConfig "Cannot read ${ConfigFile}: $($_.Exception.Message)"
    }
    if ($Config['ConfigVersion'] -ne $RequiredConfigVersion) {
        Stop-Script $ExitConfig "ConfigVersion '$($Config['ConfigVersion'])' does not match required '$RequiredConfigVersion'."
    }
    foreach ($key in @('GithubOrg', 'DefaultBranch', 'RemoteUrlTemplate', 'MinGitVersion')) {
        if (-not $Config[$key]) { Stop-Script $ExitConfig "$key is not set in the config." }
    }
    if (-not "$($Config['RemoteUrlTemplate'])".Contains('{name}')) {
        Stop-Script $ExitConfig 'RemoteUrlTemplate in the config must contain {name} (the repo name).'
    }
    if ($Config.ContainsKey('CustomerPatterns') -and $Config['CustomerPatterns']) {
        $script:Patterns = @(@($Config['CustomerPatterns']) | Where-Object { "$_" -ne '' })
    }

    if ($DryRun) { Write-Host '*** DRY-RUN: nothing will be changed ***' }
    Test-Preflight
    Find-Target
    Write-Host "Script in the current directory: $($script:TargetScript)"
    Test-RepoFiles

    Write-Host ''
    Write-Host 'What should happen?'
    Write-Host '  [1] Create a new repo (start with v1.0.0)'
    Write-Host '  [2] Existing repo: script changed, raise the version'
    $mode = "$(Read-Host 'Selection [1/2]')".Trim()
    switch ($mode) {
        '1' { Invoke-FlowNew }
        '2' { Invoke-FlowExisting }
        default { Stop-Script $ExitUsage 'Invalid selection.' }
    }
}
catch {
    $exitCode = $ExitError
    $known = $_.Exception.Data.Contains('ExitCode')
    if ($known) { $exitCode = [int]$_.Exception.Data['ExitCode'] }
    Invoke-Rollback
    $msg = $_.Exception.Message
    if (-not $known) { $msg = "Unexpected error: $msg (line $($_.InvocationInfo.ScriptLineNumber))" }
    if ($exitCode -eq $ExitOk) { Write-Host $msg }
    elseif ($exitCode -eq $ExitAbort) { [Console]::Error.WriteLine($msg) }
    else { [Console]::Error.WriteLine("ERROR: $msg") }
}
finally {
    # Also runs on Ctrl-C: undo the local changes of an unfinished run
    Invoke-Rollback
}
exit $exitCode
