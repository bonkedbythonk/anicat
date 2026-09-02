import { useState, useEffect } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { X, Download, Loader2, CheckCircle2, Folder, BookOpen, Monitor, Sliders, Sparkles } from "lucide-react";
import { novelApi } from "@/lib/api";
import type { MediaItem, EreaderPreset, NovelVolume, NovelBuildResult } from "@/lib/types";

interface EreaderDownloadModalProps {
  isOpen: boolean;
  onClose: () => void;
  media: MediaItem;
  volumes?: NovelVolume[];
  selectedVolumeId?: number | string | null;
}

const DEFAULT_PRESETS: EreaderPreset[] = [
  {
    id: "xteink_x3",
    name: "Xteink X3 (3.97\" E-Ink)",
    width: 528,
    height: 792,
    grayscale: true,
    quality: 85,
    split_spreads: true,
    description: "Native 528x792 8-bit grayscale for Xteink X3",
  },
  {
    id: "xteink_x4",
    name: "Xteink X4 (4.3\" E-Ink)",
    width: 480,
    height: 800,
    grayscale: true,
    quality: 85,
    split_spreads: true,
    description: "Native 480x800 layout for Xteink X4",
  },
  {
    id: "kindle_pw",
    name: "Kindle Paperwhite (6.8\" / 300 PPI)",
    width: 1072,
    height: 1448,
    grayscale: true,
    quality: 85,
    split_spreads: true,
    description: "High-resolution 300 PPI layout for Kindle Paperwhite",
  },
  {
    id: "kindle_basic",
    name: "Kindle Basic (6.0\")",
    width: 600,
    height: 800,
    grayscale: true,
    quality: 85,
    split_spreads: true,
    description: "600x800 portrait layout for Kindle Basic",
  },
  {
    id: "kobo_clara",
    name: "Kobo Clara 2E / BW (6.0\")",
    width: 1072,
    height: 1448,
    grayscale: true,
    quality: 85,
    split_spreads: true,
    description: "Crisp 300 PPI layout for Kobo Clara",
  },
  {
    id: "kobo_libra",
    name: "Kobo Libra (7.0\")",
    width: 1264,
    height: 1680,
    grayscale: false,
    quality: 90,
    split_spreads: true,
    description: "High-res portrait layout with color illustration support",
  },
  {
    id: "custom",
    name: "Custom Resolution",
    width: 528,
    height: 792,
    grayscale: true,
    quality: 85,
    split_spreads: true,
    description: "User-defined screen resolution",
  },
];

