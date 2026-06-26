const express = require("express");
const cors = require("cors");
const fs = require("fs");
const pdfjsLib = require("pdfjs-dist/legacy/build/pdf.mjs");

require("dotenv").config();

const { OpenAI } = require("openai");
const openai = process.env.OPENAI_API_KEY ? new OpenAI({ apiKey: process.env.OPENAI_API_KEY }) : null;

const { GoogleGenerativeAI } = require("@google/generative-ai");
const genAI = process.env.GEMINI_API_KEY ? new GoogleGenerativeAI(process.env.GEMINI_API_KEY) : null;

const Groq = require("groq-sdk");
const groq = process.env.GROQ_API_KEY ? new Groq({ apiKey: process.env.GROQ_API_KEY }) : null;

const app = express();
app.use(cors());
app.use(express.json());

let pdfChunks = [];
let rerankerModel = null;
let rerankerTokenizer = null;

// Initialize reranker model using the low-level Transformers.js API
async function initReranker() {
  try {
    console.log("⚡ Loading BAAI/bge-reranker-base model...");
    // Dynamic import to support ESM inside CommonJS
    const { AutoModelForSequenceClassification, AutoTokenizer } = await import("@xenova/transformers");
    rerankerTokenizer = await AutoTokenizer.from_pretrained("Xenova/bge-reranker-base");
    rerankerModel = await AutoModelForSequenceClassification.from_pretrained("Xenova/bge-reranker-base");
    console.log("✅ Reranker model loaded successfully.");
  } catch (e) {
    console.error("❌ Failed to load reranker model:", e.message);
    console.log("ℹ️ Will fall back to standard keyword retrieval without re-ranking.");
  }
}

async function downloadPDF(url, path) {
  try {
    console.log(`⚡ Downloading PDF from: ${url}...`);
    const res = await fetch(url);
    if (!res.ok) throw new Error(`HTTP error! status: ${res.status}`);
    const buffer = Buffer.from(await res.arrayBuffer());
    fs.writeFileSync(path, buffer);
    console.log("✅ PDF downloaded and saved to " + path);
  } catch (error) {
    console.error("❌ Failed to download PDF:", error.message);
    console.log("ℹ️ Falling back to existing local file if available.");
  }
}

function chunkText(pages, chunkSize = 350, overlap = 50) {
  const chunks = [];
  for (const page of pages) {
    const words = page.text.trim().split(/\s+/).filter(w => w.length > 0);
    if (words.length === 0) continue;

    let i = 0;
    while (i < words.length) {
      const chunkWords = words.slice(i, i + chunkSize);
      const text = chunkWords.join(" ");
      chunks.push({
        text,
        page: page.pageNum,
        part: page.part,
        article: page.article
      });

      i += (chunkSize - overlap);

      if (i >= words.length || chunkWords.length < chunkSize) {
        break;
      }
    }
  }
  return chunks;
}

async function loadPDF() {
  try {
    const pdfPath = "file.pdf";
    const url = process.env.PDF_URL;
    if (url && url.startsWith("http")) {
      await downloadPDF(url, pdfPath);
    }

    if (!fs.existsSync(pdfPath)) {
      throw new Error(`PDF file not found at: ${pdfPath}`);
    }

    console.log("⚡ Reading and parsing PDF...");
    const data = new Uint8Array(fs.readFileSync(pdfPath));
    const pdf = await pdfjsLib.getDocument({ data }).promise;

    const pages = [];
    let currentPart = "";
    let currentArticle = "";

    for (let i = 1; i <= pdf.numPages; i++) {
      const page = await pdf.getPage(i);
      const content = await page.getTextContent();
      const strings = content.items.map((item) => item.str);
      const pageText = strings.join(" ").replace(/\s+/g, " ");

      // Detect section metadata
      const partMatch = pageText.match(/Part\s+([A-Z])\b/i);
      const articleMatch = pageText.match(/Article\s+\(?(\d+)\)?/i);

      if (partMatch) currentPart = `Part ${partMatch[1].toUpperCase()}`;
      if (articleMatch) currentArticle = `Article ${articleMatch[1]}`;

      pages.push({ 
        pageNum: i, 
        text: pageText,
        part: currentPart,
        article: currentArticle
      });
    }

    pdfChunks = chunkText(pages, 350, 50);
    console.log(`✅ PDF loaded. Pages: ${pdf.numPages}, Total chunks: ${pdfChunks.length}`);
  } catch (e) {
    console.error("❌ PDF Load Error:", e);
  }
}

