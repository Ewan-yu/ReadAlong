import { describe, expect, it } from "vitest";

import { createBookSchema, valuesForPreset } from "./form";

describe("create book form", () => {
  it("applies the documented quality presets", () => {
    expect(valuesForPreset("clear")).toEqual({
      quality: "clear",
      readingLongEdge: 2000,
      webpQuality: 82,
    });
    expect(valuesForPreset("compact").webpQuality).toBe(72);
  });

  it("rejects output settings outside the pipeline limits", () => {
    const pdf = new File(["pdf"], "book.pdf", { type: "application/pdf" });
    const result = createBookSchema.safeParse({
      pdf,
      quality: "clear",
      readingLongEdge: 500,
      webpQuality: 110,
      splitDetectionEnabled: true,
    });

    expect(result.success).toBe(false);
  });
});
