// Test file: excluded from sync, imported by no script.
import { main } from "./a.ts";

if ((await main()) !== "hello a") throw new Error("unexpected");
