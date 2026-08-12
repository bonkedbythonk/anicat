"""Parser-contract tests for the AniNeko provider."""

import logging

from anineko import AniNekoProvider

from pathlib import Path

FIXTURES = Path(__file__).parent / "fixtures"

# Captured from a live /ajax/search?q=frieren response (2026-08-12).
SEARCH_JSON = """
{"success":true,"results":[
 {"title":"Frieren: Beyond Journey's End","url":"\\/watch\\/frieren-beyond-journeys-end",
  "image":"https:\\/\\/cdn.anizara.store\\/cover\\/a.webp","meta":"TV \\u2022 28 Episodes"},
 {"title":"Frieren: Beyond Journey's End Season 2","url":"\\/watch\\/frieren-beyond-journeys-end-season-2",
  "image":"","meta":"TV \\u2022 12 Episodes"},
 {"title":"No URL","url":"","meta":"TV"},
 {"title":"","url":"\\/watch\\/no-title","meta":"TV"}
]}
"""

ANIME_HTML = """
<h1>Frieren: Beyond Journey's End</h1>
<div class="episodes">
  <article class="nv-info-episode-item">
    <a class="nv-info-episode-main" href="/watch/frieren-123/ep-1">
      <strong>1</strong><span>The Journey's End</span>
    </a>
  </article>
  <article class="nv-info-episode-item">
    <a class="nv-info-episode-main" href="/watch/frieren-123/ep-2">
      <strong>Episode 2</strong><span>It Didn't Have to Be Magic</span>
    </a>
  </article>
</div>
"""


def test_parse_ajax_search_extracts_results():
    results = AniNekoProvider._parse_ajax_search(SEARCH_JSON)
    # Entries missing a url or a title are dropped, not guessed at.
    assert [r.id for r in results] == [
        "frieren-beyond-journeys-end",
        "frieren-beyond-journeys-end-season-2",
    ]
    assert results[0].title == "Frieren: Beyond Journey's End"


def test_parse_ajax_search_handles_non_json(caplog):
    # A Cloudflare interstitial reaches this function as HTML; it must not raise.
    with caplog.at_level(logging.WARNING):
        results = AniNekoProvider._parse_ajax_search("<html>Just a moment...</html>")
    assert results == []
    assert any("/ajax/search" in r.message for r in caplog.records)


def test_parse_ajax_search_empty_results():
    assert AniNekoProvider._parse_ajax_search('{"success":true,"results":[]}') == []


def test_parse_servers_reads_the_live_panel_markup():
    """Against real captured markup, not a hand-written approximation."""
    html = (FIXTURES / "anineko_watch_servers.html").read_text()
    servers, debug = AniNekoProvider()._parse_servers(html)

    # Two lang-group panels, twelve data-video buttons.
    assert debug["panels"] == 2
    assert len(servers) == 12

    # Group comes from the panel, never from sniffing a label.
    assert {s.group for s in servers} == {"soft_sub", "dub"}
    by_group = {}
    for s in servers:
        by_group.setdefault(s.group, []).append(s.name)
    assert "HD-1" in by_group["soft_sub"]
    assert "HD-1" in by_group["dub"]
    # Names are the button's own text only, whitespace collapsed — the previous
    # parser shipped them padded to 40 characters, straight into the UI.
    assert all(s.name == s.name.strip() for s in servers)
    assert "StreamHG" in by_group["soft_sub"]

    # Every URL is a real embed. The old regex pass put
    # `https://anineko.to/img/logo.png` in this list as a "server".
    assert all(s.url.startswith("http") for s in servers)
    assert not any("logo.png" in s.url for s in servers)

    # Soft-sub HD-1 carries its VTT in the query string.
    hd1 = next(s for s in servers if s.name == "HD-1" and s.group == "soft_sub")
    assert hd1.subtitle_url and hd1.subtitle_url.endswith(".vtt")


