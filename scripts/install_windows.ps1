# Anicat Windows installer. Downloads the latest release into
# %LOCALAPPDATA%\Programs\Anicat, adds a Start menu shortcut and opens it.
# No administrator rights. Running it again is how Anicat is updated.
#
#   irm https://raw.githubusercontent.com/bonkedbythonk/anicat/master/scripts/install_windows.ps1 | iex
#
# Written for that pipe, which shapes the whole file: iex runs it as one
# string, so there is no $PSScriptRoot and no param() block, and it runs
# inside the user's own PowerShell session. Everything is wrapped in a script
# block, and failures `return` out of it rather than `exit`: an `exit` under
# iex closes the window the user typed into, taking the error message with it.
# Must stay compatible with Windows PowerShell 5.1, the only PowerShell a
# fresh Windows 10 has.
#
# Never touches %APPDATA%\Anicat, where the library, watch history, sign-in
# and log live.

& {
    $ErrorActionPreference = 'Stop'
    # 5.1 redraws Invoke-WebRequest's progress bar per chunk, which turns a
    # 40 MB download into minutes. Restored at the end because iex runs in the
    # caller's session and this is the caller's preference.
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    $Repo = 'bonkedbythonk/anicat'
    $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Anicat'
    $StartMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $Shortcut = Join-Path $StartMenu 'Anicat.lnk'

    function Say($message) { Write-Host $message }
    function Complain($message) { Write-Host $message -ForegroundColor Red }

    try {
        # Windows PowerShell 5.1 still offers TLS 1.0 first, and GitHub has
        # refused anything below 1.2 since 2018: every request fails with "The
        # underlying connection was closed" and nothing more.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        if (-not $env:LOCALAPPDATA -or -not $env:APPDATA) {
            Complain 'LOCALAPPDATA or APPDATA is not set in this session, so there is nowhere safe to install to.'
            return
        }
        if (-not [Environment]::Is64BitOperatingSystem) {
            Complain 'Anicat for Windows is built for 64-bit Windows 10 or 11 only.'
            return
        }

        Say 'Step 1: Finding the latest version...'
        $downloadUrl = $null
        $tag = $null
        try {
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing
            $tag = $release.tag_name
            $asset = $release.assets | Where-Object { $_.name -like '*-windows-x64.zip' } | Select-Object -First 1
            if ($asset) { $downloadUrl = $asset.browser_download_url }
        } catch {
            # The API allows 60 anonymous requests an hour per public IP,
            # shared by everyone behind the same NAT, and answers the 61st
            # with a 403. The web redirect for /releases/latest has no such
            # limit and names the tag, and the packaging script names the zip
            # from the version, so the URL can be rebuilt from the tag alone.
            try {
                $request = [Net.WebRequest]::Create("https://github.com/$Repo/releases/latest")
                $request.AllowAutoRedirect = $false
                $response = $request.GetResponse()
                $location = $response.Headers['Location']
                $response.Close()
                if ($location -match '/releases/tag/(v[0-9][^/?#]*)') {
                    $tag = $Matches[1]
                    $downloadUrl = "https://github.com/$Repo/releases/download/$tag/Anicat-$($tag.Substring(1))-windows-x64.zip"
                }
            } catch { }
        }

        if (-not $downloadUrl) {
            if ($tag) {
                # The Mac half of a release is published first and the Windows
                # zip is attached by CI some minutes later.
                Complain "The latest release ($tag) has no Windows download yet."
                Say 'It is usually attached within half an hour of the release. Try again later, or check:'
            } else {
                Complain "Couldn't find the latest release."
                Say 'Check your internet connection and try again, or download manually from:'
            }
            Say "  https://github.com/$Repo/releases"
            return
        }

        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("anicat-install-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $zip = Join-Path $tmp 'anicat.zip'
            Say "Step 2: Downloading Anicat $tag... (this might take a minute)"
            try {
                Invoke-WebRequest -Uri $downloadUrl -OutFile $zip -UseBasicParsing
            } catch {
                Complain "The download failed: $($_.Exception.Message)"
                Say "If the release was just published, its Windows zip may still be uploading. Try again in a few minutes."
                return
            }

            Say 'Step 3: Installing...'
            # A running anicat.exe holds its own file open and the delete
            # below fails half way, leaving an install that is part old, part
            # missing. Stopped without asking it anything: a hung instance is
            # exactly the one that would not answer.
            Get-Process -Name anicat -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            # Only an mpv started from this install. Reading .Path throws for
            # a process this account cannot open (another user's mpv, an
            # elevated one), and under $ErrorActionPreference = 'Stop' an
            # unguarded read would end the install over a player that is not
            # even ours.
            Get-Process -Name mpv -ErrorAction SilentlyContinue | Where-Object {
                $path = $null
                try { $path = $_.Path } catch { }
                $path -and $path.StartsWith($InstallDir + '\', [StringComparison]::OrdinalIgnoreCase)
            } | Stop-Process -Force -ErrorAction SilentlyContinue
            # Stop-Process returns before the handles close.
            Start-Sleep -Seconds 2

            $extracted = Join-Path $tmp 'extracted'
            Expand-Archive -Path $zip -DestinationPath $extracted -Force
            $exe = Get-ChildItem -Path $extracted -Filter 'anicat.exe' -Recurse | Select-Object -First 1
            if (-not $exe) {
                Complain 'The downloaded archive did not contain anicat.exe.'
                return
            }
            $payload = $exe.DirectoryName

            # Replaced, not merged: files a previous version shipped and this
            # one dropped would otherwise stay beside the new exe, and a stale
            # DLL next to mpv.exe is loaded before the system's copy.
            if (Test-Path $InstallDir) {
                try {
                    Remove-Item -Recurse -Force $InstallDir
                } catch {
                    Complain "Could not remove the old install at $InstallDir."
                    Say 'Something still has a file open there. Quit Anicat from its tray icon, close any mpv window, and run this again.'
                    return
                }
            }
            New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
            Copy-Item -Path (Join-Path $payload '*') -Destination $InstallDir -Recurse -Force

            # A downloaded zip carries the Mark of the Web and so does every
            # file expanded from it. Left on, mpv.exe starts with a security
            # prompt the first time Anicat launches it, behind the browser.
            Get-ChildItem -Path $InstallDir -Recurse -File | Unblock-File

            $shell = New-Object -ComObject WScript.Shell
            $link = $shell.CreateShortcut($Shortcut)
            $link.TargetPath = Join-Path $InstallDir 'anicat.exe'
            $link.WorkingDirectory = $InstallDir
            $link.Description = 'Anicat'
            $link.Save()
        } finally {
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        }

        Say 'Step 4: Opening Anicat...'
        Start-Process -FilePath (Join-Path $InstallDir 'anicat.exe') -WorkingDirectory $InstallDir

        Write-Host ''
        Write-Host '    /\_/\'
        Write-Host '   ( ^.^ )   Anicat is ready!'
        Write-Host '    > ^ <'
        Write-Host ''
        Say 'Anicat opens in your browser and puts an icon in the system tray.'
        Say 'Next time, start it from the Start menu.'
        Say ''
        Say 'If Windows SmartScreen warns, choose More info, then Run anyway.'
        Say ''
        Say 'Connect your AniList account from Settings to sync your library.'
        Say "Installed to $InstallDir. Run this command again to update."
    } catch {
        Complain "Install failed: $($_.Exception.Message)"
        Say "Download manually from https://github.com/$Repo/releases"
    } finally {
        $ProgressPreference = $previousProgress
    }
}
