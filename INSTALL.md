# Installation: push-scriptupdate (Windows)

Interactive PowerShell script for the development PC. It releases PowerShell scripts
that have their own GitHub repo: it checks the working copy, raises the version,
commits, pushes the branch, creates and verifies a signed tag and pushes the tag.
Runs as a normal user in Windows PowerShell 5.1, no administrator rights needed.

All commands are meant to be pasted into **one PowerShell window**. The variables from
step 0 only exist in that window. If you open a new window, repeat step 0.

## 0. Variables

```powershell
$InstallDir = Join-Path $HOME 'bin'
$ScriptName = 'push-scriptupdate'
$RepoName   = 'push-scriptupdate-win'
$ConfigFile = Join-Path $InstallDir "$ScriptName.config"
$Tool       = Join-Path $InstallDir "$ScriptName.ps1"
$Tag        = 'v1.0.0'
```

The script and its config live together in `$InstallDir`. This is a tool on your PC,
so it is not installed under `C:\scripts`.

## 1. Prerequisites

Git for Windows 2.34 or newer and the Windows OpenSSH client (part of Windows):

```powershell
git --version
ssh -V
```

The signing setup on this PC (signing key, `allowed_signers`, Git configuration and the
public commit mail) is described in your internal howtos. Check that it is in place:

```powershell
git config --get gpg.format
git config --get user.signingkey
git config --get tag.gpgSign
git config --get gpg.ssh.allowedSignersFile
git config --get gpg.ssh.program
git config --get user.email
ssh-add -l
ssh -T git@github.com
```

Expected: `ssh`, the path of your signing key, `true`, the path of `allowed_signers`, the
path of the Windows `ssh-keygen`, a `...@users.noreply.github.com` address, the keys in
your ssh-agent and a greeting with your GitHub user name (the last command exits with
code 1, that is normal).

## 2. Allow local scripts

