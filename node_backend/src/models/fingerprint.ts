import mongoose from 'mongoose';

const fingerprintSchema = new mongoose.Schema({
    songId: { type: mongoose.Schema.Types.ObjectId, ref: 'Song', required: true },
    hash: { type: Number, required: true },
    offset: { type: Number, required: true },
    created_at: { type: Date, default: Date.now }
});

// Create an index for faster lookups
fingerprintSchema.index({ hash: 1 });

export const Fingerprint = mongoose.model('Fingerprint', fingerprintSchema);
