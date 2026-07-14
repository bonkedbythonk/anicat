import { useQuery } from "@tanstack/react-query";
import {
  Calendar,
  Bell,
  ChevronRight,
  Play,
  FastForward,
  Gauge,
  Languages,
  Server,
} from "lucide-react";
import { getNotifications } from "@/lib/api";
import { useAppStore, useSettingsStore } from "@/stores/app";
import { saveMobileSetting } from "./mobileSettings";

interface YouViewProps {
  displayName: string;
  anilistUsername: string | null;
  onNavigate: (view: "schedule" | "notifications" | "profile") => void;
  onLogout: () => void;
}

const PROVIDERS = ["anineko", "mkissa"] as const;
const PROVIDER_LABELS: Record<string, string> = { anineko: "AniNeko", mkissa: "Mkissa" };

function Row({
  color,
  icon: Icon,
  label,
  onClick,
  children,
  first,
}: {
  color: string;
  icon: typeof Play;
  label: string;
  onClick?: () => void;
  children?: React.ReactNode;
  first?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      disabled={!onClick}
      className={`w-full flex items-center gap-3 px-4 py-3 text-left ${onClick ? "active:bg-white/[0.06]" : ""} transition-colors ${
        first ? "" : "border-t border-white/[0.05]"
      }`}
    >
      <div className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-[7px] ${color}`}>
        <Icon size={15} className="text-white" />
      </div>
      <span className="flex-1 text-[15px] font-medium text-foreground">{label}</span>
      {children}
    </button>
  );
}

function Toggle({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return (
    <span
      role="switch"
      aria-checked={on}
      onClick={(e) => {
        e.stopPropagation();
        onChange(!on);
      }}
      className={`relative inline-block h-[26px] w-[44px] shrink-0 rounded-full transition-colors duration-200 ${
        on ? "bg-[#30d158]" : "bg-white/[0.16]"
      }`}
    >
      <span
        className={`absolute top-[2px] h-[22px] w-[22px] rounded-full bg-white shadow transition-all duration-200 ${
          on ? "left-[20px]" : "left-[2px]"
        }`}
      />
    </span>
  );
}

/** The account tab: profile header, phone-relevant playback settings
 * (per-device via mobileSettings, never written to the server's global
 * config.toml), the secondary sections that used to live in the "More" hub,
 * server status, and log out. iOS grouped-inset-list idiom throughout. */
export function YouView({ displayName, anilistUsername, onNavigate, onLogout }: YouViewProps) {
  const autoplay = useSettingsStore((s) => s.autoplay);
  const autoskip = useSettingsStore((s) => s.autoskip);
  const dataSaver = useSettingsStore((s) => s.dataSaver);
  const provider = useSettingsStore((s) => s.defaultProvider);
  const titleLanguage = useSettingsStore((s) => s.preferredTitleLanguage);
  const apiConnected = useAppStore((s) => s.apiConnected);

  const { data: unreadCount } = useQuery({
    queryKey: ["more-unread-notifications"],
    queryFn: async () => {
      const lastCleared = Number(localStorage.getItem("anicat_last_notifications_cleared") || 0);
      const res = await getNotifications();
      const notifications = res?.Page?.notifications ?? [];
      return notifications.filter((n) => (n.createdAt || 0) > lastCleared).length;
    },
    staleTime: 60_000,
  });

  const cycleProvider = () => {
    const idx = PROVIDERS.indexOf(provider as (typeof PROVIDERS)[number]);
    saveMobileSetting("defaultProvider", PROVIDERS[(idx + 1) % PROVIDERS.length]);
  };
  const cycleTitleLanguage = () => {
    saveMobileSetting("preferredTitleLanguage", titleLanguage === "english" ? "romaji" : "english");
  };

  const groupClass = "rounded-xl bg-white/[0.04] border border-white/[0.05] overflow-hidden";
  const groupLabel = "px-4 pt-5 pb-1.5 text-[12px] font-semibold uppercase tracking-wide text-muted-foreground";

  return (
    <div className="animate-fade-in pb-4">
      {/* Profile header */}
      <div className={groupClass}>
        <button
          onClick={() => onNavigate("profile")}
          className="w-full flex items-center gap-3.5 px-4 py-3.5 text-left active:bg-white/[0.06] transition-colors"
        >
          <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-accent to-accent-light text-[19px] font-bold text-white">
            {displayName.charAt(0).toUpperCase()}
          </div>
          <div className="min-w-0 flex-1">
            <p className="text-[16px] font-semibold text-foreground truncate">{displayName}</p>
            <p className="text-[12.5px] text-muted-foreground truncate">
              {anilistUsername ? `AniList: ${anilistUsername}` : "AniList not connected"}
            </p>
          </div>
          <ChevronRight size={18} className="text-muted-foreground shrink-0" />
        </button>
      </div>

      <p className={groupLabel}>Playback</p>
      <div className={groupClass}>
        <Row first color="bg-accent" icon={Play} label="Source" onClick={cycleProvider}>
          <span className="text-[14px] text-muted-foreground">{PROVIDER_LABELS[provider] || provider}</span>
          <ChevronRight size={16} className="text-muted-foreground shrink-0" />
        </Row>
        <Row color="bg-[#30d158]" icon={FastForward} label="Auto-play next episode">
          <Toggle on={autoplay} onChange={(v) => saveMobileSetting("autoplay", v)} />
        </Row>
        <Row color="bg-accent-light" icon={FastForward} label="Auto-skip intros & outros">
          <Toggle on={autoskip} onChange={(v) => saveMobileSetting("autoskip", v)} />
        </Row>
        <Row color="bg-[#ff9f0a]" icon={Gauge} label="Data saver">
          <Toggle on={dataSaver} onChange={(v) => saveMobileSetting("dataSaver", v)} />
        </Row>
      </div>

      <p className={groupLabel}>Display</p>
      <div className={groupClass}>
        <Row first color="bg-[#8e8e93]" icon={Languages} label="Title language" onClick={cycleTitleLanguage}>
          <span className="text-[14px] text-muted-foreground capitalize">{titleLanguage}</span>
          <ChevronRight size={16} className="text-muted-foreground shrink-0" />
        </Row>
      </div>

      <p className={groupLabel}>Sections</p>
      <div className={groupClass}>
        <Row first color="bg-[#ff375f]" icon={Calendar} label="Schedule" onClick={() => onNavigate("schedule")}>
          <ChevronRight size={16} className="text-muted-foreground shrink-0" />
        </Row>
        <Row color="bg-accent" icon={Bell} label="Notifications" onClick={() => onNavigate("notifications")}>
          {!!unreadCount && (
            <span className="flex h-5 min-w-[20px] items-center justify-center rounded-full bg-accent px-1.5 text-[11px] font-bold text-white">
              {unreadCount > 99 ? "99+" : unreadCount}
            </span>
          )}
          <ChevronRight size={16} className="text-muted-foreground shrink-0" />
        </Row>
      </div>

      <p className={groupLabel}>Server</p>
      <div className={groupClass}>
        <Row first color={apiConnected ? "bg-[#30d158]" : "bg-[#ff453a]"} icon={Server} label={window.location.hostname}>
          <span className={`text-[13px] font-medium ${apiConnected ? "text-[#30d158]" : "text-[#ff453a]"}`}>
            {apiConnected ? "Connected" : "Unreachable"}
          </span>
        </Row>
        <button
          onClick={onLogout}
          className="w-full border-t border-white/[0.05] px-4 py-3 text-center text-[15px] font-medium text-[#ff453a] active:bg-white/[0.06] transition-colors"
        >
          Log out
        </button>
      </div>
    </div>
  );
}
