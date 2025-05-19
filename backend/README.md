# Audio Fingerprinting Backend

This is a Flask-based backend service for audio fingerprinting using Dejavu.

## Setup

1. Install Python dependencies:
```bash
pip install -r requirements.txt
```

2. Install MySQL and create a database:
```sql
CREATE DATABASE dejavu;
```

3. Update the database configuration in `app.py` if needed.

## API Endpoints

### POST /match
Match an audio file against the database.

Request:
- Multipart form data with 'file' field containing audio file (.wav, .mp3, etc.)

Response:
```json
{
    "match": true/false,
    "song": "Song Name",
    "confidence": 85.5
}
```

### POST /add
Add a new song to the database.

Request:
- Multipart form data with:
  - 'file': Audio file (.wav, .mp3, etc.)
  - 'name': Song name

Response:
```json
{
    "success": true,
    "message": "Added song: Song Name"
}
```

## Running the Server
```bash
python app.py
```
Server will run on http://localhost:5000
