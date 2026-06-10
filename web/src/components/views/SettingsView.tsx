import { useSettingsStore } from "@/stores/app";
import { setConfig } from "@/lib/api";
import { useState } from "react";

export function SettingsView() {
  const {
    playerType,
    autoplay,
    autoskip,
    preferredQuality,
    preferredTitleLanguage,
    defaultProvider,
    setPlayerType,
    setAutoplay,
    setAutoskip,
    setPreferredQuality,
    setPreferredTitleLanguage,
    setDefaultProvider,
  } = useSettingsStore();

  const [saving, setSaving] = useState(false);

  const save = async (field: string, value: unknown) => {
    setSaving(true);
    try {
      await setConfig({ [field]: value });
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="flex-1 overflow-y-auto p-6">
      <h1 className="text-2xl font-bold text-[var(--text-primary)] mb-6">Settings</h1>
      <div className="max-w-lg space-y-4">
        <div className="bg-[var(--bg-tertiary)] rounded-xl p-4">
          <label className="text-sm text-[var(--text-primary)] block mb-2">Player</label>
          <select
            value={playerType}
            onChange={(e) => {
              setPlayerType(e.target.value as "embedded" | "external");
              save("stream.player_type", e.target.value);
            }}
            className="w-full bg-[var(--bg-primary)] text-[var(--text-primary)] rounded-lg px-3 py-2 text-sm border border-[var(--border)]"
          >
            <option value="embedded">Embedded</option>
            <option value="external">External (mpv)</option>
          </select>
        </div>

        <div className="bg-[var(--bg-tertiary)] rounded-xl p-4 space-y-3">
          {[
            { label: "Autoplay next episode", value: autoplay, set: setAutoplay, field: "general.autoplay" },
            { label: "Auto-skip OP/ED (AniSkip)", value: autoskip, set: setAutoskip, field: "general.autoskip" },
          ].map(({ label, value, set, field }) => (
            <label key={field} className="flex items-center justify-between cursor-pointer">
              <span className="text-sm text-[var(--text-primary)]">{label}</span>
              <button
                onClick={() => {
                  set(!value);
                  save(field, !value);
                }}
                className={`w-10 h-5 rounded-full transition-colors relative ${
                  value ? "bg-[var(--accent)]" : "bg-[var(--border)]"
                }`}
              >
                <span
                  className={`absolute top-0.5 w-4 h-4 rounded-full bg-white transition-transform ${
                    value ? "translate-x-5" : "translate-x-0.5"
                  }`}
                />
              </button>
            </label>
          ))}
        </div>

        <div className="bg-[var(--bg-tertiary)] rounded-xl p-4">
          <label className="text-sm text-[var(--text-primary)] block mb-2">Default quality</label>
          <select
            value={preferredQuality}
            onChange={(e) => {
              setPreferredQuality(e.target.value);
              save("stream.preferred_quality", e.target.value);
            }}
            className="w-full bg-[var(--bg-primary)] text-[var(--text-primary)] rounded-lg px-3 py-2 text-sm border border-[var(--border)]"
          >
            <option value="1080p">1080p</option>
            <option value="720p">720p</option>
            <option value="480p">480p</option>
          </select>
        </div>

        <div className="bg-[var(--bg-tertiary)] rounded-xl p-4">
          <label className="text-sm text-[var(--text-primary)] block mb-2">Title language</label>
          <select
            value={preferredTitleLanguage}
            onChange={(e) => {
              setPreferredTitleLanguage(e.target.value);
              save("general.preferred_title_language", e.target.value);
            }}
            className="w-full bg-[var(--bg-primary)] text-[var(--text-primary)] rounded-lg px-3 py-2 text-sm border border-[var(--border)]"
          >
            <option value="romaji">Romaji</option>
            <option value="english">English</option>
            <option value="native">Native</option>
          </select>
        </div>
      </div>
    </div>
  );
}
