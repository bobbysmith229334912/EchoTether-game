"use strict";

/**
 * Random Drops (backend-only)
 * - createRandomDrops: scheduled generator (creates drops in Firestore)
 * - claimDrop: HTTPS callable (server verifies location + anti-cheat + atomic claim)
 *
 * NOTE: This file is added safely and does NOT change your iOS app yet.
 */

const admin = require("firebase-admin");

function haversineMeters(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

function randBetween(min, max) {
  return min + Math.random() * (max - min);
}

/**
 * Generates a random coordinate around a center point.
 * This is a simple "random nearby" generator; later we can restrict to safe zones.
 */
function randomPointAround(lat, lng, minMeters, maxMeters) {
  const r = randBetween(minMeters, maxMeters);
  const theta = randBetween(0, Math.PI * 2);

  // meters -> degrees approx
  const dLat = (r * Math.cos(theta)) / 111320;
  const dLng = (r * Math.sin(theta)) / (111320 * Math.cos((lat * Math.PI) / 180));

  return { lat: lat + dLat, lng: lng + dLng };
}

/**
 * Drop schema (Firestore: drops/{dropId})
 * {
 *   lat, lng,
 *   createdAt, expiresAt,
 *   amountCents,
 *   visibilityRadiusM, claimRadiusM,
 *   status: "active"|"claimed"|"expired",
 *   claimedBy, claimedAt
 * }
 */

async function createRandomDrop({ centerLat, centerLng, amountCents, ttlMinutes, visibilityRadiusM, claimRadiusM }) {
  const db = admin.firestore();

  const now = admin.firestore.Timestamp.now();
  const expiresAt = admin.firestore.Timestamp.fromMillis(
    Date.now() + ttlMinutes * 60 * 1000
  );

  const p = randomPointAround(centerLat, centerLng, 80, 500);

  const docRef = db.collection("drops").doc();
  const drop = {
    lat: p.lat,
    lng: p.lng,
    createdAt: now,
    expiresAt,
    amountCents,
    currency: "USD",
    visibilityRadiusM,
    claimRadiusM,
    status: "active",
    claimedBy: null,
    claimedAt: null,
    createdBy: "SYSTEM"
  };

  await docRef.set(drop);
  return { dropId: docRef.id, ...drop };
}

async function claimDropTxn({ uid, dropId, userLat, userLng, userAccuracyM, deviceHash }) {
  const db = admin.firestore();
  const dropRef = db.collection("drops").doc(dropId);
  const userRef = db.collection("users").doc(uid);
  const claimRef = db.collection("claims").doc();

  const MAX_ACCURACY_M = 35;      // must be reasonably accurate
  const MAX_CLAIMS_PER_DAY = 3;   // safe default
  const CLAIM_COOLDOWN_SEC = 20;  // basic spam protection

  return await db.runTransaction(async (tx) => {
    const [dropSnap, userSnap] = await Promise.all([tx.get(dropRef), tx.get(userRef)]);

    if (!dropSnap.exists) {
      return { ok: false, reason: "drop_not_found" };
    }
    const drop = dropSnap.data();

    if (drop.status !== "active") {
      return { ok: false, reason: "drop_not_active" };
    }

    const nowMs = Date.now();
    if (drop.expiresAt && drop.expiresAt.toMillis() <= nowMs) {
      tx.update(dropRef, { status: "expired" });
      return { ok: false, reason: "drop_expired" };
    }

    if (!userLat || !userLng) return { ok: false, reason: "missing_location" };
    if (typeof userAccuracyM === "number" && userAccuracyM > MAX_ACCURACY_M) {
      return { ok: false, reason: "gps_inaccurate" };
    }

    const dist = haversineMeters(userLat, userLng, drop.lat, drop.lng);
    if (dist > (drop.claimRadiusM || 20)) {
      return { ok: false, reason: "too_far", distM: Math.round(dist) };
    }

    // initialize user doc if needed
    const user = userSnap.exists ? userSnap.data() : {};
    const lastClaimAtMs = user.lastClaimAt?.toMillis?.() ?? 0;

    if (lastClaimAtMs && (nowMs - lastClaimAtMs) / 1000 < CLAIM_COOLDOWN_SEC) {
      return { ok: false, reason: "claim_too_fast" };
    }

    // simple daily reset window: UTC day
    const todayKey = new Date().toISOString().slice(0, 10);
    const claimsTodayKey = user.claimsTodayKey || todayKey;
    let claimsToday = user.claimsToday || 0;
    if (claimsTodayKey !== todayKey) {
      claimsToday = 0;
    }
    if (claimsToday >= MAX_CLAIMS_PER_DAY) {
      return { ok: false, reason: "daily_limit" };
    }

    // Atomic claim
    tx.update(dropRef, {
      status: "claimed",
      claimedBy: uid,
      claimedAt: admin.firestore.Timestamp.now(),
      claimedDeviceHash: deviceHash || null
    });

    // Track reward as credits (safe first). You can convert later.
    const newBalance = (user.balanceCents || 0) + (drop.amountCents || 0);

    tx.set(userRef, {
      balanceCents: newBalance,
      lastKnownLat: userLat,
      lastKnownLng: userLng,
      lastSeenAt: admin.firestore.Timestamp.now(),
      lastClaimAt: admin.firestore.Timestamp.now(),
      claimsTodayKey: todayKey,
      claimsToday: claimsToday + 1,
      deviceHashLast: deviceHash || null
    }, { merge: true });

    tx.set(claimRef, {
      uid,
      dropId,
      amountCents: drop.amountCents || 0,
      lat: userLat,
      lng: userLng,
      accuracyM: userAccuracyM || null,
      deviceHash: deviceHash || null,
      createdAt: admin.firestore.Timestamp.now(),
      result: "approved",
      reason: null
    });

    return { ok: true, amountCents: drop.amountCents || 0, newBalanceCents: newBalance };
  });
}

module.exports = {
  createRandomDrop,
  claimDropTxn
};
