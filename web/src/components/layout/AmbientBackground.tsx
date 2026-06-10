import { useEffect, useState } from "react";

type SkinConfig = {
  base: string;
  blobs: Array<{
    gradient: string;
    size: string;
    opacity: string;
    blur: string;
    position: Record<string, string>;
    duration: string;
    direction: string;
  }>;
};

const SKIN_CONFIGS: Record<string, SkinConfig> = {
  "neon-abyss": {
    base: "var(--background)",
    blobs: [
      {
        gradient: "radial-gradient(circle, rgba(94,92,230,0.8) 0%, rgba(94,92,230,0) 70%)",
        size: "80vw",
        opacity: "0.15",
        blur: "100px",
        position: { top: "-10%", left: "-10%" },
        duration: "20s",
        direction: "alternate",
      },
      {
        gradient: "radial-gradient(circle, rgba(191,90,242,0.6) 0%, rgba(191,90,242,0) 70%)",
        size: "70vw",
        opacity: "0.10",
        blur: "120px",
        position: { top: "40%", right: "-20%" },
        duration: "25s",
        direction: "alternate-reverse",
      },
      {
        gradient: "radial-gradient(circle, rgba(10,132,255,0.5) 0%, rgba(10,132,255,0) 70%)",
        size: "90vw",
        opacity: "0.05",
        blur: "150px",
        position: { bottom: "-20%", left: "20%" },
        duration: "30s",
        direction: "alternate",
      },
    ],
  },
  "sakura-zen": {
    base: "var(--background)",
    blobs: [
      {
        gradient: "radial-gradient(circle, rgba(220,100,150,0.75) 0%, rgba(220,100,150,0) 70%)",
        size: "90vw",
        opacity: "0.13",
        blur: "120px",
        position: { top: "-15%", left: "-15%" },
        duration: "18s",
        direction: "alternate",
      },
      {
        gradient: "radial-gradient(circle, rgba(154,184,154,0.6) 0%, rgba(154,184,154,0) 70%)",
        size: "75vw",
        opacity: "0.09",
        blur: "140px",
        position: { bottom: "-10%", right: "-15%" },
        duration: "24s",
        direction: "alternate-reverse",
      },
      {
        gradient: "radial-gradient(circle, rgba(232,160,180,0.5) 0%, rgba(232,160,180,0) 70%)",
        size: "60vw",
        opacity: "0.07",
        blur: "100px",
        position: { top: "30%", left: "30%" },
        duration: "28s",
        direction: "alternate",
      },
    ],
  },
  "retro-manga": {
    base: "var(--background)",
    blobs: [
      {
        gradient: "radial-gradient(circle, rgba(232,39,44,0.3) 0%, rgba(232,39,44,0) 70%)",
        size: "70vw",
        opacity: "0.06",
        blur: "80px",
        position: { top: "-10%", right: "-10%" },
        duration: "20s",
        direction: "alternate",
      },
      {
        gradient: "radial-gradient(circle, rgba(244,239,230,0.2) 0%, rgba(244,239,230,0) 70%)",
        size: "80vw",
        opacity: "0.04",
        blur: "100px",
        position: { bottom: "-10%", left: "-10%" },
        duration: "25s",
        direction: "alternate-reverse",
      },
    ],
  },
};

export function AmbientBackground() {
  const [config, setConfig] = useState<SkinConfig>(SKIN_CONFIGS["neon-abyss"]);

  useEffect(() => {
    const updateConfig = () => {
      const style = document.documentElement.getAttribute("data-style") || "neon-abyss";
      setConfig(SKIN_CONFIGS[style] || SKIN_CONFIGS["neon-abyss"]);
    };

    updateConfig();

    const observer = new MutationObserver(updateConfig);
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-style"],
    });

    return () => observer.disconnect();
  }, []);

  return (
    <div
      className="fixed inset-0 pointer-events-none z-0 overflow-hidden"
      style={{ background: config.base }}
    >
      {config.blobs.map((blob, i) => (
        <div
          key={i}
          className="ambient-blob animate-blob absolute rounded-full"
          style={{
            background: blob.gradient,
            width: blob.size,
            height: blob.size,
            opacity: blob.opacity,
            filter: `blur(${blob.blur})`,
            ...blob.position,
            animationDuration: blob.duration,
            animationDirection: blob.direction as "alternate" | "alternate-reverse",
          }}
        />
      ))}
    </div>
  );
}
