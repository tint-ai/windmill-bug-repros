import dayjs from "dayjs";

export const VERSION = "v1";

export function stamp(name: string): string {
  return `[${VERSION}] hello ${name} at ${dayjs().format("YYYY-MM-DD")}`;
}
