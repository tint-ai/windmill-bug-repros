import { stamp } from "../shared/lib/format.ts";

export async function main(name = "world") {
  return stamp(name);
}