export function EreaderDownloadModal({
  isOpen,
  onClose,
  media,
  volumes = [],
  selectedVolumeId = null,
}: EreaderDownloadModalProps) {
  const [presets, setPresets] = useState<EreaderPreset[]>(DEFAULT_PRESETS);
  const [selectedPresetId, setSelectedPresetId] = useState<string>("xteink_x3");
  const [customWidth, setCustomWidth] = useState<number>(528);
  const [customHeight, setCustomHeight] = useState<number>(792);
  const [grayscale, setGrayscale] = useState<boolean>(true);
  const [splitSpreads, setSplitSpreads] = useState<boolean>(true);
  const [quality, setQuality] = useState<number>(85);
  const [selectedVol, setSelectedVol] = useState<string>(
    selectedVolumeId ? String(selectedVolumeId) : "all"
  );
  const [isDownloading, setIsDownloading] = useState<boolean>(false);
  const [result, setResult] = useState<NovelBuildResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (isOpen) {
      setResult(null);
      setError(null);
      novelApi.getEreaderPresets().then((p) => {
        if (p && p.length > 0) setPresets(p);
      }).catch(() => {});
    }
  }, [isOpen]);

  const activePreset = presets.find((p) => p.id === selectedPresetId) || presets[0];

  const handlePresetChange = (presetId: string) => {
    setSelectedPresetId(presetId);
    const p = presets.find((pr) => pr.id === presetId);
    if (p && presetId !== "custom") {
      setCustomWidth(p.width);
      setCustomHeight(p.height);
      setGrayscale(p.grayscale);
      setQuality(p.quality);
      setSplitSpreads(p.split_spreads);
    }
  };

  const handleDownload = async () => {
    setIsDownloading(true);
    setError(null);
    setResult(null);

    try {
      const volNum = selectedVol !== "all" ? Number(selectedVol) : null;
      const volObj = volumes.find((v) => String(v.id) === selectedVol);

      const res = await novelApi.downloadNovelEpub({
        slug: String(media.id_mal || media.id),
        volume_id: isNaN(volNum as number) ? null : volNum,
        volume_title: volObj ? volObj.title : undefined,
        target_width: selectedPresetId === "custom" ? customWidth : activePreset.width,
        target_height: selectedPresetId === "custom" ? customHeight : activePreset.height,
        grayscale,
        jpeg_quality: quality,
        split_spreads: splitSpreads,
      });

      setResult(res);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setIsDownloading(false);
    }
  };

  const handleOpenFolder = () => {
    if (result?.file_path) {
      novelApi.openNovelFile(result.file_path);
    }
  };

  if (!isOpen) return null;

  return (
    <AnimatePresence>
      <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/70 backdrop-blur-sm">
        <motion.div
          initial={{ opacity: 0, scale: 0.95, y: 10 }}
          animate={{ opacity: 1, scale: 1, y: 0 }}
          exit={{ opacity: 0, scale: 0.95, y: 10 }}
          className="relative w-full max-w-xl rounded-xl border border-border bg-card p-6 text-foreground shadow-2xl overflow-hidden"
        >
          {/* Header */}
          <div className="flex items-start justify-between pb-4 border-b border-border/60">
            <div>
              <div className="flex items-center gap-2">
                <span className="inline-flex items-center gap-1 rounded bg-accent/15 px-2 py-0.5 text-[11px] font-bold text-accent">
                  <Sparkles size={12} /> CrossPoint E-Ink Pipeline
                </span>
              </div>
              <h2 className="mt-1 text-lg font-bold tracking-tight">
                Download EPUB for E-Reader
              </h2>
              <p className="meta-mono text-xs text-muted-foreground line-clamp-1">
                {media.title.english || media.title.romaji || "Light Novel"}
              </p>
            </div>
            <button
              onClick={onClose}
              className="rounded-md p-1.5 text-muted-foreground hover:bg-muted hover:text-foreground transition-colors cursor-pointer"
            >
              <X size={18} />
            </button>
          </div>

          {result ? (
            <div className="py-8 text-center space-y-4">
              <div className="inline-flex items-center justify-center w-14 h-14 rounded-full bg-accent/15 text-accent mb-2">
                <CheckCircle2 size={32} />
              </div>
              <div>
                <h3 className="text-base font-bold text-foreground">EPUB Generated Successfully</h3>
                <p className="meta-mono text-xs text-muted-foreground mt-1 max-w-md mx-auto break-all">
                  {result.filename}
                </p>
                <p className="meta-mono text-xs text-accent mt-1">
                  {(result.file_size / (1024 * 1024)).toFixed(2)} MB · Optimized for {activePreset.name}
                </p>
              </div>

              <div className="flex items-center justify-center gap-3 pt-4">
                <button
                  onClick={handleOpenFolder}
                  className="flex items-center gap-2 rounded-md bg-accent px-4 py-2 text-xs font-semibold text-accent-foreground hover:opacity-90 transition-opacity cursor-pointer"
                >
                  <Folder size={15} />
                  <span>Show in Finder</span>
                </button>
                <button
                  onClick={onClose}
                  className="rounded-md border border-border px-4 py-2 text-xs font-medium text-foreground hover:bg-muted transition-colors cursor-pointer"
                >
                  Close
                </button>
              </div>
            </div>
          ) : (
            <div className="mt-4 space-y-5">
              {error && (
                <div className="rounded-md bg-destructive/15 border border-destructive/30 p-3 text-xs text-destructive">
                  {error}
                </div>
              )}

              {/* Volume Selection */}
              {volumes.length > 0 && (
                <div>
                  <label className="block text-xs font-medium text-muted-foreground mb-1.5">
                    Target Volume / Compilation
                  </label>
                  <select
                    value={selectedVol}
                    onChange={(e) => setSelectedVol(e.target.value)}
                    className="w-full rounded-md border border-border bg-background px-3 py-2 text-xs text-foreground focus:outline-none focus:border-accent"
                  >
                    <option value="all">Full Series Guide & Overview</option>
                    {volumes.map((v, i) => (
                      <option key={String(v.id || i)} value={String(v.id)}>
                        {v.title || `Volume ${i + 1}`}
                      </option>
                    ))}
                  </select>
                </div>
              )}

              {/* Device Preset Selection */}
              <div>
                <label className="block text-xs font-medium text-muted-foreground mb-1.5">
                  E-Reader Device Profile
                </label>
                <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
                  {presets.map((preset) => {
                    const isSelected = selectedPresetId === preset.id;
                    return (
                      <button
                        key={preset.id}
                        type="button"
                        onClick={() => handlePresetChange(preset.id)}
                        className={`p-2.5 rounded-lg border text-left transition-all cursor-pointer ${
                          isSelected
                            ? "border-accent bg-accent/10 shadow-[0_0_0_1px_var(--accent-color)]"
                            : "border-border bg-background/50 hover:border-foreground/30 hover:bg-background"
                        }`}
                      >
                        <div className="flex items-center justify-between">
                          <span className="text-xs font-semibold text-foreground line-clamp-1">
                            {preset.id === "xteink_x3" ? "★ Xteink X3" : preset.name.split(" (")[0]}
                          </span>
                        </div>
                        <p className="meta-mono text-[10px] text-muted-foreground mt-0.5">
                          {preset.width} × {preset.height}
                        </p>
                      </button>
                    );
                  })}
                </div>
              </div>

              {/* Custom Resolution Inputs */}
              {selectedPresetId === "custom" && (
                <div className="grid grid-cols-2 gap-3 p-3 rounded-lg border border-border/80 bg-background/50">
                  <div>
                    <label className="block text-[11px] font-mono text-muted-foreground mb-1">
                      Screen Width (px)
                    </label>
                    <input
                      type="number"
                      value={customWidth}
                      onChange={(e) => setCustomWidth(Number(e.target.value))}
                      className="w-full rounded border border-border bg-background px-2.5 py-1.5 text-xs text-foreground"
                    />
                  </div>
                  <div>
                    <label className="block text-[11px] font-mono text-muted-foreground mb-1">
                      Screen Height (px)
                    </label>
                    <input
                      type="number"
                      value={customHeight}
                      onChange={(e) => setCustomHeight(Number(e.target.value))}
                      className="w-full rounded border border-border bg-background px-2.5 py-1.5 text-xs text-foreground"
                    />
                  </div>
                </div>
              )}

              {/* Optimization Settings */}
              <div className="space-y-2.5 pt-2 border-t border-border/60">
                <label className="flex items-center justify-between text-xs text-foreground cursor-pointer">
                  <div>
                    <span className="font-medium">8-bit True Grayscale (Mode 'L')</span>
                    <p className="text-[11px] text-muted-foreground">
                      Removes color dither artifacts and optimizes for e-ink microcontrollers
                    </p>
                  </div>
                  <input
                    type="checkbox"
                    checked={grayscale}
                    onChange={(e) => setGrayscale(e.target.checked)}
                    className="rounded border-border accent-accent h-4 w-4"
                  />
                </label>

                <label className="flex items-center justify-between text-xs text-foreground cursor-pointer">
                  <div>
                    <span className="font-medium">Auto-Split Double-Page Landscape Art</span>
                    <p className="text-[11px] text-muted-foreground">
                      Cuts landscape 16:9/3:2 spreads into Left & Right portrait pages at full screen height
                    </p>
                  </div>
                  <input
                    type="checkbox"
                    checked={splitSpreads}
                    onChange={(e) => setSplitSpreads(e.target.checked)}
                    className="rounded border-border accent-accent h-4 w-4"
                  />
                </label>

                <div className="flex items-center justify-between pt-1">
                  <div>
                    <span className="text-xs font-medium text-foreground">JPEG Compression Quality</span>
                    <p className="text-[11px] text-muted-foreground">Balance between crisp illustrations and small EPUB file size</p>
                  </div>
                  <div className="flex items-center gap-2">
                    <input
                      type="range"
                      min={60}
                      max={95}
                      step={5}
                      value={quality}
                      onChange={(e) => setQuality(Number(e.target.value))}
                      className="accent-accent w-24"
                    />
                    <span className="meta-mono text-xs font-semibold w-8 text-right">{quality}%</span>
                  </div>
                </div>
              </div>

              {/* Action Buttons */}
              <div className="flex items-center justify-end gap-3 pt-3 border-t border-border/60">
                <button
                  type="button"
                  onClick={onClose}
                  disabled={isDownloading}
                  className="rounded-md border border-border px-4 py-2 text-xs font-medium text-foreground/80 hover:bg-muted transition-colors cursor-pointer"
                >
                  Cancel
                </button>
                <button
                  type="button"
                  onClick={handleDownload}
                  disabled={isDownloading}
                  className="flex items-center gap-2 rounded-md bg-accent px-5 py-2 text-xs font-semibold text-accent-foreground hover:opacity-90 disabled:opacity-50 transition-opacity cursor-pointer"
                >
                  {isDownloading ? (
                    <>
                      <Loader2 size={14} className="animate-spin" />
                      <span>Optimizing & Compiling...</span>
                    </>
                  ) : (
                    <>
                      <Download size={14} />
                      <span>Download {activePreset.name.split(" (")[0]} EPUB</span>
                    </>
                  )}
                </button>
              </div>
            </div>
          )}
        </motion.div>
      </div>
    </AnimatePresence>
  );
}
