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

import logging

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

@app.route('/add', methods=['POST'])
def add_song():
    logger.info('Starting add_song process')
    if 'file' not in request.files:
        logger.error('No file found in request')
        return jsonify({'error': 'No file part'}), 400
    
    file = request.files['file']
    song_name = request.form.get('name', '')
    logger.info(f'Received file: {file.filename}, song name: {song_name}')
    
    if file.filename == '' or song_name == '':
        logger.error('Missing file or song name')
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
            logger.info('Generating fingerprints')
            fingerprints = generate_fingerprints(peaks, song_id)
            logger.info(f'Number of fingerprints generated: {len(fingerprints)}')
            
            # Store fingerprints
            logger.info('Storing fingerprints in database')
            for hash_value, (offset, _) in fingerprints.items():
                c.execute(
                    'INSERT INTO fingerprints (hash, song_id, offset) VALUES (?, ?, ?)',
                    (hash_value, song_id, offset)
                )
            logger.info('Fingerprints stored successfully')
            
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
    try:
        if 'file' not in request.files:
            print('Error: No file in request')
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
                
                print('\n' + '='*50)
                print('MATCHING PROCESS STARTED')
                print('='*50)
                print(f'Sample has {len(sample_fingerprints)} fingerprints')
                
                conn = sqlite3.connect(DATABASE_PATH)
                c = conn.cursor()
                
                matches = {}
                total_hash_matches = 0
                
                print('\nFINGERPRINT MATCHES:')
                print('-'*30)
                
                for hash_value, (sample_offset, _) in sample_fingerprints.items():
                    c.execute('''
                        SELECT f.song_id, f.offset, s.name 
                        FROM fingerprints f 
                        JOIN songs s ON f.song_id = s.id 
                        WHERE f.hash = ?
                    ''', (hash_value,))
                    results = c.fetchall()
                    if results:
                        total_hash_matches += len(results)
                        print(f'\nHash {hash_value}:')
                        print(f'  Sample offset: {sample_offset:.2f}s')
                        for song_id, db_offset, song_name in results:
                            print(f'  → Matched in "{song_name}" at {db_offset:.2f}s (time diff: {(sample_offset - db_offset):.2f}s)')
                            if song_id not in matches:
                                matches[song_id] = {
                                    'name': song_name,
                                    'offsets': []
                                }
                            matches[song_id]['offsets'].append(sample_offset - db_offset)
                
                print('\n' + '='*50)
                print('ANALYZING MATCHES')
                print('='*50)
                print(f'Total fingerprint matches across all songs: {total_hash_matches}')
                
                best_match = None
                highest_score = 0
                
                for song_id, data in matches.items():
                    print(f'\nAnalyzing: "{data["name"]}"')
                    print(f'Total matches: {len(data["offsets"])}')
                    
                    offset_histogram = {}
                    for offset in data['offsets']:
                        offset_histogram[offset] = offset_histogram.get(offset, 0) + 1
                    
                    print('Time difference histogram:')
                    for offset, count in sorted(offset_histogram.items()):
                        print(f'  {offset:.2f}s: {"*" * count} ({count} matches)')
                    
                    score = max(offset_histogram.values()) if offset_histogram else 0
                    
                    if score > highest_score:
                        highest_score = score
                        best_match = {
                            'id': song_id,
                            'name': data['name'],
                            'score': score
                        }
                
                confidence = (highest_score / len(sample_fingerprints)) * 100 if sample_fingerprints else 0
                
                print('\n' + '='*50)
                print('FINAL RESULTS')
                print('='*50)
                print(f'Sample fingerprints: {len(sample_fingerprints)}')
                print(f'Best matching song: {best_match["name"] if best_match else "None"}')
                print(f'Highest matching score: {highest_score} fingerprints at same time offset')
                print(f'Confidence: {confidence:.2f}%')
                
                response = {
                    'matched': False,
                    'confidence': confidence,
                    'song': None,
                    'songName': None,
                    'song_id': None
                }
                
                if best_match and confidence > 15 and highest_score > 1:
                    print('\n✅ MATCH FOUND!')
                    response.update({
                        'matched': True,
                        'song': best_match['name'],
                        'songName': best_match['name'],
                        'song_id': best_match['id']
                    })
                else:
                    print('\n❌ NO CONFIDENT MATCH')
                    if best_match:
                        response.update({
                            'song': best_match['name'],
                            'songName': best_match['name'],
                            'song_id': best_match['id']
                        })
                
                return jsonify(response)
                
            finally:
                # Cleanup
                try:
                    os.remove(filepath)
                    os.rmdir(temp_dir)
                except Exception as e:
                    print(f'Error cleaning up: {str(e)}')
        
        return jsonify({'error': 'Invalid file type'}), 400
        
    except Exception as e:
        print(f'Error in match_audio: {str(e)}')
        return jsonify({'error': str(e)}), 500
    
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
            print('\n' + '='*50)
            print('MATCHING PROCESS STARTED')
            print('='*50)
            print(f'Sample has {len(sample_fingerprints)} fingerprints')
            
            conn = sqlite3.connect(DATABASE_PATH)
            c = conn.cursor()
            
            matches = {}
            total_hash_matches = 0
            
            # Track all fingerprint matches
            print('\nFINGERPRINT MATCHES:')
            print('-'*30)
            
            for hash_value, (sample_offset, _) in sample_fingerprints.items():
                # Find matching fingerprints
                c.execute('''
                    SELECT f.song_id, f.offset, s.name 
                    FROM fingerprints f 
                    JOIN songs s ON f.song_id = s.id 
                    WHERE f.hash = ?
                ''', (hash_value,))
                results = c.fetchall()
                if results:
                    total_hash_matches += len(results)
                    print(f'\nHash {hash_value}:')
                    print(f'  Sample offset: {sample_offset:.2f}s')
                    for song_id, db_offset, song_name in results:
                        print(f'  → Matched in "{song_name}" at {db_offset:.2f}s (time diff: {(sample_offset - db_offset):.2f}s)')
                
                for song_id, db_offset, song_name in c.fetchall():
                    if song_id not in matches:
                        matches[song_id] = {
                            'name': song_name,
                            'offsets': []
                        }
                    matches[song_id]['offsets'].append(sample_offset - db_offset)
            
            # Find best match
            print('\n' + '='*50)
            print('ANALYZING MATCHES')
            print('='*50)
            print(f'Total fingerprint matches across all songs: {total_hash_matches}')
            
            best_match = None
            highest_score = 0
            
            for song_id, data in matches.items():
                print(f'\nAnalyzing: "{data["name"]}"')
                print(f'Total matches: {len(data["offsets"])}')
                
                # Enhanced offset grouping with weighted scoring
                offset_histogram = {}
                for offset in data['offsets']:
                    # Use smaller intervals (0.05s) for more precise grouping
                    rounded_offset = round(offset * 20) / 20
                    # Add weighted score based on how close offsets are
                    for nearby_offset in np.arange(rounded_offset - 0.3, rounded_offset + 0.3, 0.05):
                        weight = 1.0 - (abs(nearby_offset - rounded_offset) / 0.3)  # Linear weight decay
                        if weight > 0:
                            offset_histogram[round(nearby_offset * 20) / 20] = \
                                offset_histogram.get(round(nearby_offset * 20) / 20, 0) + weight
                
                print('Time difference histogram (grouped by 0.1s intervals):')
                for offset, count in sorted(offset_histogram.items()):
                    print(f'  {offset:.1f}s: {"*" * count} ({count} matches)')
                
                # Filter out matches with unreasonable time offsets
                # We expect offsets to be within the song duration (plus some margin)
                valid_offsets = []
                for offset in data['offsets']:
                    # Typical song is under 10 minutes (600 seconds)
                    # Allow for some margin of error (±1000 seconds)
                    if abs(offset) < 1000:
                        valid_offsets.append(offset)
                
                # Update offsets with only valid ones
                data['offsets'] = valid_offsets
                total_matches = len(valid_offsets)
                
                if total_matches < 3:  # Require at least 3 valid matches
                    continue
                
                # Calculate match density for valid matches
                match_density = total_matches / (sample_duration / 1000) if sample_duration > 0 else 0
                
                # Calculate temporal consistency
                sorted_offsets = sorted(valid_offsets)
                if len(sorted_offsets) > 1:
                    # Calculate gaps between consecutive matches
                    gaps = np.diff(sorted_offsets)
                    mean_gap = np.mean(gaps)
                    std_gap = np.std(gaps)
                    
                    # Consistency score (0-1) - lower std deviation means better consistency
                    consistency = 1.0 / (1.0 + std_gap/mean_gap) if mean_gap != 0 else 0
                else:
                    consistency = 0
                
                # Calculate cluster score - how many matches are close together
                clusters = {}
                for offset in valid_offsets:
                    # Round to nearest 0.1 second
                    rounded = round(offset * 10) / 10
                    clusters[rounded] = clusters.get(rounded, 0) + 1
                
                # Get the size of the largest cluster
                largest_cluster = max(clusters.values()) if clusters else 0
                
                # Calculate cluster density (what percentage of matches are in the largest cluster)
                cluster_density = largest_cluster / total_matches if total_matches > 0 else 0
                
                
                # Calculate final score with adjusted weights
                score = (
                    largest_cluster * 0.4 +  # Weight for matches in best cluster
                    (match_density * 10) * 0.3 +  # Weight for overall match density
                    (consistency * total_matches) * 0.2 +  # Weight for temporal consistency
                    (cluster_density * total_matches) * 0.1  # Weight for cluster quality
                )
                
                # Only consider as potential match if we have good cluster density
                if cluster_density < 0.3:  # At least 30% of matches should be in the main cluster
                    continue
                
                if score > highest_score:
                    highest_score = score
                    best_match = {
                        'id': song_id,
                        'name': data['name'],
                        'score': score
                    }
            
            # Calculate expected fingerprints dynamically based on audio characteristics
            sample_duration = max([offset for offset, _ in sample_fingerprints.values()]) if sample_fingerprints else 0
            # Base expectation on actual fingerprints generated for full songs
            c.execute('''
                SELECT AVG(fingerprint_count) / AVG(duration) as fps 
                FROM (
                    SELECT song_id, COUNT(*) as fingerprint_count, MAX(offset)/1000.0 as duration
                    FROM fingerprints 
                    GROUP BY song_id
                )
            ''')
            avg_fingerprints_per_second = c.fetchone()[0] or 10  # fallback to 10 if no data
            expected_fingerprints = (sample_duration / 1000) * avg_fingerprints_per_second
            
            # Enhanced confidence calculation with relative metrics
            if expected_fingerprints > 0 and sample_fingerprints:
                # Get match statistics for best match
                if best_match:
                    match_data = matches[best_match['id']]
                    total_matches = len(match_data['offsets'])
                    
                    # Calculate relative match ratio (compared to sample length)
                    relative_match_ratio = total_matches / len(sample_fingerprints)
                    
                    # Calculate time alignment consistency
                    sorted_offsets = sorted(match_data['offsets'])
                    if len(sorted_offsets) > 1:
                        time_diff_std = np.std(sorted_offsets)
                        time_consistency = 1.0 / (1.0 + time_diff_std)  # Closer to 1 if offsets are consistent
                    else:
                        time_consistency = 0
                
                # Calculate coverage score (0-1)
                # How well the matches are distributed across the sample duration
                match_times = sorted([offset for offset, _ in sample_fingerprints.values()])
                if len(match_times) > 1:
                    avg_gap = sample_duration / (len(match_times) - 1)
                    actual_gaps = [match_times[i+1] - match_times[i] for i in range(len(match_times)-1)]
                    gap_consistency = 1.0 - (np.std(actual_gaps) / avg_gap if avg_gap > 0 else 1.0)
                else:
                    gap_consistency = 0.0
                
                # Combine scores with weights
                raw_confidence = highest_score / expected_fingerprints
                weighted_confidence = (
                    raw_confidence * 0.6 +  # Base confidence from number of matches
                    time_consistency * 0.25 +  # Time alignment quality
                    gap_consistency * 0.15  # Distribution of matches
                ) * 100
                
                confidence = min(100, weighted_confidence)  # Cap at 100%
            else:
                confidence = 0
            
            print('\n' + '='*50)
            print('FINAL RESULTS')
            print('='*50)
            print(f'Sample duration: {sample_duration/1000:.2f} seconds')
            print(f'Sample fingerprints: {len(sample_fingerprints)}')
            print(f'Expected fingerprints: {expected_fingerprints:.0f}')
            print(f'Best matching song: {best_match["name"] if best_match else "None"}')
            print(f'Highest matching score: {highest_score} fingerprints at same time offset')
            print(f'Confidence: {confidence:.2f}%')
            
            # Prepare response
            response = {
                'matched': False,
                'confidence': confidence,
                'song': None,
                'songName': None,
                'song_id': None
            }
            
            # Stricter adaptive thresholds
            sample_length_factor = max(0.3, min(1.0, sample_duration / 10000))
            min_matches = max(10, int(sample_duration/1000))  # At least 10 matches or 1 match per second
            min_cluster_size = max(5, min_matches * 0.3)  # At least 30% of min_matches in largest cluster
            
            # Calculate match quality metrics
            if best_match:
                match_data = matches[best_match['id']]
                valid_matches = len([x for x in match_data['offsets'] if abs(x) < 1000])
                largest_match_cluster = max(clusters.values()) if 'clusters' in locals() and clusters else 0
            
            is_match = (
                best_match and 
                confidence > (15 * (1/sample_length_factor)) and  # Increased confidence threshold
                valid_matches >= min_matches and  # Must have enough valid matches
                largest_match_cluster >= min_cluster_size and  # Must have a good cluster
                ('cluster_density' in locals() and cluster_density >= 0.3)  # Must have concentrated matches
            )
            
            if is_match:
                print('\n✅ MATCH FOUND!')
                response.update({
                    'matched': True,
                    'song': best_match['name'],
                    'songName': best_match['name'],
                    'song_id': best_match['id']
                })
            else:
                print('\n❌ NO CONFIDENT MATCH')
                if best_match:
                    response.update({
                        'song': best_match['name'],
                        'songName': best_match['name'],
                        'song_id': best_match['id']
                    })
            
            return jsonify(response)
            
            # Prepare response
            response = {
                'matched': False,
                'confidence': confidence,
                'song': None,
                'songName': None,
                'song_id': None
            }
            
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
