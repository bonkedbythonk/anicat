"""Parser-contract tests for the AniNeko provider."""

import logging

from anineko import AniNekoProvider

SEARCH_HTML = """
<div class="grid">
  <article class="nv-anime-card">
    <a class="nv-anime-thumb" href="/watch/frieren-123">
      <img src="/img/frieren.jpg" alt="Frieren" />
    </a>
  </article>
  <article class="nv-anime-card">
    <a class="nv-anime-thumb" href="/watch/dandadan-456">
      <img src="/img/dandadan.jpg" alt="" />
    </a>
    <div class="nv-anime-title"><a href="/watch/dandadan-456">Dandadan</a></div>
  </article>
  <article class="nv-anime-card">
    <a class="nv-anime-thumb" href="/genre/action"><img alt="not an anime" /></a>
  </article>
</div>
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


def test_parse_search_extracts_cards():
    results = AniNekoProvider._parse_search(SEARCH_HTML)
    # Third card has no /watch/ thumb and is skipped.
    assert [r.id for r in results] == ["frieren-123", "dandadan-456"]
    # First takes its title from the img alt; second falls back to the title div.
    assert results[0].title == "Frieren"
    assert results[1].title == "Dandadan"


def test_parse_search_empty_logs_warning(caplog):
    with caplog.at_level(logging.WARNING):
        results = AniNekoProvider._parse_search("<html><body>nothing</body></html>")
    assert results == []
    assert any("article.nv-anime-card" in r.message for r in caplog.records)


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
