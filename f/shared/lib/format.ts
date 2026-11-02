import dayjs from "dayjs";

export function stamp(name: string): string {
  return `hello ${name} at ${dayjs().format("YYYY-MM-DD")}`;
}
