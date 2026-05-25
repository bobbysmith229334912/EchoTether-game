# EchoTether-game Millionaire Roadmap

## Main decision
EchoTether-game is the main product focus.

The product should become the world/map/social layer where users bring their Mimoji avatar into an AR/location-based game world.

## Ecosystem structure

- Mimoji = avatar creation, AR identity, 3D export, paid upgrades
- EchoTether-game = world map, drops, whispers, location/social loop
- AnimeClashAI = battle system expansion
- StockMarketFrenzy = market-powered daily events and power-ups

## Safe build rules

1. Do not remove working features.
2. Do not hardcode a user UID or email.
3. Do not rely on ownerEmail as the source of truth.
4. Use Firebase Auth UID first.
5. Add new systems in small, reversible pieces.
6. Keep fallback paths for older data.
7. Add diagnostic logs so bugs are visible.
8. Monetize only after the daily loop is stable.

## Phase 1: Stabilize identity and Mimoji loading

Goal: every user should be able to bring their own Mimoji into EchoTether-game.

Required behavior:

- Read current Firebase Auth UID.
- Check current user's active Mimoji paths first.
- Check old compatibility paths second.
- Check public EchoTether Mimojis last.
- Never depend on Bobby's personal account.
- Never depend on email-only lookup.

## Phase 2: Add daily retention

Add one clear daily action loop:

- daily drop
- daily whisper
- daily reward
- daily AR check-in
- daily Mimoji energy refill

Start with one. Do not add all at once.

## Phase 3: Add viral growth

Add one share mechanic:

- share a discovered drop
- share a Mimoji location card
- share a battle result
- share a whisper invite

## Phase 4: Monetization

Only after onboarding and daily retention are stable:

- Pro subscription
- premium drops
- premium avatar/world cosmetics
- creator tools
- advanced map features

## First implementation target

Add a universal Mimoji lookup service that is safe, additive, and does not break the existing app if not wired in yet.