def test_parse_servers_missing_panels_warns(caplog):
    with caplog.at_level(logging.WARNING):
        servers, _ = AniNekoProvider()._parse_servers("<html><body>nope</body></html>")
    assert servers == []
    assert any("lang-group" in r.message for r in caplog.records)


def test_direct_shape_url_avoids_a_fetch_for_vivibebe():
    p = AniNekoProvider()
    # Query string carries the subtitle sidecar and must not pollute the token.
    got = p._direct_shape_url("https://vivibebe.site/be6f15ff30f73d95?sub=https://cdn.anizara.store/x.vtt")
    assert got == "https://vivibebe.site/public/stream/be6f15ff30f73d95/master.m3u8"
    # Hosts without a known shape fall through to page extraction.
    assert p._direct_shape_url("https://otakuhg.site/e/1eh90ov0kaep") is None
    assert p._direct_shape_url("https://playmogo.com/e/eifwiofn845e") is None


def test_browser_reachability_tracks_the_proxy_allowlist():
    from anineko import _host_is_browser_reachable
    # The one anineko server the mobile PWA can actually play.
    assert _host_is_browser_reachable("https://vivibebe.site/public/stream/x/master.m3u8")
    # Rotating throwaway CDNs the proxy allowlist can never cover.
    assert not _host_is_browser_reachable(
        "https://OkqtSs1gBbNcA8e.rivercrestlearningstudio.store/x/hls3/01/master.txt"
    )
    # HD-2 sits on one fixed Workers subdomain and is reachable -- it is what
    # covers the episodes whose HD-1 segments have been revoked.
    assert _host_is_browser_reachable("https://morning-credit-3bcc.vibevibe.workers.dev/x/master.m3u8")
    # But only that namespace: workers.dev at large is a shared public platform.
    assert not _host_is_browser_reachable("https://someone-else.workers.dev/x/master.m3u8")
    # Suffix matching must not be fooled by a lookalike parent domain.
    assert not _host_is_browser_reachable("https://vivibebe.site.evil.com/x/master.m3u8")
    assert not _host_is_browser_reachable("https://vibevibe.workers.dev.evil.com/x/master.m3u8")


def test_parse_anime_extracts_episodes():
    info = AniNekoProvider._parse_anime(ANIME_HTML)
    assert info is not None
    assert info.title.startswith("Frieren")
    assert [e.number for e in info.episodes] == [1, 2]
    assert info.episodes[0].title == "The Journey's End"


def test_parse_anime_no_episodes_logs_warning(caplog):
    with caplog.at_level(logging.WARNING):
        info = AniNekoProvider._parse_anime("<h1>Some Show</h1>")
    assert info is not None
    assert info.episodes == []
    assert any("article.nv-info-episode-item" in r.message for r in caplog.records)


JWPLAYER_JS = """
var uas=[];var links={"hls4":"/stream/AbC-dEf/kjhh/1786495156/66838462/master.m3u8",
"hls3":"https://54pkd.rotating-host.cfd/QVi5/hls3/01/13367/ivvhiadw4tdz_,l,n,h,.urlset/master.txt",
"hls2":"https://54pkd.premilkyway.com/hls2/01/13367/ivvhiadw4tdz_.urlset/master.m3u8?t=abc"};
jwplayer("vplayer").setup({sources:[{file:links.hls4||links.hls3||links.hls2,type:"hls"}]});
"""


def test_extract_jwplayer_links_prefers_same_origin_hls4():
    assert AniNekoProvider._extract_jwplayer_links(JWPLAYER_JS) == (
        "/stream/AbC-dEf/kjhh/1786495156/66838462/master.m3u8"
    )


def test_extract_jwplayer_links_falls_back_when_hls4_absent():
    js = JWPLAYER_JS.replace('"hls4"', '"hls9"')
    assert AniNekoProvider._extract_jwplayer_links(js).endswith("master.txt")


def test_extract_jwplayer_links_ignores_non_links_assignments():
    assert AniNekoProvider._extract_jwplayer_links("var other={\"hls4\":\"/x\"};") is None
