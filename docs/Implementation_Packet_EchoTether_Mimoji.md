# Implementation Packet: EchoTether-game + Mimoji

## Objective
Turn EchoTether-game into the main world app and connect it safely to Mimoji as the avatar identity layer.

## Safe implementation order

### 1. Audit current app structure
Find:
- Swift app entry file
- Firebase initialization file
- authentication/session manager
- map/world screen
- character/avatar/model loading file
- any existing Mimoji lookup code

### 2. Add universal Mimoji sync service
The service must:
- use the signed-in user ID first
- support legacy user Mimoji paths
- support public EchoTether Mimoji documents
- never hardcode one user
- never depend on email as the only lookup key
- fail safely with nil if no Mimoji exists

### 3. Add diagnostics card
The card should show:
- signed-in status
- current user ID present or missing
- active Mimoji found or missing
- checked sources
- model URL found or missing

### 4. Wire into UI safely
The app must still load even if no Mimoji exists.

Expected UI states:
- signed out: show sign-in required message
- signed in, no Mimoji: show create/connect Mimoji prompt
- signed in, has Mimoji: show connected avatar card
- public Mimojis available: show discovery list later

### 5. Add retention loop
Start with one daily loop only:
- daily drop
- daily whisper
- daily check-in
- daily Mimoji energy reward

### 6. Add monetization later
Only after the loop works:
- premium drops
- premium map cosmetics
- pro creator tools
- avatar/world upgrades

## Data lookup priority

1. users/{uid}/echoMimojis/active
2. users/{uid}/activeMimoji/current
3. users/{uid}/mimojis newest updated item
4. echoTetherMimojis where ownerUid equals uid
5. echoTetherMimojis where isPublicForEchoTether equals true

## Acceptance criteria

- Existing app launch still works
- Signed-out state does not crash
- Signed-in user without Mimoji does not crash
- Signed-in user with Mimoji can resolve model URL
- No hardcoded UID
- No ownerEmail-only identity lookup
- Debug output explains what was checked

## Rollback plan
Because the first code update should be additive, rollback means removing the new service and diagnostics files only. Existing production files should not be replaced until verified.