// Extract search metadata queries (e.g. Article 10, Page 5, Part C)
function extractQueryMetadata(query) {
  const meta = { page: null, article: null, part: null };
  
  // Normalize Arabic digits to English
  const normalizeDigits = (str) => {
    return str.replace(/[٠-٩]/g, d => '٠١٢٣٤٥٦٧٨٩'.indexOf(d));
  };
  
  const queryNormalized = normalizeDigits(query.toLowerCase());
  
  // Match page number: e.g. "page 12", "صفحة 12", "صفحه 12"
  const pageMatch = queryNormalized.match(/(?:page|صفحة|صفحه)\s*(\d+)/i);
  if (pageMatch) {
    meta.page = parseInt(pageMatch[1], 10);
  }
  
  // Match article number: e.g. "article 10", "مادة 10", "ماده 10", "المادة 10", "الماده 10"
  const articleMatch = queryNormalized.match(/(?:article|مادة|ماده|المادة|الماده)\s*\(?(\d+)\)?/i);
  if (articleMatch) {
    meta.article = `Article ${articleMatch[1]}`;
  }
  
  // Match part: e.g. "part a", "جزء أ", "قسم أ", "القسم أ"
  const partMatch = queryNormalized.match(/(?:part|جزء|قسم|القسم)\s*([a-d])\b/i);
  if (partMatch) {
    meta.part = `Part ${partMatch[1].toUpperCase()}`;
  }
  
  return meta;
}

const STOP_WORDS = new Set([
  'a', 'an', 'the', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
  'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'could', 'should',
  'may', 'might', 'shall', 'must', 'can', 'need', 'dare', 'ought', 'used',
  'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by', 'from', 'as', 'into',
  'through', 'during', 'before', 'after', 'above', 'below', 'up', 'down', 'out',
  'off', 'over', 'under', 'again', 'then', 'once', 'and', 'but', 'or', 'nor',
  'not', 'so', 'yet', 'both', 'either', 'neither', 'whether', 'if', 'that',
  'this', 'these', 'those', 'what', 'which', 'who', 'how', 'when', 'where',
  'why', 'all', 'each', 'every', 'more', 'most', 'other', 'some', 'such',
  'no', 'only', 'same', 'than', 'too', 'very', 'just', 'i', 'you', 'he',
  'she', 'it', 'we', 'they', 'me', 'him', 'her', 'us', 'them', 'my', 'your',
  'his', 'its', 'our', 'their', 'any', 'few', 'much', 'many', 'also', 'while'
]);

function retrieveCandidates(query, chunks, topK = 10) {
  const queryTokens = query
    .toLowerCase()
    .replace(/[^\w\s\u0600-\u06FF]/g, " ")
    .split(/\s+/)
    .filter(t => t.length > 1 && !STOP_WORDS.has(t));

  const metaCriteria = extractQueryMetadata(query);

  const scored = chunks.map(chunk => {
    const chunkLower = chunk.text.toLowerCase();
    let score = 0;
    
    // Keyword scoring
    for (const token of queryTokens) {
      const regex = new RegExp(`\\b${token}\\b`, 'g');
      const matches = chunkLower.match(regex);
      const tf = matches ? matches.length : 0;
      if (tf > 0) {
        score += tf * 3.0;
      } else if (chunkLower.includes(token)) {
        score += 1.0;
      }
    }

    // Metadata boosting (for simple/targeted queries)
    if (metaCriteria.page && chunk.page === metaCriteria.page) {
      score += 25.0;
    }
    if (metaCriteria.article && chunk.article && chunk.article.toLowerCase() === metaCriteria.article.toLowerCase()) {
      score += 25.0;
    }
    if (metaCriteria.part && chunk.part && chunk.part.toLowerCase() === metaCriteria.part.toLowerCase()) {
      score += 15.0;
    }

    return { chunk, score };
  });

  scored.sort((a, b) => b.score - a.score);
  return scored
    .filter(s => s.score > 0)
    .map(s => s.chunk)
    .slice(0, topK);
}

