// Importing a .node file makes esbuild (default loader { ".node": "file" })
// emit a second output file, so the CLI pushes a tarball instead of a plain
// bundle. Real-world trigger: ssh2's native crypto addon.
import addonPath from "./native/addon.node";

export async function main() {
  return { addonPath };
}
