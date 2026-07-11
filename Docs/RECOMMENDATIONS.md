# Recommendations

Atlas has three Home feed modes. Subscriptions is direct channel-following behavior. The two For You modes build a local candidate pool and rank it using on-device signals.

## Feed modes

Feed mode is persisted under `UserDefaults` key `feedMode`.

| Mode | Behavior |
| --- | --- |
| Subscriptions | Shows newest uploads from subscribed channels. |
| For You - Related | Uses Piped related videos, searches, saves, subscriptions, and simple ranking. |
| For You - Personalized | Uses on-device topic matching and explicit feedback. |

The player reads the current mode too, because feedback controls are only shown when the personalized mode is active.

## Signals

The personalized system derives its profile and ranking weights from local signals:

- Watch history.
- Resume position and known duration.
- Search history from successful searches.
- Saved playlist videos.
- Subscribed channels.
- Suggest More / Suggest Less feedback.
- Cached video category and tag metadata from `/streams`.

Atlas does not upload a recommendation profile or library database. It does send
recent search terms and video or channel identifiers derived from those local
signals to the selected Piped instance when gathering search, related-video,
channel, stream-metadata, or trending candidates.

## Candidate sources

`FeedView` and `RecommendationEngine` gather candidates from several sources:

- Related videos from recent watch seeds.
- Search results from recent search queries.
- Related videos from saved playlist seeds.
- Recent uploads from subscribed channels.
- Exploration seeds from additional watch history.

Candidates are deduped by video ID, capped per source, and merged into a target pool. Source attribution is retained so ranking can boost videos that appear from multiple sources.

## Cold start

If the user has no meaningful local signals, For You falls back to regional trending. Once history, subscriptions, saved videos, or recent searches exist, the feed switches to personalized candidate generation.

## Watch weighting

A watch becomes a stronger signal the more of the video was seen.

- Unknown duration is neutral.
- Around half watched is the baseline.
- Near-complete watches ramp up to a stronger signal.
- 80 percent watched is treated as finished for feed filtering and badges.

This avoids treating accidental opens as strong interest.

## Related ranking

For You - Related uses a lightweight score:

- Related frequency.
- Channel affinity.
- Subscribed-channel boost.
- Candidate source boost.
- Freshness.

It then diversifies the list so one creator or topic cannot dominate the top of the feed.

## Personalized topic ranking

For You - Personalized uses NaturalLanguage word embeddings on device.

It builds taste documents from:

- Recent watches.
- Likes.
- Saved videos.
- Recent searches.

It builds anti-taste documents from dislikes.

The ranking compares candidate vectors to the user's nearest interest vectors, adds channel/source boosts, and applies soft category gating. YouTube category and creator tags from `/streams` can refine the ranking after initial results are already shown.

## Feedback

Feedback rows store:

- Video ID.
- Signal: `+1` for Suggest More, `-1` for Suggest Less.
- Title.
- Uploader.
- Optional category.
- Optional tags.

Card menus can record feedback with title/uploader only. Info sheet feedback can record richer category/tag data because stream details have been resolved.

Tapping the active feedback state again clears it.

## Search history

Successful searches are stored as normalized `SearchEntry` rows with:

- Normalized query.
- Display query.
- Count.
- Last searched timestamp.

Recent searches are capped and age out as recommendation signals after 30 days. Repeated searches carry more weight.

## Recommendation caches

Atlas uses two caches:

- `RecommendationProfileSnapshot` caches selected seeds and channel affinity until the input signature changes.
- `VideoSignalCacheEntry` caches per-video category, tags, uploader, and topic key for 30 days.

These caches exist to keep For You responsive while avoiding repeated `/streams` calls.

## Refresh behavior

For You starts rendering as soon as useful candidates arrive. It can show an initial result set and later refine it once more signals are available.

Pull-to-refresh softly rotates the last top items downward so refresh can reveal other good candidates rather than repeating the same first screen.