async function rerankCandidates(query, candidates, topK = 3) {
  if (!rerankerModel || !rerankerTokenizer) {
    console.warn("⚠️ Reranker model not loaded. Returning raw candidate retrieval results.");
    return candidates.slice(0, topK);
  }

  if (candidates.length === 0) return [];

  try {
    // Batch tokenize all query-candidate pairs
    const inputs = await rerankerTokenizer(new Array(candidates.length).fill(query), {
      text_pair: candidates.map(c => c.text),
      padding: true,
      truncation: true,
      max_length: 512
    });
    
    // Run inference
    const output = await rerankerModel(inputs);
    
    const scoredCandidates = candidates.map((c, idx) => {
      const score = output.logits.data[idx];
      return { chunk: c, score };
    });

    scoredCandidates.sort((a, b) => b.score - a.score);
    
    console.log("Reranked results:");
    scoredCandidates.slice(0, topK).forEach((sc, i) => {
      console.log(`  [${i+1}] Score: ${sc.score.toFixed(4)} | Page: ${sc.chunk.page} | ${sc.chunk.text.substring(0, 60)}...`);
    });

    return scoredCandidates.map(s => s.chunk).slice(0, topK);
  } catch (e) {
    console.error("❌ Reranking Error:", e.message);
    return candidates.slice(0, topK);
  }
}

// Initialize server data
async function initServer() {
  await loadPDF();
  await initReranker();
}

initServer();

async function expandQueryWithLLM(query) {
  const prompt = `You are a search assistant. Your task is to analyze the user's query and expand it to English search keywords and synonyms.
- If the query is in Arabic (or any other language), translate the core search terms into English.
- If the query is in English, generate key synonyms, related terms, and alternative spellings.
- Output ONLY a space-separated list of the 5 to 8 most important English search keywords.
- Do NOT output any preamble, extra punctuation, numbers, or explanation.

Query: "${query}"`;

  // 1. Try Groq (fast, free)
  if (groq) {
    try {
      console.log("⚡ Requesting query expansion from Groq...");
      const expansionModel = process.env.GROQ_MODEL || "llama-3.3-70b-versatile";
      const completion = await groq.chat.completions.create({
        model: expansionModel,
        messages: [{ role: "user", content: prompt }],
        max_tokens: 50,
        temperature: 0.1
      });
      const res = completion.choices[0].message?.content?.trim();
      if (res) {
        console.log(`🔍 LLM Expanded query keywords: "${res}"`);
        return res;
      }
    } catch (e) {
      console.warn("⚠️ Groq query expansion failed:", e.message);
    }
  }

  // 2. Try Gemini
  if (genAI) {
    try {
      console.log("⚡ Requesting query expansion from Gemini...");
      const model = genAI.getGenerativeModel({ model: "gemini-2.0-flash" });
      const resultObj = await model.generateContent(prompt);
      const res = resultObj.response.text()?.trim();
      if (res) {
        console.log(`🔍 Gemini Expanded query keywords: "${res}"`);
        return res;
      }
    } catch (e) {
      console.warn("⚠️ Gemini query expansion failed:", e.message);
    }
  }

  return "";
}

