# Data freshness

**Default: live.** Every WinDeployKit panel reflects *machine state right now* —
services up or down, transfers in flight, clients mid-deployment, what is
actually on disk in the image library. State changes outside the app (a service
stopped from a terminal, an ISO dropped into the folder, a client PXE-booting),
so a panel that trusts a TTL will lie.

This is the opposite of the USM original it was ported from, where the expensive
sources were LDAP directory reads — staff and student lists that change daily at
most, and where a cached list shown instantly was strictly better than a spinner.
Those panels are not here.

## The rule

| Data | Treatment |
| --- | --- |
| Service status (HTTP/TFTP/SMB), PXE config | Poll, 8s |
| Imaging clients, per-device log | Poll, 3s while expanded |
| PXE activity log | Poll, 3s while expanded |
| Downloads / transfers | Poll, 2s |
| Image library, boot WIMs, driver store | Refetch on mount + after any mutation |
| Stored credential list | Poll, 30s |
| Vendor SCCM driver catalogs | **Cached (168h)** — see below |

## Caching is not banned

The cache layer (`lib/queryCache.ts`, `useCachedQuery`, `cacheTtls.ts`) is kept,
for two legitimate uses:

1. **Paint buffer.** A cached value lets a remounted panel paint instantly
   instead of flashing empty, while the live fetch lands underneath. Pass
   `pollMs` and the cached value is never the final answer.
2. **Genuinely slow, genuinely static remote data.** Vendor driver catalogs are
   the clear case: multi-hundred-KB CAB/XML downloads from Dell/HP/Lenovo/Acer
   that change a few times a year, where clients must *not* hammer vendor WAFs.
   Those stay cached on disk with a long TTL and an explicit **Refresh
   catalogs** button.

If a new panel wants a TTL, the question to answer first: *can this change
without the app knowing?* If yes, it polls.

## How to write a live panel

```ts
const { data, refetch } = useCachedQuery<Thing>(
  "thing",
  () => sidecar.invoke<Thing>("GetThing"),
  { ttlMs: 0, pollMs: 5_000, invalidateOnRefetch: false },
);
```

`ttlMs: 0` means the mount fetch is never served from cache; `pollMs` keeps it
live afterwards. Call `refetch()` after any mutation rather than waiting a tick.
