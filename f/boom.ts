export async function main() {
  throw Object.assign(new Error("boom"), { metadata: { code: "SOME_CODE" } });
}
