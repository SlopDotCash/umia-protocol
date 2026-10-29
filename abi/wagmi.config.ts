import { defineConfig } from "@wagmi/cli";
import { foundry } from "@wagmi/cli/plugins";
import { FOUNDRY_ARTIFACT_PATHS } from "./src/contracts";

export default defineConfig({
  out: "src/generated.ts",
  plugins: [
    foundry({
      project: "../",
      // CI builds in an earlier step; building again here recompiles the whole via-IR project.
      forge: { clean: !process.env.CI, build: !process.env.CI },
      include: [...FOUNDRY_ARTIFACT_PATHS],
      // `include` is explicit, so the exclude list only guards against
      // accidental cross-matches. Don't blanket-exclude `interfaces/**`
      // or `I*.sol/**` — spec-only interfaces (e.g. ILiquidator) are
      // intentionally part of the public surface for error decoding.
      exclude: ["src/**", "mocks/**", "tokens/**", "*.s.sol/**"],
    }),
  ],
});
