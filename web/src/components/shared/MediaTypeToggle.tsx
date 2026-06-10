export function MediaTypeToggle({ value, onChange }: { value: "ANIME" | "MANGA"; onChange: (v: "ANIME" | "MANGA") => void }) {
  return (
    <div className="flex rounded-lg overflow-hidden border border-border">
      {(["ANIME","MANGA"] as const).map(t => (
        <button key={t} onClick={() => onChange(t)} className={`px-3 py-1 text-xs font-medium ${value===t?"bg-accent text-white":"text-muted-foreground"}`}>{t}</button>
      ))}
    </div>
  );
}
