import express from "express";
import cors from "cors";
import mongoose from "mongoose";
import multer from "multer";
import { spawn } from "child_process";
import { Readable } from "stream";
import { Codegen } from "./fingerprint";
import { Song } from "./models/song";
import { Fingerprint } from "./models/fingerprint";

const app = express();
const port = process.env.PORT || 3000;

// MongoDB connection
mongoose
  .connect("mongodb://localhost:27017/audio_fingerprint")
  .then(() => console.log("Connected to MongoDB"))
  .catch((err) => console.error("MongoDB connection error:", err));

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true })); // For parsing form data

import path from "path";
import fs from "fs";

// Create uploads directory if it doesn't exist
const uploadsDir = path.join(__dirname, "../uploads");
if (!fs.existsSync(uploadsDir)) {
  fs.mkdirSync(uploadsDir, { recursive: true });
}

// File upload configuration
const storage = multer.diskStorage({
  destination: (req, file, cb) => {
    cb(null, uploadsDir);
  },
  filename: (req, file, cb) => {
    const timestamp = Date.now();
    const ext = path.extname(file.originalname);
    cb(null, `recording_${timestamp}${ext}`);
  },
});

const upload = multer({
  storage,
  fileFilter: (req, file, cb) => {
    // Accept audio files by extension
    const allowedExtensions = [".mp3", ".wav", ".m4a", ".ogg"];
    const fileExt = file.originalname.toLowerCase().split(".").pop();
    console.log("File extension:", fileExt);
    console.log("Mimetype:", file.mimetype);

    if (fileExt && allowedExtensions.includes("." + fileExt)) {
      cb(null, true);
    } else {
      cb(new Error("Only audio files (mp3, wav, m4a, ogg) are allowed"));
    }
  },
});

// Helper function to generate fingerprints
async function generateFingerprints(
  buffer: Buffer,
  options: { preprocess?: boolean; adaptiveThreshold?: boolean } = {}
): Promise<{ tcodes: number[]; hcodes: number[] }> {
  return new Promise((resolve, reject) => {
    console.log("Starting fingerprint generation...");
    const fingerprinter = new Codegen(options);
    const decoder = spawn(
      "ffmpeg",
      [
        "-i",
        "pipe:0",
        "-acodec",
        "pcm_s16le",
        "-ar",
        "22050",
        "-ac",
        "1",
        "-f",
        "wav",
        "-v",
        "info", // Changed from fatal to info for more logging
        "pipe:1",
      ],
      { stdio: ["pipe", "pipe", "pipe"] }
    );

    decoder.stderr.on("data", (data) => {
      console.log("FFmpeg:", data.toString());
    });

    let tcodes: number[] = [];
    let hcodes: number[] = [];

    fingerprinter.on("data", (data: { tcodes: number[]; hcodes: number[] }) => {
      console.log("Received fingerprint data chunk");
      tcodes = tcodes.concat(data.tcodes);
      hcodes = hcodes.concat(data.hcodes);
    });

    fingerprinter.on("end", () => {
      console.log("Fingerprint generation complete");
      console.log(`Generated ${tcodes.length} fingerprints`);
      resolve({ tcodes, hcodes });
    });

    fingerprinter.on("error", (err) => {
      console.error("Error in fingerprint generation:", err);
      reject(err);
    });

    decoder.stdout.pipe(fingerprinter);
    const readable = new Readable();
    readable.push(buffer);
    readable.push(null);
    readable.pipe(decoder.stdin);
  });
}

// Routes
app.post("/add", upload.single("file"), async (req, res) => {
  try {
    if (!req.file) {
      return res.status(400).json({ error: "No audio file provided" });
    }

    const { tcodes, hcodes } = await generateFingerprints(fs.readFileSync(req.file.path));

    // Create song record
    const song = new Song({
      name: req.file.originalname,
      duration: tcodes[tcodes.length - 1] || 0,
    });
    await song.save();

    // Store fingerprints
    const fingerprints = tcodes.map((offset, index) => ({
      songId: song._id,
      hash: hcodes[index],
      offset,
    }));
    await Fingerprint.insertMany(fingerprints);

    res.json({
      message: "Song added successfully",
      songId: song._id,
      fingerprintCount: fingerprints.length,
    });
  } catch (err) {
    console.error("Error processing audio:", err);
    res.status(500).json({ error: "Error processing audio file" });
  }
});

// app.post("/match", upload.single("file"), async (req, res) => {
//   try {
//     console.log("Received file:", req.file);
//     if (!req.file) {
//       return res.status(400).json({ error: "No audio file provided" });
//     }
//     console.log(req.body);
//     const isLiveRecording = req.body?.isLive === "true";
//     console.log("Recording type:", isLiveRecording ? "live" : "file");

//     console.log("Starting fingerprint generation for matching...");
//     const { tcodes, hcodes } = await generateFingerprints(req.file.buffer, {
//       preprocess: isLiveRecording,
//       adaptiveThreshold: isLiveRecording,
//     });
//     console.log("Fingerprints generated, searching for matches...");

