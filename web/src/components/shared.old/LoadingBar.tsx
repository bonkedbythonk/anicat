"use client";

export default function LoadingBar({ active }: { active: boolean }) {
  if (!active) return null;

  return (
    <div className="absolute top-0 left-0 right-0 z-[60] h-0.5 overflow-hidden">
      <div className="absolute inset-0 bg-accent/20" />
      <div className="absolute inset-0 bg-accent animate-loading-bar" />
    </div>
  );
}
