"""Data models for RanobeDB entities, chapters, and novels."""

from dataclasses import dataclass, field
from typing import List, Optional, Dict, Any


@dataclass
class ImageInfo:
    id: Optional[int] = None
    filename: Optional[str] = None
    width: Optional[int] = None
    height: Optional[int] = None
    spoiler: bool = False
    nsfw: bool = False

    @property
    def url(self) -> Optional[str]:
        if self.filename:
            return f"https://images.ranobedb.org/{self.filename}"
        return None


@dataclass
class BookInfo:
    id: int
    title: str
    title_orig: Optional[str] = None
    romaji: Optional[str] = None
    romaji_orig: Optional[str] = None
    lang: Optional[str] = "ja"
    release_date: Optional[int] = None
    sort_order: Optional[int] = 0
    book_type: Optional[str] = "main"
    pages: Optional[int] = None
    description: Optional[str] = None
    image: Optional[ImageInfo] = None

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "BookInfo":
        img_data = data.get("image")
        image = ImageInfo(**img_data) if img_data and isinstance(img_data, dict) else None
        return cls(
            id=data.get("id", 0),
            title=data.get("title", ""),
            title_orig=data.get("title_orig"),
            romaji=data.get("romaji"),
            romaji_orig=data.get("romaji_orig"),
            lang=data.get("lang", "ja"),
            release_date=data.get("c_release_date") or data.get("release_date"),
            sort_order=data.get("sort_order", 0),
            book_type=data.get("book_type", "main"),
            pages=data.get("pages"),
            description=data.get("description"),
            image=image,
        )


@dataclass
class StaffMember:
    role_type: str  # author, artist, translator, etc.
    name: str
    romaji: Optional[str] = None
    staff_id: Optional[int] = None
    staff_alias_id: Optional[int] = None
    note: Optional[str] = None
    lang: Optional[str] = None

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "StaffMember":
        return cls(
            role_type=data.get("role_type", "staff"),
            name=data.get("name", ""),
            romaji=data.get("romaji"),
            staff_id=data.get("staff_id"),
            staff_alias_id=data.get("staff_alias_id"),
            note=data.get("note"),
            lang=data.get("lang"),
        )


@dataclass
class Publisher:
    id: int
    name: str
    romaji: Optional[str] = None
    publisher_type: Optional[str] = "publisher"
    lang: Optional[str] = "ja"

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "Publisher":
        return cls(
            id=data.get("id", 0),
            name=data.get("name", ""),
            romaji=data.get("romaji"),
            publisher_type=data.get("publisher_type"),
            lang=data.get("lang"),
        )


@dataclass
class Tag:
    id: int
    name: str
    ttype: Optional[str] = "tag"  # genre or tag

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "Tag":
        return cls(
            id=data.get("id", 0),
            name=data.get("name", ""),
            ttype=data.get("ttype", "tag"),
        )


@dataclass
class SeriesInfo:
    id: int
    title: str
    title_orig: Optional[str] = None
    romaji: Optional[str] = None
    romaji_orig: Optional[str] = None
    description: str = ""
    publication_status: Optional[str] = None
    web_novel: Optional[str] = None
    website: Optional[str] = None
    lang: str = "en"
    books: List[BookInfo] = field(default_factory=list)
    staff: List[StaffMember] = field(default_factory=list)
    publishers: List[Publisher] = field(default_factory=list)
    tags: List[Tag] = field(default_factory=list)
    rating_score: Optional[float] = None
    rating_count: Optional[int] = None
    child_series: List[Dict[str, Any]] = field(default_factory=list)
    raw_data: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "SeriesInfo":
        books_data = data.get("books", [])
        books = [BookInfo.from_dict(b) for b in books_data] if isinstance(books_data, list) else []
        books.sort(key=lambda b: (b.sort_order if b.sort_order is not None else 9999, b.id))

        staff_data = data.get("staff", [])
        staff = [StaffMember.from_dict(s) for s in staff_data] if isinstance(staff_data, list) else []

        publishers_data = data.get("publishers", [])
        publishers = [Publisher.from_dict(p) for p in publishers_data] if isinstance(publishers_data, list) else []

        tags_data = data.get("tags", [])
        tags = [Tag.from_dict(t) for t in tags_data] if isinstance(tags_data, list) else []

        rating = data.get("rating") or {}

        return cls(
            id=data.get("id", 0),
            title=data.get("title", ""),
            title_orig=data.get("title_orig"),
            romaji=data.get("romaji"),
            romaji_orig=data.get("romaji_orig"),
            description=data.get("description", ""),
            publication_status=data.get("publication_status"),
            web_novel=data.get("web_novel"),
            website=data.get("website"),
            lang=data.get("lang", "en"),
            books=books,
            staff=staff,
            publishers=publishers,
            tags=tags,
            rating_score=rating.get("score"),
            rating_count=rating.get("count"),
            child_series=data.get("child_series", []),
            raw_data=data,
        )

    @property
    def authors(self) -> List[str]:
        auths = []
        for s in self.staff:
            if s.role_type == "author":
                if s.romaji and s.name and s.romaji != s.name:
                    auths.append(f"{s.romaji} ({s.name})")
                else:
                    auths.append(s.romaji or s.name)
        return auths if auths else ["Unknown Author"]

    @property
    def artists(self) -> List[str]:
        arts = []
        for s in self.staff:
            if s.role_type == "artist":
                if s.romaji and s.name and s.romaji != s.name:
                    arts.append(f"{s.romaji} ({s.name})")
                else:
                    arts.append(s.romaji or s.name)
        return arts

    @property
    def translators(self) -> List[str]:
        trs = []
        for s in self.staff:
            if s.role_type == "translator":
                if s.romaji and s.name and s.romaji != s.name:
                    trs.append(f"{s.romaji} ({s.name})")
                else:
                    trs.append(s.romaji or s.name)
        return trs

    @property
    def genres(self) -> List[str]:
        return [t.name for t in self.tags if t.ttype == "genre"]

    @property
    def all_tags(self) -> List[str]:
        return [t.name for t in self.tags]

    @property
    def primary_cover_url(self) -> Optional[str]:
        for book in self.books:
            if book.image and book.image.url:
                return book.image.url
        # Search results carry a single representative book instead of the list.
        img = (self.raw_data.get("book") or {}).get("image")
        if isinstance(img, dict) and img.get("filename"):
            return ImageInfo(**img).url
        return None

    @property
    def display_title(self) -> str:
        return self.title or self.title_orig or self.romaji or f"Series #{self.id}"


@dataclass
class Chapter:
    index: int
    title: str
    url: str
    volume_name: Optional[str] = None
    content_html: Optional[str] = None
    content_text: Optional[str] = None


@dataclass
class Novel:
    title: str
    author: str
    description: str
    source_url: str
    chapters: List[Chapter] = field(default_factory=list)
    cover_image_bytes: Optional[bytes] = None
    cover_image_url: Optional[str] = None
    series_info: Optional[SeriesInfo] = None
    language: str = "en"
