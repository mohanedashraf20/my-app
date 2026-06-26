const fs = require("fs");
const path = require("path");
const pdfjsLib = require("pdfjs-dist/legacy/build/pdf.mjs");

async function run() {
  try {
    const pdfPath = path.join(__dirname, "file.pdf");
    console.log("⚡ Reading and parsing PDF at:", pdfPath);
    if (!fs.existsSync(pdfPath)) {
      throw new Error(`PDF file not found at: ${pdfPath}`);
    }

    const data = new Uint8Array(fs.readFileSync(pdfPath));
    const pdf = await pdfjsLib.getDocument({ data }).promise;
    console.log(`✅ PDF loaded. Pages: ${pdf.numPages}`);

    const lines = [];
    for (let i = 1; i <= pdf.numPages; i++) {
      const page = await pdf.getPage(i);
      const content = await page.getTextContent();
      const strings = content.items.map((item) => item.str);
      const pageText = strings.join(" ").replace(/\s+/g, " ").trim();
      lines.push(pageText);
      console.log(`Extracted page ${i}/${pdf.numPages}`);
    }

    const outputText = lines.join("\n");

    const assetPath = path.join(__dirname, "..", "assets", "bylaws.txt");
    const extractedPath = path.join(__dirname, "bylaws_extracted.txt");

    // Make sure directory exists for assetPath
    const assetDir = path.dirname(assetPath);
    if (!fs.existsSync(assetDir)) {
      fs.mkdirSync(assetDir, { recursive: true });
    }

    fs.writeFileSync(assetPath, outputText, "utf8");
    console.log("✅ Wrote to:", assetPath);

    fs.writeFileSync(extractedPath, outputText, "utf8");
    console.log("✅ Wrote to:", extractedPath);

    console.log("🎉 Successfully completed!");
  } catch (error) {
    console.error("❌ Error during extraction:", error);
    process.exit(1);
  }
}

run();
