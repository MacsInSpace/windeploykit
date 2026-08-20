import { defineSetting } from "./settings";

/** User override; empty string means the system Downloads folder. */
export const SETTING_DOWNLOAD_DIR = defineSetting({
  id: "download.dir",
  group: "Downloads",
  label: "Default folder",
  description:
    "Base folder for exports and downloads. Leave empty to use your system Downloads folder.",
  type: "string",
  defaultValue: "",
  hidden: true,
});

/**
 * Where ISOs, driver packs, and imageable WIMs live (the "ISO & driver root").
 * Large/optional imaging data is user-relocatable (external drive / NAS) and must
 * never silently fill the system drive — see docs/core/app-data/AGENT_NOTES_APP_DATA_LAYOUT.md
 * and docs/plugins/netboot/AGENT_NOTES_FIELDISO_SMB_PAYLOAD.md. Empty = follow the main Downloads
 * folder, under an "WinDeployKit" subfolder.
 */
export const SETTING_IMAGE_LIBRARY_DIR = defineSetting({
  id: "download.imageLibraryDir",
  group: "Downloads",
  label: "ISO & driver root",
  description:
    "Where ISOs, driver packs, and imageable WIMs are stored and served from (Netboot/ImageDeployer read the iso/, Drivers/<model>/ and WIMs/ structure beneath it). Leave empty for the default (Windows: Downloads; macOS: ~/Public — Downloads/Desktop/Documents are TCC-protected and can't be served over SMB). Point it at an external drive or NAS for large images.",
  type: "string",
  defaultValue: "",
  hidden: true,
});

/** When enabled, append the active school number (e.g. 5573) under the base folder. */
export const SETTING_DOWNLOAD_SCHOOL_SUBDIR = defineSetting({
  id: "download.schoolSubdir",
  group: "Downloads",
  label: "School subfolder",
  description:
    "Save into a school-number subfolder under the default folder (e.g. ~/Downloads/5573). Follows your current school context.",
  type: "boolean",
  defaultValue: false,
  hidden: true,
});