A fresh Windows client does not run `.ps1` files. Allow locally created and copied
scripts for your user only:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
Get-ExecutionPolicy -List
```

Expected: `RemoteSigned` in the scope `CurrentUser`.

## 3. Install the files

```powershell
New-Item -ItemType Directory -Force $InstallDir | Out-Null
```

### Variant A: release path (signed tag)

The files are only copied if the signature check succeeds:

```powershell
$Work = Join-Path $env:TEMP ([guid]::NewGuid().ToString())
git clone "https://github.com/it-flows-de/$RepoName.git" (Join-Path $Work $RepoName)
Set-Location (Join-Path $Work $RepoName)
git verify-tag $Tag
if ($LASTEXITCODE -eq 0) {
    git checkout $Tag
    Copy-Item "$ScriptName.ps1", "$ScriptName.config.example" $InstallDir
    Write-Host "OK: signature verified, files installed to $InstallDir"
} else {
    Write-Host 'STOP: signature check failed, nothing was installed'
}
Set-Location $HOME
Remove-Item -Recurse -Force $Work
```

### Variant B: development path (only before the first release)

Create the files and copy the content from the ZIP with VS Code or another editor of
your choice. The command fails if a file already exists, so it cannot overwrite
anything:

```powershell
Set-Location $InstallDir
New-Item -ItemType File "$ScriptName.ps1", "$ScriptName.config.example" | Out-Null
code $InstallDir
```

If you copied the files from a downloaded ZIP, remove the download mark, otherwise
Windows blocks the script:

```powershell
Get-ChildItem $InstallDir | Unblock-File
```

## 4. Check the PATH

```powershell
($env:Path -split ';') -contains $InstallDir
```

If the result is `False`, add the directory to the PATH of your user and open a new
PowerShell window (then repeat step 0):

```powershell
$userPath = "$([Environment]::GetEnvironmentVariable('Path', 'User'))"
if (($userPath -split ';') -notcontains $InstallDir) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $InstallDir), 'User')
}
```

Check in the new window:

```powershell
Get-Command push-scriptupdate.ps1
```

## 5. Config

```powershell
Set-Location $InstallDir
Copy-Item "$ScriptName.config.example" $ConfigFile
code $ConfigFile
Import-PowerShellDataFile $ConfigFile
```

The config is a PowerShell data file: it is read, but nothing in it is executed. It
stays on this PC and is never committed. Fill `CustomerPatterns` with the words that must
never appear in a public repo, see the comments in the file. Two rules apply: separate
the words with **commas** (`@('a', 'b')`, not spaces as in the Bash config) and use
**ASCII only**. Windows PowerShell 5.1 reads a file without BOM as ANSI, so an umlaut
would be garbled. For a word with an umlaut use the part without it.

The script refuses to start if anyone except you, SYSTEM and Administrators may write
the config. A file in your user profile is fine. To check:

```powershell
icacls $ConfigFile
```

## 6. Test

The tests call the script by its full path (`$Tool`), so they also work in a window
that does not know the new PATH yet.

Help:

```powershell
Get-Help $Tool
```

Error case: wrong permissions on the config (expected: error message, exit code 3):

```powershell
icacls $ConfigFile /grant "*S-1-1-0:(W)"
& $Tool
"exit code: $LASTEXITCODE"
icacls $ConfigFile /remove "*S-1-1-0"
```

Dry-run in a scratch working copy (checks only, changes nothing). The commands create a
minimal script with its files:

```powershell
$Test = Join-Path $HOME 'dryrun-test'
New-Item -ItemType Directory $Test | Out-Null
Set-Location $Test
@(
    '$Version               = ''1.0.0''',
    '$RequiredConfigVersion = 1',
    'Write-Host ''hello'''
) | Set-Content dryrun-test.ps1 -Encoding Ascii
'@{', '    ConfigVersion = 1', '}' | Set-Content dryrun-test.config.example -Encoding Ascii
'*.config', '*.secrets' | Set-Content .gitignore -Encoding Ascii
'# dryrun-test' | Set-Content README.md -Encoding Ascii
'# Installation' | Set-Content INSTALL.md -Encoding Ascii
& $Tool -DryRun
```

Choose `1` (new repo) and press Enter at the repo name prompt. Expected: `File checks: ok`,
the plan with the remote URL and the
note that the empty public repo must be created before a real run, and
`Dry-run: nothing was changed.`

Clean up:

```powershell
Set-Location $HOME
Remove-Item -Recurse -Force $Test
```

## Troubleshooting

| Message or exit code | Meaning | What to check |
|---|---|---|
| `running scripts is disabled on this system` | Execution policy | Step 2 |
| `... is not digitally signed` or "blocked" | Files carry a download mark | `Get-ChildItem $InstallDir \| Unblock-File` |
| `push-scriptupdate.ps1` is not found | PATH | Step 4, open a new window |
| 0 | OK | - |
| 1 | Unexpected error | Read the message and the line number |
| 2 | Invalid menu selection | Choose one of the numbers shown |
| 3 | Config error | Config exists, `ConfigVersion` matches, `GithubOrg` is set, the config is ASCII only, only you, SYSTEM and Administrators may write the file (fix: `icacls $ConfigFile /inheritance:r /grant:r "${env:USERNAME}:(M)" "*S-1-5-18:(F)" "*S-1-5-32-544:(F)"`) |
| `Import-PowerShellDataFile` cannot parse the config | Syntax error in the config | Find the line: `$t = $null; $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($ConfigFile, [ref]$t, [ref]$e); $e \| ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }` (usual cause: words in `CustomerPatterns` separated by spaces instead of commas) |
| 5 | A check failed | Read the message: git setup, missing files, customer data, version mismatch, non-ASCII characters in the script |
| 6 | Aborted by you | Local changes of the run were reverted, start again |
| 7 | Git operation failed | Read the message: network, push access, signature |