app.post("/ask", async (req, res) => {
  const question = req.body.message;
  if (!question) {
    return res.status(400).json({ reply: "Message is required" });
  }

  const ollamaHost = (process.env.OLLAMA_HOST || "http://localhost:11434").replace(/\/$/, "");
  const ollamaModel = process.env.OLLAMA_MODEL || "llama3.2";

  try {
    // ─── Step 1: LLM Query Expansion ───
    const expandedKeywords = await expandQueryWithLLM(question);
    
    // Combine original question and expanded keywords
    const searchQuery = `${question} ${expandedKeywords}`;
    console.log(`🔎 Combined search query: "${searchQuery}"`);

    const candidates = retrieveCandidates(searchQuery, pdfChunks, 10);
    const topChunks = await rerankCandidates(question, candidates, 3);
    
    if (topChunks.length === 0) {
      return res.json({
        reply: "Not found in document",
        sources: []
      });
    }

    const context = topChunks.map(c => c.text).join("\n\n");
    const sourcePages = [...new Set(topChunks.map(c => c.page))].sort((a, b) => a - b);

    let reply = "";
    const errors = [];

    const SYSTEM_PROMPT = `You are a helpful academic assistant that answers questions based on the provided document context.
- Use the provided context to answer the question as accurately and completely as possible.
- If the context contains relevant information, synthesize a clear answer even if it is not stated verbatim.
- Only respond with exactly 'Not found in document' if the context contains absolutely no relevant information.
- Answer in the same language as the user's question (Arabic question → Arabic answer, English question → English answer).
- Be concise and direct.`;

    // ── 1. Try Groq (FREE & Fast - Primary Provider) ───────────────────────
    if (groq) {
      try {
        const groqModel = process.env.GROQ_MODEL || "llama-3.3-70b-versatile";
        console.log(`⚡ Trying Groq (${groqModel})...`);
        const completion = await groq.chat.completions.create({
          model: groqModel,
          messages: [
            { role: "system", content: SYSTEM_PROMPT },
            { role: "user", content: `Context:\n${context}\n\nQuestion: ${question}` }
          ]
        });
        reply = completion.choices[0].message.content || "";
      } catch (e) {
        console.warn("⚠️ Groq failed:", e.message);
        errors.push("Groq: " + e.message);
      }
    }

    // ── 2. Try OpenAI (ChatGPT) ────────────────────────────────────────────
    if (!reply && openai) {
      try {
        const openaiModel = process.env.OPENAI_MODEL || "gpt-4o-mini";
        console.log(`⚡ Trying OpenAI (${openaiModel})...`);
        const completion = await openai.chat.completions.create({
          model: openaiModel,
          messages: [
            { role: "system", content: SYSTEM_PROMPT },
            { role: "user", content: `Context:\n${context}\n\nQuestion: ${question}` }
          ]
        });
        reply = completion.choices[0].message.content || "";
      } catch (e) {
        console.warn("⚠️ OpenAI failed:", e.message);
        errors.push("OpenAI: " + e.message);
      }
    }

    // ── 3. Try Google Gemini ───────────────────────────────────────────────
    if (!reply && genAI) {
      try {
        const modelName = process.env.GEMINI_MODEL || "gemini-2.5-flash";
        console.log(`⚡ Trying Google Gemini (${modelName})...`);
        const model = genAI.getGenerativeModel({ model: modelName });
        const geminiPrompt = `${SYSTEM_PROMPT}\n\nContext:\n${context}\n\nQuestion: ${question}`;
        const result = await model.generateContent(geminiPrompt);
        reply = result.response.text() || "";
      } catch (e) {
        console.warn("⚠️ Gemini failed:", e.message);
        errors.push("Gemini: " + e.message);
      }
    }

    // ── 4. Try Ollama (Local - Last Resort) ────────────────────────────────
    if (!reply) {
      try {
        console.log(`⚡ Trying Ollama (${ollamaModel})...`);
        const response = await fetch(`${ollamaHost}/api/chat`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            model: ollamaModel,
            messages: [
              { role: "system", content: SYSTEM_PROMPT },
              { role: "user", content: `Context:\n${context}\n\nQuestion: ${question}` }
            ],
            stream: false
          })
        });
        if (!response.ok) throw new Error(`Ollama error: ${response.status}`);
        const data = await response.json();
        reply = data.message?.content || "";
      } catch (e) {
        console.warn("⚠️ Ollama failed:", e.message);
        errors.push("Ollama: " + e.message);
      }
    }

    // ── All LLMs failed ────────────────────────────────────────────────────
    if (!reply) {
      return res.json({
        reply: `❌ All AI providers failed. Please check your configuration.\n\nDetails:\n${errors.map(e => "• " + e).join("\n")}`,
        sources: []
      });
    }

    // ── Append source pages ────────────────────────────────────────────────
    // Trim trailing punctuation before comparing so "Not found in document." also matches
    const replyNormalized = reply.trim().toLowerCase().replace(/[.!?]+$/, "");
    if (replyNormalized !== "not found in document" && sourcePages.length > 0) {
      const sourceStr = sourcePages.map(p => `Page ${p}`).join(", ");
      reply += `\n\nSources: ${sourceStr}`;
    }

    res.json({ reply, sources: sourcePages });

  } catch (e) {
    console.error("❌ Unexpected server error:", e);
    res.json({ reply: `❌ Server error: ${e.message}`, sources: [] });
  }
});

app.listen(3000, () => {
  console.log("🚀 Server running on http://localhost:3000");
});