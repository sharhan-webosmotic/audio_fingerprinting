from flask import Flask, request, jsonify
from flask_cors import CORS
import os
import sqlite3
from datetime import datetime
from werkzeug.utils import secure_filename
import tempfile
import soundfile as sf
import numpy as np
from scipy import signal
from shazam_fingerprint import (
    create_spectrogram, 
    extract_peaks, 
    generate_fingerprints
)

app = Flask(__name__)
CORS(app)

# Configure upload folder
UPLOAD_FOLDER = 'temp_uploads'
ALLOWED_EXTENSIONS = {'wav', 'mp3', 'm4a', 'ogg'}

if not os.path.exists(UPLOAD_FOLDER):
    os.makedirs(UPLOAD_FOLDER)

app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER

# Database setup
DATABASE_PATH = 'songs.db'

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

def init_db():
    conn = sqlite3.connect(DATABASE_PATH)
    c = conn.cursor()
    
    # Drop existing tables if they exist
    c.execute('DROP TABLE IF EXISTS fingerprints')
    c.execute('DROP TABLE IF EXISTS songs')
    
    # Create tables with new schema
    c.execute('''
        CREATE TABLE songs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    c.execute('''
        CREATE TABLE fingerprints (
            hash INTEGER NOT NULL,
            song_id INTEGER NOT NULL,
            offset INTEGER NOT NULL,
            FOREIGN KEY(song_id) REFERENCES songs(id)
        )
    ''')
    conn.commit()
    conn.close()

@app.route('/add', methods=['POST'])
def add_song():
    if 'file' not in request.files:
        return jsonify({'error': 'No file part'}), 400
    
    file = request.files['file']
    song_name = request.form.get('name', '')
    
    if file.filename == '' or song_name == '':
        return jsonify({'error': 'Missing file or song name'}), 400
        
    if file and allowed_file(file.filename):
        # Create temporary file
        temp_dir = tempfile.mkdtemp()
        filename = secure_filename(file.filename)
        filepath = os.path.join(temp_dir, filename)
        file.save(filepath)
        
        try:
            # Load audio file using soundfile
            samples, sample_rate = sf.read(filepath)
            
            # Convert to mono if stereo
            if len(samples.shape) > 1:
                samples = samples.mean(axis=1)
            
            # Ensure float64
            samples = samples.astype(np.float64)
            
            # Generate spectrogram
            spectrogram = create_spectrogram(samples, sample_rate)
            
            # Extract peaks
            duration = len(samples) / sample_rate
            peaks = extract_peaks(spectrogram, duration)
            
            # Store song in database
            conn = sqlite3.connect(DATABASE_PATH)
            c = conn.cursor()
            
            c.execute('INSERT INTO songs (name) VALUES (?)', (song_name,))
            song_id = c.lastrowid
            fingerprints = generate_fingerprints(peaks, song_id)
            
            # Store fingerprints
            for hash_value, (offset, _) in fingerprints.items():
                c.execute(
                    'INSERT INTO fingerprints (hash, song_id, offset) VALUES (?, ?, ?)',
                    (hash_value, song_id, offset)
                )
            
            conn.commit()
            conn.close()
            
            return jsonify({
                'success': True,
                'message': f'Added song: {song_name}',
                'song_id': song_id,
                'stats': {
                    'duration': len(samples) / sample_rate,
                    'num_fingerprints': len(fingerprints)
                }
            })
            
        except Exception as e:
            print(f"Error adding song: {str(e)}")
            return jsonify({'error': str(e)}), 500
            
        finally:
            # Cleanup
            try:
                os.remove(filepath)
                os.rmdir(temp_dir)
            except Exception as e:
                print(f"Error cleaning up: {str(e)}")
    
    return jsonify({'error': 'Invalid file type'}), 400

@app.route('/clear_db', methods=['POST'])
def clear_database():
    try:
        conn = sqlite3.connect(DATABASE_PATH)
        c = conn.cursor()
        c.execute('DELETE FROM fingerprints')
        c.execute('DELETE FROM songs')
        conn.commit()
        conn.close()
        return jsonify({'message': 'Database cleared successfully'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/match', methods=['POST'])
def match_audio():
    if 'file' not in request.files:
        return jsonify({'error': 'No file part'}), 400
    
    file = request.files['file']
    
    if file.filename == '':
        return jsonify({'error': 'No selected file'}), 400
        
    if file and allowed_file(file.filename):
        # Create temporary file
        temp_dir = tempfile.mkdtemp()
        filename = secure_filename(file.filename)
        filepath = os.path.join(temp_dir, filename)
        file.save(filepath)
        
        try:
            # Load audio file using soundfile
            samples, sample_rate = sf.read(filepath)
            
            # Convert to mono if stereo
            if len(samples.shape) > 1:
                samples = samples.mean(axis=1)
            
            # Ensure float64
            samples = samples.astype(np.float64)
            
            # Generate spectrogram
            spectrogram = create_spectrogram(samples, sample_rate)
            
            # Extract peaks
            duration = len(samples) / sample_rate
            peaks = extract_peaks(spectrogram, duration)
            
            # Generate fingerprints (use 0 as temporary song_id)
            sample_fingerprints = generate_fingerprints(peaks, 0)
            
            # Match against database
            conn = sqlite3.connect(DATABASE_PATH)
            c = conn.cursor()
            
            matches = {}
            for hash_value, (sample_offset, _) in sample_fingerprints.items():
                # Find matching fingerprints
                c.execute('''
                    SELECT f.song_id, f.offset, s.name 
                    FROM fingerprints f 
                    JOIN songs s ON f.song_id = s.id 
                    WHERE f.hash = ?
                ''', (hash_value,))
                
                for song_id, db_offset, song_name in c.fetchall():
                    if song_id not in matches:
                        matches[song_id] = {
                            'name': song_name,
                            'offsets': []
                        }
                    matches[song_id]['offsets'].append(sample_offset - db_offset)
            
            # Find best match
            best_match = None
            highest_score = 0
            
            for song_id, data in matches.items():
                # Count how many offset differences are similar
                offset_histogram = {}
                for offset in data['offsets']:
                    offset_histogram[offset] = offset_histogram.get(offset, 0) + 1
                
                # Get the highest count of similar offsets
                score = max(offset_histogram.values()) if offset_histogram else 0
                
                if score > highest_score:
                    highest_score = score
                    best_match = {
                        'id': song_id,
                        'name': data['name'],
                        'score': score
                    }
            
            # Calculate confidence (normalize score)
            confidence = (highest_score / len(sample_fingerprints)) * 100 if sample_fingerprints else 0
            print(f"Confidence: {confidence}, Best match: {best_match}")
            print(f"Condition check: best_match exists: {bool(best_match)}, confidence > 15: {confidence > 15}")
            if best_match and confidence > 15 and highest_score > 1:  # Threshold can be adjusted
                print("Sending matched=True response")
                return jsonify({
                    'matched': True,
                    'song': best_match['name'],
                    'songName': best_match['name'],
                    'song_id': best_match['id'],
                    'confidence': confidence
                })
            
            print("Sending matched=False response")
            response = {
                'matched': False,
                'confidence': confidence
            }
            if best_match:
                response.update({
                    'song': best_match['name'],
                    'songName': best_match['name'],
                    'song_id': best_match['id']
                })
            return jsonify(response)
            
        except Exception as e:
            print(f"Error matching audio: {str(e)}")
            return jsonify({'error': str(e)}), 500
            
        finally:
            # Cleanup
            try:
                os.remove(filepath)
                os.rmdir(temp_dir)
            except Exception as e:
                print(f"Error cleaning up: {str(e)}")
    
    return jsonify({'error': 'Invalid file type'}), 400

# Initialize database
init_db()

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5001)
