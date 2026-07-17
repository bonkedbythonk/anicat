export function MediaTypeToggle({ value, onChange }: { value: "ANIME" | "MANGA"; onChange: (v: "ANIME" | "MANGA") => void }) {
  return (
    <div className="flex rounded-md overflow-hidden border border-border">
      {(["ANIME", "MANGA"] as const).map((t) => (
        <button
          key={t}
          onClick={() => onChange(t)}
          className={`px-3 py-1.5 text-[12px] font-medium cursor-pointer ${
            value === t ? "bg-accent/15 text-accent" : "text-foreground/50 hover:text-foreground"
          }`}
        >
          {t === "ANIME" ? "Anime" : "Manga"}
        </button>
      ))}
    </div>
  );
}