//     console.log(`Processing ${hcodes.length} fingerprints...`);
//     const matches = new Map<string, { offsets: number[]; count: number }>();

//     // Process each hash individually like the original implementation
//     for (let i = 0; i < hcodes.length; i++) {
//       const hash = hcodes[i];
//       const fingerprints = await Fingerprint.find({ hash });

//       for (const fp of fingerprints) {
//         const songId = fp.songId.toString();
//         const timeDiff = tcodes[i] - fp.offset;

//         if (!matches.has(songId)) {
//           matches.set(songId, { offsets: [], count: 0 });
//         }

//         const songMatch = matches.get(songId)!;
//         songMatch.offsets.push(timeDiff);
//         songMatch.count++;
//       }
//     }

//     console.log(`Found ${matches.size} matching fingerprints`);

//     // Find best match using time offset clusters
//     let bestMatch = null;
//     let bestScore = 0;
//     let bestClusterDensity = 0;

//     for (const [songId, match] of matches) {
//       // Calculate match score with adaptive time window for live recordings
//       const offsetCounts = new Map<number, number>();
//       const timeWindow = isLiveRecording ? 0.2 : 0.1; // Wider window for live recordings

//       match.offsets.forEach((offset) => {
//         const rounded = Math.round(offset / timeWindow) * timeWindow;
//         offsetCounts.set(rounded, (offsetCounts.get(rounded) || 0) + 1);
//       });

//       const largestCluster = Math.max(...offsetCounts.values());
//       // Calculate density based on input fingerprints, not total matches
//       const clusterDensity = largestCluster / hcodes.length;

//       // Score calculation with adaptive thresholds
//       const MIN_ALIGNED = isLiveRecording ? 5 : 10; // Even more forgiving for live
//       const MIN_DENSITY = isLiveRecording ? 0.01 : 0.2; // Much more forgiving density for live

//       // For live recordings, use a weighted score that considers both alignment and match count
//       console.log({ isLiveRecording });
//       const score = isLiveRecording
//         ? largestCluster * 2 + match.count / hcodes.length // Boost alignment and consider total matches
//         : largestCluster >= MIN_ALIGNED && clusterDensity >= MIN_DENSITY
//         ? largestCluster
//         : 0;

//       console.log({
//         score,
//         largestCluster,
//         inputFingerprints: hcodes.length,
//         density: clusterDensity,
//       });
//       console.log(
//         `Song ${songId}: matches=${
//           match.count
//         }, aligned=${largestCluster}, density=${clusterDensity.toFixed(2)}`
//       );

//       if (score > bestScore) {
//         bestScore = score;
//         bestMatch = songId;
//         bestClusterDensity = clusterDensity;
//       }
//     }

//     // Calculate confidence with adaptive thresholds
//     const minConfidenceThreshold = isLiveRecording ? 15 : 25; // Lower threshold for live
//     const minDensityThreshold = isLiveRecording ? 0.01 : 0.1; // Lower density requirement for live

//     // For live recordings, calculate confidence differently
//     const confidence = isLiveRecording
//       ? Math.min(100, (bestScore / 5) * 100) // More forgiving confidence calculation
//       : Math.min(100, (bestScore / Math.min(20, hcodes.length)) * 100);

//     console.log({
//       confidence,
//       bestScore,
//       hcodesLength: hcodes.length,
//       isLiveRecording,
//     });

