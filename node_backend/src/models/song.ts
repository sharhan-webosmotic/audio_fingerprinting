import mongoose from 'mongoose';

const songSchema = new mongoose.Schema({
    name: { type: String, required: true },
    duration: { type: Number, required: true },
    created_at: { type: Date, default: Date.now }
});

export const Song = mongoose.model('Song', songSchema);
