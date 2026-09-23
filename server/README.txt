Anicat for Windows
==================

Watch anime, films and TV and keep your AniList up to date. Anicat runs in
the system tray and opens its page in your browser; videos play in mpv,
which comes with it. Windows 10 or 11, 64-bit.


Starting it
-----------

Click Anicat in the Start menu. Right-click the tray icon (near the clock)
to open the page again or quit. If you unpacked the zip by hand, run
anicat.exe and keep every file in this folder together.

If SmartScreen blocks it the first time, choose More info, then Run anyway.
The program is not signed with a paid certificate.


Updating
--------

Paste this into PowerShell:

    irm https://raw.githubusercontent.com/bonkedbythonk/anicat/master/scripts/install_windows.ps1 | iex

Your library and sign-in are kept in %APPDATA%\Anicat and survive updates.


Problems
--------

The Windows build is best effort. Copy the debug report from Settings on
Anicat's page and paste it into an issue:

    https://github.com/bonkedbythonk/anicat/issues

The log is at %APPDATA%\Anicat\anicat.log.


Legal
-----

Anicat hosts no content; read DISCLAIMER.md before using it. Licenses are in
THIRD_PARTY_NOTICES.txt. Free software under the GPLv3:
https://github.com/bonkedbythonk/anicat
