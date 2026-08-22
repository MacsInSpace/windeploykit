import { useCallback, useEffect, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";

import {
  ensureDownloadDir,
  formatConfiguredDownloadDirPreview,
  getConfiguredDownloadBaseDir,
  getSystemDownloadsDir,
} from "../lib/downloadPath";
import {
  SETTING_DOWNLOAD_DIR,
  SETTING_DOWNLOAD_SITE_SUBDIR,
  SETTING_IMAGE_LIBRARY_DIR,
} from "../lib/downloadSettings";
import {
  formatImageLibraryRootPreview,
  pushImageLibraryRoot,
} from "../lib/imageLibrary";
import {
  getSetting,
  getSettingSource,
  setSetting,
  subscribeSettings,
} from "../lib/settings";
import { useSiteIdForQueries } from "../state/appStore";

export function DownloadSettingsSection() {
  const [, setTick] = useState(0);
  useEffect(() => subscribeSettings(() => setTick((n) => n + 1)), []);

  const siteId = useSiteIdForQueries();
  const configuredDir = String(getSetting(SETTING_DOWNLOAD_DIR)).trim();
  const siteSubdir = Boolean(getSetting(SETTING_DOWNLOAD_SITE_SUBDIR));
  const dirSource = getSettingSource(SETTING_DOWNLOAD_DIR);
  const subdirSource = getSettingSource(SETTING_DOWNLOAD_SITE_SUBDIR);

  const imageRoot = String(getSetting(SETTING_IMAGE_LIBRARY_DIR)).trim();
  const imageRootSource = getSettingSource(SETTING_IMAGE_LIBRARY_DIR);

  const [preview, setPreview] = useState("");
  const [systemDownloads, setSystemDownloads] = useState("");
  const [imagePreview, setImagePreview] = useState("");

  useEffect(() => {
    void getSystemDownloadsDir().then(setSystemDownloads);
  }, []);

  useEffect(() => {
    void formatConfiguredDownloadDirPreview(siteId ?? undefined).then(setPreview);
  }, [configuredDir, siteSubdir, siteId]);

  // Image library follows the main Downloads folder unless explicitly overridden,
  // so re-resolve the preview and re-push to the sidecar when either changes.
  useEffect(() => {
    void formatImageLibraryRootPreview().then(setImagePreview);
    void pushImageLibraryRoot();
  }, [imageRoot, configuredDir]);

  const browseFolder = useCallback(async () => {
    const picked = await open({
      directory: true,
      multiple: false,
      title: "Choose default download folder",
      defaultPath: configuredDir || systemDownloads || undefined,
    });
    if (!picked || typeof picked !== "string") return;
    setSetting(SETTING_DOWNLOAD_DIR, picked);
  }, [configuredDir, systemDownloads]);

  const resetFolder = useCallback(() => {
    setSetting(SETTING_DOWNLOAD_DIR, SETTING_DOWNLOAD_DIR.defaultValue);
  }, []);

  const browseImageRoot = useCallback(async () => {
    const picked = await open({
      directory: true,
      multiple: false,
      title: "Choose ISO & driver root",
      defaultPath: imageRoot || configuredDir || systemDownloads || undefined,
    });
    if (!picked || typeof picked !== "string") return;
    setSetting(SETTING_IMAGE_LIBRARY_DIR, picked);
  }, [imageRoot, configuredDir, systemDownloads]);

  const resetImageRoot = useCallback(() => {
    setSetting(SETTING_IMAGE_LIBRARY_DIR, SETTING_IMAGE_LIBRARY_DIR.defaultValue);
  }, []);

  return (
    <section>
      <div
        className="mono mb-2 text-[9px] font-medium uppercase"
        style={{ color: "var(--text3)", letterSpacing: "0.15em" }}
      >
        Downloads
      </div>
      <div
        className="flex flex-col gap-3 rounded-sm px-3 py-3"
        style={{ background: "var(--surface2)", border: "1px solid var(--border)" }}
      >
        <div>
          <div className="flex items-center gap-2">
            <div className="flex-1 text-[12px]" style={{ color: "var(--text)" }}>
              Default folder
            </div>
            <SourceBadge source={dirSource} />
          </div>
          <div className="mt-1 text-[10.5px]" style={{ color: "var(--text3)" }}>
            Exports and automatic downloads use this location. Empty uses your system
            Downloads folder
            {systemDownloads ? (
              <>
                {" "}
                (<span className="mono">{systemDownloads}</span>)
              </>
            ) : null}
            .
          </div>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <div
              className="input-box mono min-w-0 flex-1 text-[11px]"
              style={{ color: configuredDir ? "var(--text)" : "var(--text3)" }}
              title={configuredDir || systemDownloads}
            >
              {configuredDir || "(system Downloads)"}
            </div>
            <button type="button" className="btn" onClick={() => void browseFolder()}>
              Browse...
            </button>
            <button
              type="button"
              className="btn"
              onClick={resetFolder}
              disabled={dirSource !== "override"}
              title="Use system Downloads folder"
            >
              Reset
            </button>
          </div>
        </div>

        <label className="flex cursor-pointer items-start gap-2 text-[11px]">
          <input
            type="checkbox"
            className="mt-0.5"
            checked={siteSubdir}
            onChange={(e) => {
              const checked = e.target.checked;
              setSetting(SETTING_DOWNLOAD_SITE_SUBDIR, checked);
              if (checked) {
                void getConfiguredDownloadBaseDir(siteId ?? undefined).then((dir) =>
                  ensureDownloadDir(dir),
                );
              }
            }}
          />
          <span style={{ color: "var(--text2)" }}>
            <span style={{ color: "var(--text)" }}>Site subfolder</span>
            {" - "}
            append the active site id (e.g.{" "}
            <span className="mono">5573</span>) so files land in a per-site folder
            when you change context. The subfolder is created automatically if missing.
            {subdirSource === "override" && (
              <span className="mono ml-1 text-[9px] uppercase" style={{ color: "var(--accent)" }}>
                override
              </span>
            )}
          </span>
        </label>

        <div className="text-[10.5px]" style={{ color: "var(--text3)" }}>
          Effective path: <span className="mono text-[11px]" style={{ color: "var(--text2)" }}>{preview}</span>
          {siteSubdir && !siteId && (
            <span style={{ color: "var(--amber)" }}>
              {" "}
              (no site context - subfolder skipped until you connect)
            </span>
          )}
        </div>

        <div style={{ borderTop: "1px solid var(--border)", paddingTop: 12 }}>
          <div className="flex items-center gap-2">
            <div className="flex-1 text-[12px]" style={{ color: "var(--text)" }}>
              ISO &amp; driver root
            </div>
            <SourceBadge source={imageRootSource} />
          </div>
          <div className="mt-1 text-[10.5px]" style={{ color: "var(--text3)" }}>
            Where ISOs, driver packs, and imageable WIMs are stored and served from
            (Netboot and the deploy client read the <span className="mono">iso/</span>,{" "}
            <span className="mono">Drivers/&lt;model&gt;/</span> and{" "}
            <span className="mono">WIMs/</span> structure beneath it). Empty follows
            your Downloads folder. Point it at an external drive or NAS for large
            images.
          </div>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <div
              className="input-box mono min-w-0 flex-1 text-[11px]"
              style={{ color: imageRoot ? "var(--text)" : "var(--text3)" }}
              title={imageRoot || imagePreview}
            >
              {imageRoot || "(follows Downloads folder)"}
            </div>
            <button type="button" className="btn" onClick={() => void browseImageRoot()}>
              Browse...
            </button>
            <button
              type="button"
              className="btn"
              onClick={resetImageRoot}
              disabled={imageRootSource !== "override"}
              title="Follow the Downloads folder"
            >
              Reset
            </button>
          </div>
          <div className="mt-2 text-[10.5px]" style={{ color: "var(--text3)" }}>
            Effective path:{" "}
            <span className="mono text-[11px]" style={{ color: "var(--text2)" }}>
              {imagePreview}
            </span>
          </div>
        </div>
      </div>
    </section>
  );
}

function SourceBadge({ source }: { source: "override" | "env" | "default" }) {
  const palette: Record<typeof source, { fg: string; bg: string }> = {
    override: { fg: "var(--accent)", bg: "rgba(56, 189, 248, 0.12)" },
    env: { fg: "var(--amber)", bg: "rgba(245, 158, 11, 0.12)" },
    default: { fg: "var(--text3)", bg: "var(--surface)" },
  };
  const { fg, bg } = palette[source];
  return (
    <span
      className="mono text-[9px] uppercase"
      style={{
        color: fg,
        background: bg,
        padding: "1px 6px",
        borderRadius: 2,
        letterSpacing: "0.08em",
      }}
    >
      {source}
    </span>
  );
}
