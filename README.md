# push-scriptupdate (Windows)

Interactive PowerShell script that releases PowerShell scripts which have their own
public GitHub repo. It checks the working copy, raises the version, commits, pushes the
branch, creates a signed Git tag, verifies the signature and pushes the tag.

## How it works

Run it in the top directory of the working copy of the script you want to release. The
directory must contain exactly one `*.ps1`; its name is the script name. The repo is
named like the script, optionally with a suffix such as `-win`. Choose:

- **New repo:** the script asks for the repo name (Enter takes the script name). After you created the empty public repo on GitHub, it runs `git init`, commits, pushes and creates the tag `v1.0.0`.
- **Existing repo:** the repo name is taken from `origin` and must be the script name or the script name plus a suffix. You choose the level (patch, minor, major). The script raises `$Version` (and `$RequiredConfigVersion` plus `ConfigVersion` in the config example on a major release), commits, pushes the branch and creates the next tag.

Before anything is changed it checks, among other things:

- the signing setup of Git on this PC and the public commit mail
- required files, `.gitignore` and that no config or secrets file is tracked
- the version lines are consistent (a changed config version is always a major release)
- the script and the config example contain only ASCII, the script has no syntax errors and, if PSScriptAnalyzer is installed, no analyzer errors
- optional customer words that must not appear in the repo files or in commit and tag messages
- the branch: if the local branch or the GitHub default branch is not the expected one, you choose one of the branches that exist on GitHub

Commit and tag messages: you type the text, the script puts `Fix: `, `Add: ` or
`Breaking: ` in front of the commit message (the first commit is `Initial version`).
The tag message defaults to the commit message. If a run is aborted before the commit
(also with Ctrl-C), all changes of the run are reverted. An interrupted release (commit
pushed, tag missing or only local) is continued by starting the script again.

The script reads the version from the lines `$Version = 'x.y.z'` and
`$RequiredConfigVersion = N` at the start of a line in the script to release, and
`ConfigVersion = N` in its `.config.example`.

## Requirements

- Windows PowerShell 5.1, Git for Windows 2.34 or newer, the Windows OpenSSH client; PSScriptAnalyzer is optional
- A normal user on the development PC, with the signing key and push access to GitHub

## Installation

See [INSTALL.md](INSTALL.md).

## Configuration

Copy `push-scriptupdate.config.example` to `push-scriptupdate.config` next to the
script and edit it. The example file is commented and documents every parameter. The
config is a PowerShell data file (read, never executed), ASCII only, and is never
committed to Git. The script refuses to start if anyone except you, SYSTEM and
Administrators may write the file.

| Parameter           | Block    | Meaning                                                         | Default                                |
|---------------------|----------|-----------------------------------------------------------------|----------------------------------------|
| `ConfigVersion`     | -        | Config format version, must match the script                    | `1`                                    |
| `GithubOrg`         | required | GitHub organisation that holds the script repos                 | `it-flows-de`                          |
| `CustomerPatterns`  | optional | Words that must never appear in the repo, empty = check skipped | `@()`                                  |
| `DefaultBranch`     | default  | Branch for new repos and the expected branch                    | `'main'`                               |
| `RemoteUrlTemplate` | default  | SSH remote, `{org}` = `GithubOrg`, `{name}` = repo name         | `'git@github.com:{org}/{name}.git'`    |
| `MinGitVersion`     | default  | Minimum Git version                                             | `'2.34'`                               |
| `CommitMailDomain`  | default  | Required domain of the commit mail, empty = check skipped       | `'users.noreply.github.com'`           |

## Usage

`push-scriptupdate.ps1 [-DryRun]`, help with `Get-Help push-scriptupdate.ps1`.

| Option    | Meaning                                          |
|-----------|--------------------------------------------------|
| `-DryRun` | Run all checks and show the plan, change nothing |

## Exit codes

| Code | Meaning                                                                                              |
|------|------------------------------------------------------------------------------------------------------|
| 0    | OK                                                                                                   |
| 1    | Unexpected error                                                                                     |
| 2    | Invalid menu selection                                                                               |
| 3    | Config error (missing file, unsafe permissions, non-ASCII, wrong `ConfigVersion`, `GithubOrg` not set) |
| 5    | A check failed                                                                                       |
| 6    | Aborted by the user (local changes of the run were reverted)                                         |
| 7    | A Git operation failed (network, push access, signature)                                             |
