import { defineSetting } from "./settings";

/**
 * Marks the first-run setup wizard as completed.
 *
 * Stored rather than inferred, because "no override set" is a legitimate steady
 * state: a technician who accepts the default Deploy$ base leaves
 * SETTING_IMAGE_LIBRARY_DIR empty, and inferring from that would re-run the
 * wizard on every launch.
 */
export const SETTING_SETUP_COMPLETED = defineSetting({
  id: "setup.completed",
  group: "Setup",
  label: "First-run setup completed",
  description:
    "Set when the setup wizard finishes. Clear it to run the wizard again on next launch.",
  type: "boolean",
  defaultValue: false,
  hidden: true,
});