//     // Adaptive matching criteria
//     if (
//       bestMatch &&
//       confidence >= minConfidenceThreshold &&
//       bestClusterDensity >= minDensityThreshold
//     ) {
//       // Only return matches with decent confidence
//       const song = await Song.findById(bestMatch);
//       console.log(
//         `Match found: ${song?.name} with confidence ${confidence.toFixed(2)}%`
//       );
//       res.json({
//         matched: true,
//         song,
//         confidence: Math.min(100, confidence),
//         stats: {
//           score: bestScore,
//           totalFingerprints: hcodes.length,
//           clusterDensity: bestClusterDensity,
//         },
//       });
//     } else {
//       console.log("No confident match found");
//       res.json({
//         matched: false,
//         stats: {
//           totalFingerprints: hcodes.length,
//           bestScore: bestScore,
//           bestClusterDensity: bestClusterDensity,
//         },
//       });
//     }
//   } catch (err) {
//     console.error("Error matching audio:", err);
//     res.status(500).json({ error: "Error matching audio file" });
//   }
// });
app.post("/match", upload.single("file"), async (req, res) => {
  try {
    console.log("Received file:", req.file);
    if (!req.file) {
      return res.status(400).json({ error: "No audio file provided" });
    }
    console.log(req.body);
    const isLiveRecording = req.body?.isLive === "true";
    console.log("Recording type:", isLiveRecording ? "live" : "file");

    console.log("Starting fingerprint generation for matching...");
    const { tcodes, hcodes } = await generateFingerprints(fs.readFileSync(req.file.path), {
      preprocess: isLiveRecording,
      adaptiveThreshold: isLiveRecording,
    });
    console.log("Fingerprints generated, searching for matches...");

    console.log(`Processing ${hcodes.length} fingerprints...`);
    const matches = new Map();

    for (let i = 0; i < hcodes.length; i++) {
      const hash = hcodes[i];
      const fingerprints = await Fingerprint.find({ hash });

      for (const fp of fingerprints) {
        const songId = fp.songId.toString();
        const timeDiff = tcodes[i] - fp.offset;

        if (!matches.has(songId)) {
          matches.set(songId, { offsets: [], count: 0 });
        }

        const songMatch = matches.get(songId);
        songMatch.offsets.push(timeDiff);
        songMatch.count++;
      }
    }

    console.log(`Found ${matches.size} matching fingerprints`);

    // Find best match using time offset clusters
    let bestMatch = null;
    let bestScore = 0;
    let bestClusterDensity = 0;

    // Calculate scores for all songs
    const scores = Array.from(matches.entries())
      .map(([songId, match]) => {
        const offsetCounts = new Map();
        const timeWindow = isLiveRecording ? 0.15 : 0.1;

        match.offsets.forEach((offset: any) => {
          const rounded = Math.round(offset / timeWindow) * timeWindow;
          offsetCounts.set(rounded, (offsetCounts.get(rounded) || 0) + 1);
        });

        const largestCluster = Math.max(...offsetCounts.values(), 0);
        const clusterDensity =
          hcodes.length > 0 ? largestCluster / hcodes.length : 0;

        // Score calculation with adaptive thresholds
        const MIN_ALIGNED = isLiveRecording ? 8 : 10; // Stricter alignment for live
        const MIN_DENSITY = isLiveRecording ? 0.05 : 0.2; // Stricter density for live

        const score = isLiveRecording
          ? largestCluster * 2 + match.count / hcodes.length // Boost alignment
          : largestCluster >= MIN_ALIGNED && clusterDensity >= MIN_DENSITY
          ? largestCluster
          : 0;

        console.log({
          songId,
          score,
          largestCluster,
          inputFingerprints: hcodes.length,
          density: clusterDensity,
        });
        console.log(
          `Song ${songId}: matches=${
            match.count
          }, aligned=${largestCluster}, density=${clusterDensity.toFixed(2)}`
        );

        return { songId, score, density: clusterDensity };
      })
      .sort((a, b) => b.score - a.score);

    // Cross-song comparison to reject ambiguous matches
    if (scores.length > 1 && scores[0].score - scores[1].score < 10) {
      console.log("Ambiguous match detected, rejecting");
      res.json({
        matched: false,
        stats: {
          totalFingerprints: hcodes.length,
          bestScore: scores[0].score,
          bestClusterDensity: scores[0].density,
        },
      });
      return;
    }

    // Set best match if there’s a valid candidate
    if (scores.length > 0 && scores[0].score > 0) {
      bestMatch = scores[0].songId;
      bestScore = scores[0].score;
      bestClusterDensity = scores[0].density;
    }

    // Calculate confidence with adaptive thresholds
    const minConfidenceThreshold = isLiveRecording ? 20 : 25; // Stricter for live
    const minDensityThreshold = isLiveRecording ? 0.05 : 0.1; // Stricter density

    const confidence = isLiveRecording
      ? Math.min(90, (bestScore / 5) * 100 * (bestClusterDensity / 0.1)) // Scale by density
      : Math.min(100, (bestScore / Math.min(20, hcodes.length)) * 100);

    console.log({
      confidence,
      bestScore,
      hcodesLength: hcodes.length,
      isLiveRecording,
    });

    // Adaptive matching criteria
    if (
      bestMatch &&
      confidence >= minConfidenceThreshold &&
      bestClusterDensity >= minDensityThreshold
    ) {
      const song = await Song.findById(bestMatch);
      console.log(
        `Match found: ${song?.name} with confidence ${confidence.toFixed(2)}%`
      );
      res.json({
        matched: true,
        song,
        confidence: Math.min(100, confidence),
        stats: {
          score: bestScore,
          totalFingerprints: hcodes.length,
          clusterDensity: bestClusterDensity,
        },
      });
    } else {
      console.log("No confident match found");
      res.json({
        matched: false,
        stats: {
          totalFingerprints: hcodes.length,
          bestScore: bestScore,
          bestClusterDensity: bestClusterDensity,
        },
      });
    }
  } catch (err) {
    console.error("Error matching audio:", err);
    res.status(500).json({ error: "Error matching audio file" });
  }
});
app.get("/songs", async (req, res) => {
  try {
    const songs = await Song.find().sort("-created_at");
    res.json(songs);
  } catch (err) {
    console.error("Error fetching songs:", err);
    res.status(500).json({ error: "Error fetching songs" });
  }
});

// Delete a song and its fingerprints
app.get("/songs/:id", async (req, res) => {
  try {
    const songId = req.params.id;
    await Fingerprint.deleteMany({ songId });
    await Song.findByIdAndDelete(songId);
    res.json({ message: "Song deleted successfully" });
  } catch (err) {
    console.error("Error deleting song:", err);
    res.status(500).json({ error: "Error deleting song" });
  }
});

app.listen(port, () => {
  console.log(`Server running at http://0.0.0.0:${port}`);
});
