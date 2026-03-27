## KCRW Tracklist API – Reverse Engineering Report

### Summary

The KCRW tracklist system still exposes a functional JSON API at:

```
https://tracklist-api.kcrw.com/Music/date/{YYYY}/{MM}/{DD}?page=N
```

The endpoint is **not publicly documented** and appears deprecated, but remains accessible if specific HTTP headers are provided. Without these headers, the server returns a frontend HTML shell instead of JSON.

---

## Endpoint Details

### Base Endpoint

```
GET /Music/date/{YYYY}/{MM}/{DD}?page={N}
Host: tracklist-api.kcrw.com
```

### Example

```
https://tracklist-api.kcrw.com/Music/date/2026/03/25?page=1
```

---

## Required Headers

Requests must include:

```
Accept: application/json
Origin: https://www.kcrw.com
Referer: https://www.kcrw.com/
```

### Behavior

- **With headers** → JSON response (tracklist data)
    
- **Without headers** → HTML (SPA app shell)
    

This indicates a **basic origin/referer gate**, not full authentication.

---

## Response Format

Returns a JSON array of track objects.

### Example Object

```json
{
  "title": "More Than a Love Song",
  "artist": "Black Pumas",
  "album": "Chronicles of a Diamond",
  "label": "ATO Records",
  "program_id": "e24",
  "program_title": "Eclectic 24",
  "time": "01:39 PM",
  "date": "2026-03-25",
  "datetime": "2026-03-25T13:39:20-07:00",
  "offset": 5960,
  "play_id": 1028574,
  "channel": "Music",
  "albumImage": "https://i.scdn.co/image/...",
  "spotify_id": "...",
  "itunes_id": "...",
  "comments": ""
}
```

---

## Field Notes

### Core Fields

- `title` → track name
    
- `artist` → artist name
    
- `time` → broadcast time (local station time)
    
- `datetime` → ISO timestamp (preferred for ordering)
    
- `play_id` → unique identifier per track
    
- `offset` → seconds from program start
    

### Program Metadata

- `program_id` → show identifier (e.g. `e24`)
    
- `program_title` → show name
    
- `program_start`, `program_end`
    

### Media / Metadata

- `album`, `label`, `year`
    
- `albumImage`, `albumImageLarge`
    
- `spotify_id`, `itunes_id`, affiliate links
    

### Special Cases

- Entries like:
    

```json
{ "artist": "[BREAK]", "title": null }
```

represent non-music segments.

---

## Pagination

- Controlled via `?page=N`
    
- Pages return arrays of tracks
    
- Termination conditions:
    
    - Empty array (`[]`)
        
    - Missing/empty response
        

### Observed Behavior

- Page size appears fixed (not configurable)
    
- No explicit `total` or `next` cursor
    
- Sequential pagination required
    

---

## Sorting / Ordering

Tracks appear:

- Reverse chronological within page (newest first)
    
- Use `datetime` or `offset` for stable ordering
    

---

## Rate Limiting / Stability

Unknown constraints:

- No visible auth token required
    
- Likely soft rate limiting (CloudFront present)
    

Recommendations:

- Avoid aggressive polling
    
- Cache responses where possible
    

---

## Failure Modes

|Condition|Result|
|---|---|
|Missing headers|HTML response (not JSON)|
|Invalid date|Empty array or error|
|Timeout|Curl/network failure|
|Future date|Likely empty array|

---

## Related Observations

### Frontend Architecture

- KCRW site uses a client-rendered app (React + virtualization)
    
- Tracklists are not server-rendered
    
- Internal API still powers frontend
    

### Virtualization

- UI uses `react-virtuoso`
    
- DOM does not contain full dataset
    
- Confirms API is authoritative source
    

---

## Alternative Endpoints (Unverified)

Based on patterns, these may exist:

```
/Music/all/{channel}
/Music/program/{program_id}
```

No confirmation of public accessibility.

---

## Security Model

Current protection:

- Header-based validation (Origin/Referer)
    
- No OAuth or token required
    

Implication:

- Intended for browser use only
    
- Not hardened against scripted access
    

---

## Implementation Requirements

A client must:

1. Format date as `YYYY/MM/DD`
    
2. Include required headers
    
3. Handle pagination
    
4. Parse JSON array responses
    
5. Filter invalid entries (e.g. `[BREAK]`)
    
6. Handle empty responses gracefully
    

---

## Example Request (Reference)

```
GET https://tracklist-api.kcrw.com/Music/date/2026/03/25?page=1

Headers:
  Accept: application/json
  Origin: https://www.kcrw.com
  Referer: https://www.kcrw.com/
```

---

## Key Takeaways

- The original `tracklist-api` is still operational
    
- Access is restricted only by basic header checks
    
- JSON structure is clean and consistent
    
- Pagination is simple but manual
    
- This is the most reliable source of KCRW track data currently available
    

---

## Risks

- Endpoint is undocumented and may change or be removed
    
- Header requirements could be tightened
    
- No SLA or versioning guarantees
    

---

## Recommendation

Treat this as an **unofficial internal API**:

- Wrap access in a thin abstraction layer
    
- Add fallback handling (e.g. HTML scraping if needed)
    
- Avoid tight coupling to response shape without validation
    

---