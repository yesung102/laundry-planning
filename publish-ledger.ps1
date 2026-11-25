#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$owner = 'yesung102'
$repository = 'laundry-planning'
$collaborator = 'HongDanaa'
$fullName = "$owner/$repository"
$apiRoot = "repos/$fullName"
$entry = Join-Path $PSScriptRoot 'index.html'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $utf8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Find-GitHubCli {
    $installed = Get-Command gh.exe -ErrorAction SilentlyContinue
    if ($installed) { return $installed.Source }
    Write-Host '공식 GitHub CLI 휴대용 버전을 내려받습니다.'
    $release = Invoke-RestMethod 'https://api.github.com/repos/cli/cli/releases/latest' -TimeoutSec 30
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $asset = @($release.assets | Where-Object { $_.name -match "_windows_${arch}\.zip$" })
    if ($asset.Count -ne 1 -or $asset[0].digest -notmatch '^sha256:[a-fA-F0-9]{64}$') {
        throw '공식 CLI 파일 또는 검증값을 확인하지 못했습니다. https://cli.github.com 에서 GitHub CLI 설치 후 다시 실행해 주세요.'
    }
    $cache = Join-Path ([IO.Path]::GetTempPath()) ('laundry-gh-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $cache
    $zip = Join-Path $cache 'gh.zip'
    Invoke-WebRequest -UseBasicParsing -Uri $asset[0].browser_download_url -OutFile $zip -TimeoutSec 120
    if (('sha256:' + (Get-FileHash $zip -Algorithm SHA256).Hash) -ne $asset[0].digest) {
        throw 'GitHub CLI 다운로드 검증에 실패했습니다.'
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $cache
    $exe = @(Get-ChildItem -LiteralPath $cache -Recurse -File -Filter gh.exe)
    if ($exe.Count -ne 1) { throw '압축 파일 안의 gh.exe를 확인하지 못했습니다.' }
    return $exe[0].FullName
}

function Invoke-GhApi {
    param([string]$Endpoint, [string]$Method='GET', [hashtable]$Body, [switch]$AllowMissing)
    $argsList = @('api','--hostname','github.com','-X',$Method,$Endpoint)
    $ErrorActionPreference = 'Continue'
    if ($null -ne $Body) {
        $argsList += @('--input','-')
        $payload = ConvertTo-Json $Body -Depth 6 -Compress
        $result = $payload | & $gh @argsList 2>&1
    } else {
        $result = & $gh @argsList 2>&1
    }
    $exitCode = $LASTEXITCODE
    $response = ($result | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        if ($AllowMissing -and $response -match 'HTTP 404') { return $null }
        throw "$Method $Endpoint 요청 실패: $response"
    }
    if ($response.Trim()) { return ($response | ConvertFrom-Json) }
}

function Publish-Ledger {
    if (!(Test-Path -LiteralPath $entry -PathType Leaf)) { throw "기획 장부를 찾지 못했습니다: $entry" }
    $gh = Find-GitHubCli
    & { $ErrorActionPreference = 'Continue'; & $gh auth status --hostname github.com *> $null }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "GitHub에서 $owner 계정으로 로그인해 주세요."
        & $gh auth login --hostname github.com --web --git-protocol https
        if ($LASTEXITCODE -ne 0) { throw '로그인이 끝나지 않았습니다.' }
    }
    $account = Invoke-GhApi 'user'
    if ($account.login -ne $owner) { throw "로그인된 계정은 $($account.login)입니다. GitHub CLI에서 $owner 계정으로 전환해 주세요." }

    $repo = Invoke-GhApi $apiRoot -AllowMissing
    if ($null -eq $repo) {
        $repo = Invoke-GhApi 'user/repos' -Method POST -Body @{name=$repository; private=$false; auto_init=$true; description='세탁소 경영 시뮬레이션 기획 장부'}
        Write-Host "공개 저장소 생성: $($repo.html_url)"
        $repo = Invoke-GhApi $apiRoot
    }
    if ($repo.full_name -ne $fullName -or $repo.private -or !$repo.permissions.admin) {
        throw '대상 저장소의 소유자·공개 상태·관리 권한을 확인해 주세요.'
    }
    $branch = $repo.default_branch
    $branchRef = [Uri]::EscapeDataString($branch)
    $remote = Invoke-GhApi "$apiRoot/contents/index.html?ref=$branchRef" -AllowMissing
    $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($entry))
    if ($null -eq $remote) {
        $null = Invoke-GhApi "$apiRoot/contents/index.html" -Method PUT -Body @{message='Publish laundry planning ledger'; content=$content; branch=$branch}
        Write-Host '기획 장부 업로드 완료'
    } elseif (($remote.content -replace '\s','') -cne $content) {
        throw '저장소에 내용이 다른 index.html이 있습니다. 두 파일을 비교한 뒤 배포해 주세요.'
    } else { Write-Host '같은 장부가 이미 업로드되어 있습니다.' }

    $pages = Invoke-GhApi "$apiRoot/pages" -AllowMissing
    if ($null -eq $pages) {
        $pages = Invoke-GhApi "$apiRoot/pages" -Method POST -Body @{build_type='legacy'; source=@{branch=$branch; path='/'}}
    } elseif ($pages.build_type -eq 'workflow' -or $pages.source.branch -ne $branch -or $pages.source.path -ne '/') {
        throw '기존 Pages 배포 경로가 다릅니다. 저장소의 Pages 설정을 확인해 주세요.'
    }
    $url = $pages.html_url
    Write-Host "Pages 설정 주소: $url"

    $person = Invoke-GhApi "users/$collaborator"
    $invited = Invoke-GhApi "$apiRoot/collaborators/$($person.login)" -Method PUT -Body @{permission='push'}
    if ($invited.id) { Write-Host "$collaborator 참여 초대 확인 (초대 번호 $($invited.id))" }
    else { Write-Host "$collaborator 참여 권한 요청 확인 (GitHub가 새 초대 번호 없이 처리)" }

    Write-Host '공개 페이지가 열릴 때까지 확인합니다.'
    for ($i=0; $i -lt 60; $i++) {
        try {
            $page = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 12
            $markup = $utf8.GetString($page.RawContentStream.ToArray())
            if ($page.StatusCode -eq 200 -and $markup.Contains('<title>세탁소 기획 장부</title>')) {
                Write-Host "공유 주소 확인 완료: $url"
                return
            }
        } catch { Write-Verbose $_.Exception.Message }
        if ($i -lt 59) { Start-Sleep -Seconds 10 }
    }
    throw "Pages는 설정됐지만 아직 게시를 확인하지 못했습니다. 상태 확인: https://github.com/$fullName/settings/pages"
}

try { Publish-Ledger }
catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }

