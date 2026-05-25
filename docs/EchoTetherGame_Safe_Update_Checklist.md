# EchoTether-game Safe Update Checklist

## Main rule
Make EchoTether-game better without breaking existing working code.

## Product focus
EchoTether-game is the main world app. Mimoji is the avatar identity system. AnimeClashAI can become the combat layer later. StockMarketFrenzy can become the daily event layer later.

## Identity rules
- Use the signed-in Firebase user as the source of truth.
- Do not hardcode a single user.
- Do not rely on email as the only account lookup.
- Keep older data paths supported while migrating.

## Mimoji rules
- Load the current user's active Mimoji first.
- Then check older compatible Mimoji paths.
- Then check public EchoTether Mimojis.
- If no Mimoji exists, keep the app usable.
- Add clear diagnostic logs for every checked source.

## Release safety
- One feature per update.
- Prefer new files before editing large existing files.
- Do not remove existing screens or features.
- Test signed-out state.
- Test signed-in state.
- Test no-Mimoji state.
- Test has-Mimoji state.
- Test app launch after every change.

## Priority order
1. Audit app entry and Firebase setup.
2. Add universal Mimoji lookup service.
3. Add safe diagnostics screen.
4. Add first daily loop.
5. Add one share mechanic.
6. Add monetization after retention works.
