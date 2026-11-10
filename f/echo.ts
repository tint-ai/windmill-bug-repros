// Top-level delay: stands in for module load time (large imports). A warm
// runner pays it once at startup; a fresh `bun run` pays it on every job.
await new Promise((r) => setTimeout(r, 500));

export async function main(x: number) {
  return x + 1;
}
