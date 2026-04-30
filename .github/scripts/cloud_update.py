"""
cloud_update.py — runs on GitHub Actions (no yt-dlp, API only)

Does two things:
  1. Refreshes SEED_SHORTS with live view/like counts and any new shorts
  2. Detects new live streams and adds them to SEED_TAGS as pending=True
     (the local LaunchAgent resolves pending entries via yt-dlp)
"""
import re, json, urllib.request, datetime

API_KEY          = 'AIzaSyCNTUjiXTQ-ftrP1NCiqBQXKO2Vu6XWFXs'
UPLOADS_PLAYLIST = 'UUvCAK_O_4gB4OvHr765ZuQg'
HTML_PATH        = 'index.html'
DAYS_BACK        = 92   # look at last 3 months of uploads


# ── helpers ──────────────────────────────────────────────────────────────────

def yt_get(url):
    with urllib.request.urlopen(url) as r:
        return json.loads(r.read())

def parse_duration(s):
    if not s or s == 'P0D':
        return 0
    m = re.match(r'P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?', s)
    if not m:
        return 0
    d, h, mi, sc = (int(m.group(i) or 0) for i in range(1, 5))
    return d * 86400 + h * 3600 + mi * 60 + sc

def fetch_uploads(days=DAYS_BACK):
    """Return list of {id, title, publishedAt} for every upload in last `days` days."""
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
    items, page_token = [], ''
    while True:
        url = (f'https://www.googleapis.com/youtube/v3/playlistItems'
               f'?part=snippet,contentDetails&playlistId={UPLOADS_PLAYLIST}'
               f'&maxResults=50&key={API_KEY}')
        if page_token:
            url += f'&pageToken={page_token}'
        data = yt_get(url)
        stop = False
        for it in data.get('items', []):
            pub_dt = datetime.datetime.fromisoformat(
                it['contentDetails']['videoPublishedAt'].replace('Z', '+00:00'))
            if pub_dt < cutoff:
                stop = True
                break
            items.append({
                'id':          it['contentDetails']['videoId'],
                'title':       it['snippet'].get('title', ''),
                'publishedAt': it['contentDetails']['videoPublishedAt'][:10],
            })
        page_token = data.get('nextPageToken', '')
        if not page_token or stop:
            break
    return items


def fetch_video_details(ids):
    """Return dict {id: {duration, stats, snippet}} for a list of video IDs."""
    details = {}
    for i in range(0, len(ids), 50):
        batch = ids[i:i+50]
        data = yt_get(
            f'https://www.googleapis.com/youtube/v3/videos'
            f'?part=contentDetails,statistics,liveStreamingDetails,snippet'
            f'&id={",".join(batch)}&key={API_KEY}'
        )
        for item in data.get('items', []):
            details[item['id']] = item
    return details


# ── main ─────────────────────────────────────────────────────────────────────

with open(HTML_PATH, encoding='utf-8') as f:
    html = f.read()

# Load existing SEED_TAGS
m = re.search(r'const SEED_TAGS = (\{.*?\});', html, re.DOTALL)
seed_tags = json.loads(m.group(1))

print(f'Fetching uploads from last {DAYS_BACK} days…')
uploads = fetch_uploads()
print(f'  {len(uploads)} uploads found')

all_ids = [u['id'] for u in uploads]
details = fetch_video_details(all_ids)
print(f'  {len(details)} video details fetched')

# ── 1. SEED_SHORTS refresh ────────────────────────────────────────────────────
shorts = []
for u in uploads:
    d = details.get(u['id'], {})
    dur_secs = parse_duration(d.get('contentDetails', {}).get('duration', ''))
    title    = d.get('snippet', {}).get('title', u['title'])
    stats    = d.get('statistics', {})
    is_short = dur_secs <= 180 or bool(re.search(r'#shorts?\b', title, re.IGNORECASE))
    if is_short:
        shorts.append({
            'id':              u['id'],
            'title':           title,
            'publishedAt':     u['publishedAt'],
            'durationSeconds': dur_secs,
            'viewCount':       int(stats.get('viewCount', 0)),
            'likeCount':       int(stats.get('likeCount', 0)),
            'commentCount':    int(stats.get('commentCount', 0)),
        })

shorts.sort(key=lambda x: x['publishedAt'], reverse=True)
total_views = sum(s['viewCount'] for s in shorts)
print(f'\nSEED_SHORTS: {len(shorts)} shorts, {total_views:,} views '
      f'({shorts[-1]["publishedAt"]} → {shorts[0]["publishedAt"]})')

shorts_json = json.dumps(shorts, ensure_ascii=False, separators=(',', ':'))
html = re.sub(r'const SEED_SHORTS = \[.*?\];', f'const SEED_SHORTS = {shorts_json};',
              html, flags=re.DOTALL)

# ── 2. SEED_TAGS — add new live streams as pending ───────────────────────────
new_pending = 0
for u in uploads:
    vid = u['id']
    if vid in seed_tags:
        continue   # already scanned (or already pending) — skip
    d = details.get(vid, {})
    # Only live streams (not shorts, not regular uploads)
    if d.get('liveStreamingDetails', {}).get('actualStartTime'):
        seed_tags[vid] = {'types': [], 'pending': True, 'error': 'awaiting local yt-dlp scan'}
        new_pending += 1

tags_json = json.dumps(seed_tags, ensure_ascii=False, separators=(',', ':'))
html = re.sub(r'const SEED_TAGS = \{.*?\};', f'const SEED_TAGS = {tags_json};',
              html, flags=re.DOTALL)
print(f'SEED_TAGS: {len(seed_tags)} entries ({new_pending} new pending)')

with open(HTML_PATH, 'w', encoding='utf-8') as f:
    f.write(html)
print('\nindex.html written ✓')
