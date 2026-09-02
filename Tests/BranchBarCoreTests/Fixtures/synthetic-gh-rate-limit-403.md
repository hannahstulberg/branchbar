# synthetic: `gh` stderr when the core rate limit is exhausted

`HTTP 403: API rate limit exceeded`. Must map to `PRUnavailableReason.rateLimited`, whose copy says waiting fixes it, and never to `commandFailed`.

Invariant: `rateLimitResponseMapsToRateLimitedNotCommandFailed`.
