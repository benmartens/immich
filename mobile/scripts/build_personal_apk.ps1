[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $HOME 'OneDrive\temp'),
    [string]$SigningConfig = (Join-Path $HOME '.android\immich-martens-signing.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)

    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Executable failed with exit code $LASTEXITCODE."
    }
}

if (-not $IsWindows) {
    throw 'The personal APK build requires PowerShell 7 on Windows.'
}

$mobile = Split-Path $PSScriptRoot -Parent
$repository = Split-Path $mobile -Parent
$branch = Invoke-Checked git @('-C', $repository, 'branch', '--show-current')
if ($branch -ne 'personal-build') {
    throw 'Check out personal-build before building the personal APK.'
}

if (-not (Test-Path -LiteralPath $SigningConfig -PathType Leaf)) {
    throw "Private signing configuration is missing: $SigningConfig. Restore the existing signing key and credentials; do not generate a replacement key."
}
$signing = Get-Content -LiteralPath $SigningConfig -Raw | ConvertFrom-Json -AsHashtable
foreach ($field in 'keystore', 'alias', 'storePassword', 'keyPassword') {
    if ($signing[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($signing[$field])) {
        throw "The signing configuration requires a nonempty string for $field."
    }
}
if (-not [System.IO.Path]::IsPathFullyQualified($signing.keystore) -or
    -not (Test-Path -LiteralPath $signing.keystore -PathType Leaf)) {
    throw 'The signing configuration must point to the existing personal keystore using an absolute path.'
}

$env:ALIAS = $signing.alias
$env:ANDROID_KEYSTORE_FILE = $signing.keystore
$env:ANDROID_STORE_PASSWORD = $signing.storePassword
$env:ANDROID_KEY_PASSWORD = $signing.keyPassword
$env:PR_NUMBER = 'martens'
$env:IMMICH_APP_LABEL = 'Immich Martens'

$certificatePem = Invoke-Checked keytool @(
    '-exportcert', '-rfc', '-keystore', $signing.keystore,
    '-alias', $signing.alias, '-storepass:env', 'ANDROID_STORE_PASSWORD'
)
$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem(
    ($certificatePem -join "`n")
)
try {
    $fingerprint = $certificate.GetCertHashString([System.Security.Cryptography.HashAlgorithmName]::SHA256)
} finally {
    $certificate.Dispose()
}
if ($fingerprint -ne 'FBB0DF573B3758F569391C510E47BE64450256324FA9422DEC97DD888E466135') {
    throw 'The signing certificate does not match the existing Immich Martens app. Restore the original key to preserve upgrade compatibility.'
}

if (-not $env:ANDROID_HOME) {
    $env:ANDROID_HOME = if ($env:ANDROID_SDK_ROOT) {
        $env:ANDROID_SDK_ROOT
    } else {
        Join-Path $env:LOCALAPPDATA 'Android\sdk'
    }
}
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$buildTools = Get-ChildItem (Join-Path $env:ANDROID_HOME 'build-tools') -Directory |
    Where-Object Name -Match '^\d+\.\d+\.\d+$' |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $buildTools) {
    throw 'Install Android SDK build-tools before building the personal APK.'
}
$aapt = Join-Path $buildTools.FullName 'aapt2.exe'
$apksigner = Join-Path $buildTools.FullName 'apksigner.bat'
foreach ($tool in $aapt, $apksigner) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Required Android build tool is missing: $tool"
    }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw 'Install Visual Studio Build Tools with Desktop development with C++ and the Windows SDK.'
}
$visualStudio = Invoke-Checked $vswhere @(
    '-latest', '-products', '*', '-requires',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'
)
if (-not $visualStudio) {
    throw 'Visual Studio C++ build tools were not found.'
}
$vcvars = Join-Path $visualStudio 'VC\Auxiliary\Build\vcvars64.bat'
$developerEnvironment = Invoke-Checked $env:ComSpec @('/d', '/c', "call `"$vcvars`" >nul && set")
$compilerEnvironment = @{}
foreach ($line in $developerEnvironment) {
    if ($line -match '^([^=]+)=(.*)$') {
        $compilerEnvironment[$Matches[1]] = $Matches[2]
    }
}
foreach ($field in 'LIB', 'INCLUDE', 'VCToolsInstallDir') {
    if (-not $compilerEnvironment[$field]) {
        throw "Visual Studio did not provide $field."
    }
}
$compilerDirectory = Join-Path $compilerEnvironment.VCToolsInstallDir 'bin\Hostx64\x64'
$nasmDirectory = Invoke-Checked mise @('where', 'conda:nasm')
$nasm = Join-Path $nasmDirectory 'Library\bin\nasm.exe'
$linker = Join-Path $compilerDirectory 'link.exe'
$compiler = Join-Path $compilerDirectory 'cl.exe'
$archiver = Join-Path $compilerDirectory 'lib.exe'
foreach ($tool in $nasm, $linker, $compiler, $archiver) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Required native build tool is missing: $tool"
    }
}

$version = [regex]::Match(
    (Get-Content (Join-Path $mobile 'pubspec.yaml') -Raw),
    '(?m)^version:\s*([^+\s]+)\+(\d+)\s*$'
)
if (-not $version.Success) {
    throw 'pubspec.yaml must specify an application version and build number.'
}
$versionName = $version.Groups[1].Value
$versionCode = $version.Groups[2].Value
$revision = Invoke-Checked git @('-C', $repository, 'rev-parse', '--short', 'HEAD')
$dirty = Invoke-Checked git @('-C', $repository, 'status', '--porcelain', '--untracked-files=normal')
if ($dirty) {
    Write-Warning 'Building uncommitted changes; the APK filename will include -dirty.'
}
if (-not (Test-Path (Join-Path $mobile '.dart_tool\package_config.json') -PathType Leaf)) {
    throw 'Prepare the mobile checkout with mise //mobile:checkout before building.'
}

$cargoConfig = Join-Path $repository 'native\native_core\.cargo\config.toml'
if (Test-Path -LiteralPath $cargoConfig) {
    throw "A local Cargo configuration already exists at $cargoConfig. Leave it intact and resolve this conflict before building."
}
$settings = @(
    '[target.x86_64-pc-windows-msvc]'
    "linker = $(ConvertTo-Json $linker -Compress)"
    ''
    '[env]'
)
$nativeEnvironment = [ordered]@{
    LIB = $compilerEnvironment.LIB
    INCLUDE = $compilerEnvironment.INCLUDE
    CC = $compiler
    CXX = $compiler
    AR = $archiver
    NASM = $nasm
}
foreach ($entry in $nativeEnvironment.GetEnumerator()) {
    $settings += "$($entry.Key) = { value = $(ConvertTo-Json $entry.Value -Compress), force = true }"
}
$cargoContents = ($settings -join "`n") + "`n"
[System.IO.Directory]::CreateDirectory((Split-Path $cargoConfig -Parent)) | Out-Null
$stream = [System.IO.File]::Open($cargoConfig, 'CreateNew', 'Write', 'Read')
try {
    try {
        $stream.Write([System.Text.UTF8Encoding]::new($false).GetBytes($cargoContents))
    } finally {
        $stream.Dispose()
    }
    Invoke-Checked mise @(
        '//mobile:build:android:apk', '--', '--build-name', $versionName, '--build-number', $versionCode
    )
} finally {
    if ([System.IO.File]::ReadAllText($cargoConfig) -ne $cargoContents) {
        throw "The temporary Cargo configuration changed during the build and was preserved: $cargoConfig"
    }
    Remove-Item -LiteralPath $cargoConfig
}

$apk = Join-Path $mobile 'build\app\outputs\flutter-apk\app-release.apk'
$badging = Invoke-Checked $aapt @('dump', 'badging', $apk)
$package = [regex]::Match(
    ($badging -join "`n"),
    "(?m)^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'"
)
if (-not $package.Success -or $package.Groups[1].Value -ne 'app.alextran.immich.prmartens' -or
    $package.Groups[2].Value -ne $versionCode -or $package.Groups[3].Value -ne "$versionName-prmartens" -or
    -not ($badging -cmatch "^application-label:'Immich Martens'$") -or
    ($badging -match '^application-debuggable')) {
    throw 'The APK does not have the expected personal release identity, label, and version.'
}
$signature = Invoke-Checked $apksigner @('verify', '--verbose', '--print-certs', $apk)
$signer = [regex]::Match(
    ($signature -join "`n"),
    '(?m)^Signer #1 certificate SHA-256 digest: ([0-9a-f]+)\r?$'
)
if (-not $signer.Success -or $signer.Groups[1].Value -ne $fingerprint) {
    throw 'The release APK was not signed with the original personal key.'
}
$archive = [System.IO.Compression.ZipFile]::OpenRead($apk)
try {
    foreach ($abi in 'arm64-v8a', 'armeabi-v7a', 'x86_64') {
        foreach ($library in 'libflutter.so', 'libapp.so', 'libnative_core_ffi.so') {
            if (-not $archive.GetEntry("lib/$abi/$library")) {
                throw "The release APK is missing $library for $abi."
            }
        }
    }
} finally {
    $archive.Dispose()
}

$timestamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
$suffix = if ($dirty) { '-dirty' } else { '' }
$filename = "Immich-Martens-v$versionName-$timestamp-$revision$suffix.apk"
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$destination = Join-Path $OutputDirectory $filename
[System.IO.File]::Copy($apk, $destination, $false)
$sourceHash = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash
if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $sourceHash) {
    Remove-Item -LiteralPath $destination
    throw 'The copied APK checksum does not match the verified release.'
}
Write-Host "Saved signed Immich Martens release: $destination"
Write-Host "SHA256: $sourceHash"
