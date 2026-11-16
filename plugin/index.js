/**
 * Server entrypoint for the `custom-provider` OpenCode plugin.
 *
 * Keeping an active server plugin definition ensures OpenCode 2.3.0 discovers
 * the plugin cleanly and serves its `./gui-experimental` bundle to OpenCode Desktop.
 * Provider persistence lives natively in `~/.config/opencode/opencode.jsonc` so
 * CLI, TUI, and Desktop stay synchronized.
 */
export default {
  id: "custom-provider",
  setup() {},
};
