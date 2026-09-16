Anicat for Windows
==================

Anicat plays anime, films and TV and keeps your AniList profile up to date
while you watch. It runs in the background and shows its page in your browser;
videos open in mpv, which comes with it.


Requirements
------------

Windows 10 or Windows 11, 64-bit.


Starting it
-----------

Open the Start menu and click Anicat. Your browser opens on Anicat's page and
an Anicat icon appears in the system tray (near the clock). Right-click that
icon to open the page again or to quit.

If you unpacked this zip by hand instead of using the installer, double-click
anicat.exe. Keep every file in this folder together: anicat.exe looks for
mpv.exe and the mpv folder beside it.

The first time, Windows SmartScreen may say it protected your PC. That is
because the program is not signed with a paid certificate. Choose More info,
then Run anyway.


Where things are kept
---------------------

Your library, watch history and AniList sign-in:
    %APPDATA%\Anicat

The log file, for when something goes wrong:
    %APPDATA%\Anicat\anicat.log

Paste either path into the address bar of File Explorer to open it. The
program itself is in %LOCALAPPDATA%\Programs\Anicat when installed with the
command below; updating or removing it there leaves your data alone.


Updating
--------

Open PowerShell (Start menu, type "powershell") and paste:

    irm https://raw.githubusercontent.com/bonkedbythonk/anicat/master/scripts/install_windows.ps1 | iex

It downloads the latest version and replaces this one. The page also shows a
banner when a new version is out.


Support
-------

The Windows build is best effort: it uses the same engine as the Mac app, with
a simpler page, and gets less testing. If something does not work, open
Settings on Anicat's page, copy the debug report, and paste it into a new
issue at:

    https://github.com/bonkedbythonk/anicat/issues


Legal
-----

Anicat hosts no content. Read DISCLAIMER.md in this folder before using it.
Licenses for Anicat and everything shipped with it are in
THIRD_PARTY_NOTICES.txt. Anicat is free software under the GNU General Public
License, version 3; its source code is at https://github.com/bonkedbythonk/anicat
