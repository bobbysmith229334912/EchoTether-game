/* eslint-disable */
// EchoTether Cloud Functions — P2P Wallet, Auto Release, Usernames, Referrals, Leaderboard
// + Digital Wallet Mode (Kraken-powered crypto rails, USDC-first)
// Node 18+ / 20 runtime, 1st Gen compatible

"use strict";

const functions = require("firebase-functions/v1");
// If you're on Node 18+ / 20, global fetch is available.
// If you ever run on Node < 18, install node-fetch and uncomment this:
// const fetch = (...args) => import("node-fetch").then(({ default: fetch }) => fetch(...args));

const admin = require("firebase-admin");
const Stripe = require("stripe");
const crypto = require("crypto");

// ---- Firebase init
try {
  admin.app();
} catch {
  admin.initializeApp();
}
const db = admin.firestore();
const houseWalletRef = db.collection("system").doc("houseWallet");


/* ==================== Global Config ==================== */

// Toggle for all Kraken / Digital Wallet Mode features
const ENABLE_CRYPTO_MODE = process.env.ENABLE_CRYPTO_MODE === "1";

// Kraken API base: use sandbox when KRAKEN_SANDBOX=1
const KRAKEN_API_BASE =
  process.env.KRAKEN_SANDBOX === "1"
    ? "https://api.sandbox.kraken.com"
    : "https://api.kraken.com";

// These must match your Kraken configuration
// Asset codes per Kraken's API (e.g. "USDC", "XBT", "ETH")
const KRAKEN_USDC_ASSET = process.env.KRAKEN_USDC_ASSET || "USDC";
const KRAKEN_BTC_ASSET = process.env.KRAKEN_BTC_ASSET || "XBT";
const KRAKEN_ETH_ASSET = process.env.KRAKEN_ETH_ASSET || "ETH";

// Deposit method IDs must be configured in your Kraken account & set as env vars
// Example (not actual): "USDC.USDC", "USDC-TRC20", etc.
const KRAKEN_USDC_METHOD = process.env.KRAKEN_USDC_METHOD || "";

// Assets we expose in "Digital Wallet Mode"
const SUPPORTED_CRYPTO_ASSETS = ["USDC", "BTC", "ETH"];

// Minimum withdrawal amounts (in asset units)
const MIN_WITHDRAW = {
  USDC: Number(process.env.MIN_WITHDRAW_USDC || "5"),
  BTC: Number(process.env.MIN_WITHDRAW_BTC || "0.0002"),
  ETH: Number(process.env.MIN_WITHDRAW_ETH || "0.005"),
};

// Max age for cached ticker prices
const KRAKEN_TICKER_TTL_SECONDS = 30;

/* ----------------------- Utilities ----------------------- */

const toNumber = (x, def = 0) =>
  typeof x === "number" ? x : (typeof x === "string" ? Number(x) : def);

const isInt = (n) => Number.isInteger(n) && isFinite(n);

// Strong lat/lon guard
function isValidLatLon(lat, lon) {
  return (
    Number.isFinite(lat) &&
    Number.isFinite(lon) &&
    Math.abs(lat) <= 90 &&
    Math.abs(lon) <= 180
  );
}

function haversineMeters(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLon = ((lon2 - lon1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((lat1 * Math.PI) / 180) *
      Math.cos((lat2 * Math.PI) / 180) *
      Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

// Safe integer cents
function cents(n) {
  const v = Number(n);
  if (!Number.isFinite(v) || v <= 0) return 0;
  return Math.floor(v);
}

/* ---------- Username validation helper ---------- */
function normalizeUsername(input) {
  const s = (input || "").trim();
  const min = 3;
  const max = 20;
  const allowed = /^[A-Za-z][A-Za-z0-9_]*$/;

  if (s.length < min || s.length > max) {
    return {
      ok: false,
      message: `Username must be ${min}-${max} characters.`,
    };
  }
  if (!allowed.test(s)) {
    return {
      ok: false,
      message:
        "Use letters, numbers, and underscores only; must start with a letter.",
    };
  }

  const reserved = new Set([
    "admin",
    "support",
    "help",
    "echo",
    "echotether",
    "system",
    "apple",
    "google",
    "firebase",
    "moderator",
    "root",
    "null",
    "undefined",
    "about",
    "terms",
    "privacy",
    "api",
    "v1",
    "v2",
    "me",
    "you",
    "owner",
    "user",
    "username",
    "profile",
    "settings",
  ]);

  const lower = s.toLowerCase();
  if (reserved.has(lower)) {
    return { ok: false, message: "That username is reserved." };
  }

  return { ok: true, username: s, usernameLower: lower };
}

/* -------- App Check (prod-enforced, dev-bypassable) --------
   - Set ENFORCE_APP_CHECK=1 in prod to require App Check.
   - For local/dev/simulator, set APPCHECK_DEV_BYPASS=1 to allow missing tokens.
*/
function enforceAppCheckOrSkip(context) {
  const enforce = process.env.ENFORCE_APP_CHECK === "1";
  if (!enforce) return;

  const hasCtx = !!context.app;
  const hasHeader =
    !!context?.rawRequest?.headers?.["x-firebase-appcheck"] ||
    !!context?.rawRequest?.headers?.["X-Firebase-AppCheck"];

  if (hasCtx || hasHeader) return;

  if (process.env.APPCHECK_DEV_BYPASS === "1") {
    console.warn("⚠️ App Check missing; bypassing due to APPCHECK_DEV_BYPASS=1.");
    return;
  }

  throw new functions.https.HttpsError(
    "failed-precondition",
    "App integrity check failed (App Check token missing)."
  );
}

/* ==================== Digital Wallet / Kraken Helpers ==================== */

function assertCryptoEnabled() {
  if (!ENABLE_CRYPTO_MODE) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Digital Wallet Mode is currently disabled."
    );
  }
}

function getKrakenKeys() {
  const key = process.env.KRAKEN_API_KEY || "";
  const secret = process.env.KRAKEN_API_SECRET || "";
  if (!key || !secret) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Kraken API keys are not configured."
    );
  }
  return { key, secret };
}

// Kraken HMAC signature
function createKrakenSignature(path, requestData, secretBase64) {
  const secret = Buffer.from(secretBase64, "base64");
  const nonce = requestData.nonce;
  const body = new URLSearchParams(requestData).toString();
  const hash = crypto.createHash("sha256");
  const hashDigest = hash.update(nonce + body).digest();
  const hmac = crypto.createHmac("sha512", secret);
  const hmacDigest = hmac.update(path + hashDigest).digest("base64");
  return hmacDigest;
}

// Kraken private POST
async function krakenPrivate(path, params) {
  const { key, secret } = getKrakenKeys();
  const nonce = Date.now().toString();
  const payload = { nonce, ...params };
  const signature = createKrakenSignature(path, payload, secret);
  const body = new URLSearchParams(payload).toString();

  const res = await fetch(KRAKEN_API_BASE + path, {
    method: "POST",
    headers: {
      "API-Key": key,
      "API-Sign": signature,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body,
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Kraken HTTP ${res.status}: ${text}`);
  }

  const json = await res.json();
  if (json.error && json.error.length) {
    throw new Error(`Kraken error: ${json.error.join(", ")}`);
  }
  return json.result;
}

// Kraken public GET
async function krakenPublic(path, params) {
  const url = new URL(KRAKEN_API_BASE + path);
  if (params) {
    Object.entries(params).forEach(([k, v]) =>
      url.searchParams.append(k, String(v))
    );
  }
  const res = await fetch(url.toString());
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Kraken public HTTP ${res.status}: ${text}`);
  }
  const json = await res.json();
  if (json.error && json.error.length) {
    throw new Error(`Kraken error: ${json.error.join(", ")}`);
  }
  return json.result;
}

// Get & cache ticker prices (BTC/USD, USDC/USD, ETH/USD) for internal use
async function fetchAndCacheKrakenPrices() {
  const pairs = ["USDCUSD", "XBTUSD", "ETHUSD"];
  const result = await krakenPublic("/0/public/Ticker", {
    pair: pairs.join(","),
  });

  const now = admin.firestore.Timestamp.now();

  const prices = {};

  const usdc = result.USDCUSD;
  if (usdc && usdc.c && usdc.c[0]) {
    prices.USDCUSD = Number(usdc.c[0]);
  }

  const btc = result.XBTUSD;
  if (btc && btc.c && btc.c[0]) {
    prices.BTCUSD = Number(btc.c[0]);
  }

  const eth = result.ETHUSD;
  if (eth && eth.c && eth.c[0]) {
    prices.ETHUSD = Number(eth.c[0]);
  }

  if (!prices.USDCUSD || !prices.BTCUSD || !prices.ETHUSD) {
    throw new Error("Missing ticker data from Kraken.");
  }

  const docData = {
    prices,
    updatedAt: now,
  };

  await db
    .collection("kraken_tickers")
    .doc("primary")
    .set(docData, { merge: true });

  return docData;
}

async function getCachedKrakenPrices(maxAgeSeconds = KRAKEN_TICKER_TTL_SECONDS) {
  const doc = await db.collection("kraken_tickers").doc("primary").get();
  const nowMs = Date.now();

  if (doc.exists) {
    const data = doc.data() || {};
    const ts =
      (data.updatedAt &&
        typeof data.updatedAt.toMillis === "function" &&
        data.updatedAt.toMillis()) ||
      0;
    if (data.prices && ts && nowMs - ts <= maxAgeSeconds * 1000) {
      return data;
    }
  }

  // Fetch fresh; if that fails but we have stale, use stale as fallback.
  try {
    return await fetchAndCacheKrakenPrices();
  } catch (err) {
    console.error("getCachedKrakenPrices: fetch failed:", err);
    if (doc && doc.exists && doc.data()?.prices) {
      return doc.data();
    }
    throw err;
  }
}

// Calculate USD cents from asset + amount using tickers
async function cryptoToUsdCents(asset, amount) {
  const cleanAsset = String(asset || "").toUpperCase();
  const v = Number(amount);
  if (!Number.isFinite(v) || v <= 0) return 0;

  const { prices } = await getCachedKrakenPrices();

  if (cleanAsset === "USDC") {
    // Soft peg
    return cents(v * (prices.USDCUSD || 1));
  }
  if (cleanAsset === "BTC") {
    return cents(v * (prices.BTCUSD || 0));
  }
  if (cleanAsset === "ETH") {
    return cents(v * (prices.ETHUSD || 0));
  }
  return 0;
}

// Ensure Firestore wallet shape supports Digital Wallet Mode
async function ensureUserWallet(uid) {
  const ref = db.collection("users").doc(uid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      tx.set(ref, {
        availableCents: 0,
        pendingWithdrawalCents: 0,
        stripeAccountId: null,
        totalEarnedCents: 0,
        totalWhispersClaimed: 0,
        totalReferralCents: 0,
        // Digital Wallet fields (Apple-safe naming)
        digitalWalletModeEnabled: false,
        echoBalanceUSD_cents: 0,
        echoBalanceCrypto: {
          USDC: 0,
          BTC: 0,
          ETH: 0,
        },
        defaultPayoutAsset: "USD",
        createdAt: admin.firestore.Timestamp.now(),
        updatedAt: admin.firestore.Timestamp.now(),
      });
    } else {
      const data = snap.data() || {};
      const updates = {};
      let needsUpdate = false;

      if (data.echoBalanceUSD_cents === undefined) {
        updates.echoBalanceUSD_cents = cents(data.availableCents || 0);
        needsUpdate = true;
      }
      if (!data.echoBalanceCrypto) {
        updates.echoBalanceCrypto = { USDC: 0, BTC: 0, ETH: 0 };
        needsUpdate = true;
      }
      if (data.digitalWalletModeEnabled === undefined) {
        updates.digitalWalletModeEnabled = false;
        needsUpdate = true;
      }
      if (!data.defaultPayoutAsset) {
        updates.defaultPayoutAsset = "USD";
        needsUpdate = true;
      }

      if (needsUpdate) {
        updates.updatedAt = admin.firestore.Timestamp.now();
        tx.update(ref, updates);
      }
    }
  });
  return ref;
}

/* ==================== Stripe Helpers (existing) ==================== */

async function creditWhisperFromStripe({
  whisperId,
  centsValue,
  addedBy,
  idemKey,
  currency = "USD",
}) {
  const whisperRef = db.collection("whispers").doc(whisperId);
  const idemRef = db.collection("transactions").doc(idemKey);

  return db.runTransaction(async (tx) => {
    const idemSnap = await tx.get(idemRef);
    if (idemSnap.exists) {
      return { success: true, message: "Already processed." };
    }

    const wSnap = await tx.get(whisperRef);
    if (!wSnap.exists) {
      return { success: false, message: "Whisper not found." };
    }
    const w = wSnap.data() || {};
    if (w.deleted) return { success: false, message: "Whisper deleted." };

    const armed = w.armed === undefined ? true : Boolean(w.armed);
    if (w.claimed === true || armed === false) {
      return { success: false, message: "Whisper is closed to funding." };
    }

    const now = admin.firestore.Timestamp.now();
    const before = cents(w.balanceCents);
    const incr = cents(centsValue);

    tx.set(idemRef, {
      type: "stripePayment",
      whisperId,
      cents: incr,
      addedBy: addedBy || null,
      currency: (w.currency || currency || "USD").toUpperCase(),
      ts: now,
      source: "stripe",
    });

    tx.update(whisperRef, {
      balanceCents: admin.firestore.FieldValue.increment(incr),
      currency: (w.currency || currency || "USD").toUpperCase(),
      updatedAt: now,
    });

    return {
      success: true,
      message: "Whisper funded.",
      before,
      after: before + incr,
    };
  });
}

/* ---------- Referral earnings helper (20% of net) ---------- */

async function creditReferralEarning({
  referrerUid,
  fromUid,
  centsValue,
  idemKey,
  source = "subscription",
}) {
  const amount = cents(centsValue);
  if (!referrerUid || !amount) {
    return { success: false, message: "No referrer or zero amount." };
  }

  const idemRef = db.collection("transactions").doc(idemKey);
  const userRef = db.collection("users").doc(referrerUid);

  return db.runTransaction(async (tx) => {
    const idemSnap = await tx.get(idemRef);
    if (idemSnap.exists) {
      return { success: true, message: "Already processed." };
    }

    const snap = await tx.get(userRef);
    const now = admin.firestore.Timestamp.now();

    if (!snap.exists) {
      tx.set(userRef, {
        availableCents: amount,
        pendingWithdrawalCents: 0,
        stripeAccountId: null,
        totalEarnedCents: amount,
        totalReferralCents: amount,
        totalWhispersClaimed: 0,
        // Mirror into Echo Balance
        echoBalanceUSD_cents: amount,
        digitalWalletModeEnabled: false,
        echoBalanceCrypto: {
          USDC: 0,
          BTC: 0,
          ETH: 0,
        },
        defaultPayoutAsset: "USD",
        createdAt: now,
        updatedAt: now,
      });
    } else {
      tx.update(userRef, {
        availableCents: admin.firestore.FieldValue.increment(amount),
        totalEarnedCents: admin.firestore.FieldValue.increment(amount),
        totalReferralCents: admin.firestore.FieldValue.increment(amount),
        echoBalanceUSD_cents:
          cents(snap.data().echoBalanceUSD_cents || snap.data().availableCents || 0) +
          amount,
        updatedAt: now,
      });
    }

    tx.set(idemRef, {
      type: "referralPayout",
      toUid: referrerUid,
      fromUid: fromUid || null,
      cents: amount,
      source,
      ts: now,
    });

    return { success: true, amount };
  });
}

/* ==================== Digital Wallet: Public Config ==================== */

/**
 * getDigitalWalletConfig
 * - Returns flags & labels for the client.
 * - Use terms like "Echo Balance" and "Digital Wallet Mode" in the UI (Apple-safe).
 */
exports.getDigitalWalletConfig = functions
  .region("us-central1")
  .runWith({
    secrets: ["ENABLE_CRYPTO_MODE", "KRAKEN_SANDBOX"],
  })
  .https.onCall(async (data, context) => {
    enforceAppCheckOrSkip(context);

    return {
      success: true,
      digitalWalletModeEnabled: ENABLE_CRYPTO_MODE,
      labelEchoBalance: "Echo Balance",
      labelDigitalWallet: "Digital Wallet Mode",
      supportedAssets: ENABLE_CRYPTO_MODE ? SUPPORTED_CRYPTO_ASSETS : [],
      krakenEnvironment:
        process.env.KRAKEN_SANDBOX === "1" ? "SANDBOX" : "PRODUCTION",
    };
  });

/* ==================== Crypto Mode: User Preferences ==================== */

/**
 * getCryptoPreferences
 * - Returns the stored crypto mode toggles for the signed-in user.
 */
exports.getCryptoPreferences = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    enforceAppCheckOrSkip(context);

    const uid = context.auth?.uid;
    if (!uid) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "Authentication required."
      );
    }

    const userRef = await ensureUserWallet(uid);
    const snap = await userRef.get();
    const u = snap.data() || {};

    return {
      success: true,
      enableCryptoMode: !!u.digitalWalletModeEnabled,
      notifyNearCryptoDrops: !!u.notifyNearCryptoDrops,
    };
  });

/**
 * setCryptoPreferences
 * - Saves crypto mode toggles on the user document.
 */
exports.setCryptoPreferences = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    enforceAppCheckOrSkip(context);

    const uid = context.auth?.uid;
    if (!uid) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "Authentication required."
      );
    }

    const enableCryptoMode = data?.enableCryptoMode === true;
    const notifyNearCryptoDrops = data?.notifyNearCryptoDrops === true;

    const userRef = await ensureUserWallet(uid);

    await userRef.set(
      {
        digitalWalletModeEnabled: enableCryptoMode,
        notifyNearCryptoDrops,
        updatedAt: admin.firestore.Timestamp.now(),
      },
      { merge: true }
    );

    return {
      success: true,
      enableCryptoMode,
      notifyNearCryptoDrops,
    };
  });



/**
 * getKrakenPrices
 * - Client-safe ticker snapshot (no keys).
 * - Uses cached values to avoid rate limits.
 */
exports.getKrakenPrices = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    enforceAppCheckOrSkip(context);
    assertCryptoEnabled();

    try {
      const { prices, updatedAt } = await getCachedKrakenPrices();
      return {
        success: true,
        prices,
        updatedAt: updatedAt ? updatedAt.toMillis() : null,
      };
    } catch (err) {
      console.error("getKrakenPrices error:", err);
      throw new functions.https.HttpsError(
        "internal",
        "Failed to load Digital Wallet rates."
      );
    }
  });

/* ==================== Digital Wallet: Crypto Funding for Whispers ==================== */

/**
 * createCryptoWhisperFundingIntent
 * - Creates a deposit address on the master Kraken account for a specific whisper & user.
 * - User sends USDC there; later synced via syncKrakenDeposits.
 * - All balances remain in Firestore; Kraken is the backend vault.
 */
exports.createCryptoWhisperFundingIntent = functions
  .region("us-central1")
  .runWith({ secrets: ["KRAKEN_API_KEY", "KRAKEN_API_SECRET"] })
  .https.onCall(async (data, context) => {
    enforceAppCheckOrSkip(context);
    assertCryptoEnabled();

    const uid = context.auth?.uid;
    if (!uid) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "Authentication required."
      );
    }

    const whisperId = String(data?.whisperId || "").trim();
    const asset = String(data?.asset || "USDC").toUpperCase();

    if (!whisperId) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Missing whisperId."
      );
    }
    if (!SUPPORTED_CRYPTO_ASSETS.includes(asset)) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Unsupported asset."
      );
    }
    if (asset === "USDC" && !KRAKEN_USDC_METHOD) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Kraken USDC deposit method is not configured."
      );
    }

    // Verify whisper is open for funding
    const whisperSnap = await db.collection("whispers").doc(whisperId).get();
    if (!whisperSnap.exists) {
      throw new functions.https.HttpsError("not-found", "Whisper not found.");
    }
    const w = whisperSnap.data() || {};
    if (w.deleted) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Whisper deleted."
      );
    }
    const armed = w.armed === undefined ? true : Boolean(w.armed);
    if (w.claimed === true || armed === false) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Whisper is closed to funding."
      );
    }

    // Request /private/DepositAddresses for USDC
    const method =
      asset === "USDC"
        ? KRAKEN_USDC_METHOD
        : KRAKEN_USDC_METHOD; // using same configured method unless you add more per asset

    const result = await krakenPrivate("/0/private/DepositAddresses", {
      asset: asset === "USDC" ? KRAKEN_USDC_ASSET : asset,
      method,
      new: "true",
    });

    if (!Array.isArray(result) || !result.length || !result[0].address) {
      throw new functions.https.HttpsError(
        "internal",
        "No deposit address returned from Kraken."
      );
    }

    const address = result[0].address;
    const now = admin.firestore.Timestamp.now();

    const intentRef = db.collection("cryptoFundingIntents").doc();
    const intent = {
      id: intentRef.id,
      uid,
      whisperId,
      asset,
      address,
      status: "PENDING",
      krakenMethod: method,
      createdAt: now,
      updatedAt: now,
      environment:
        process.env.KRAKEN_SANDBOX === "1" ? "SANDBOX" : "PRODUCTION",
    };
    await intentRef.set(intent);

    return {
      success: true,
      intentId: intentRef.id,
      asset,
      address,
      note:
        "Send only the specified asset to this address. Funds appear in the whisper once confirmed.",
    };
  });

/**
 * syncKrakenDeposits
 * - Admin/cron callable: sync recent Kraken deposits to open funding intents.
 * - Matches by deposit address & asset; credits whisper + logs transaction.
 * - This is idempotent via txid-based transaction docs.
 */
exports.syncKrakenDeposits = functions
  .region("us-central1")
  .runWith({ secrets: ["KRAKEN_API_KEY", "KRAKEN_API_SECRET"] })
  .https.onCall(async (data, context) => {
    enforceAppCheckOrSkip(context);
    assertCryptoEnabled();

    // Basic admin gate: replace with proper auth check (e.g. custom claims)
    const uid = context.auth?.uid || "";
    const isAdmin =
      uid &&
      (process.env.ADMIN_UIDS || "")
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean)
        .includes(uid);
    if (!isAdmin) {
      throw new functions.https.HttpsError(
        "permission-denied",
        "Admin only."
      );
    }

    // Load pending intents
    const intentsSnap = await db
      .collection("cryptoFundingIntents")
      .where("status", "==", "PENDING")
      .limit(100)
      .get();

    if (intentsSnap.empty) {
      return { success: true, processed: 0 };
    }

    const intents = intentsSnap.docs.map((d) => ({ id: d.id, ...d.data() }));

    // Fetch recent deposits for all assets we care about
    const assetsToCheck = [...new Set(intents.map((i) => i.asset))];

    const depositsByAsset = {};

    for (const asset of assetsToCheck) {
      try {
        const result = await krakenPrivate("/0/private/DepositStatus", {
          asset:
            asset === "USDC"
              ? KRAKEN_USDC_ASSET
              : asset === "BTC"
              ? KRAKEN_BTC_ASSET
              : asset === "ETH"
              ? KRAKEN_ETH_ASSET
              : asset,
          // You can add limit/cursor here if needed.
        });
        if (Array.isArray(result)) {
          depositsByAsset[asset] = result;
        }
      } catch (err) {
        console.error("DepositStatus error for asset", asset, err);
      }
    }

    let applied = 0;

    for (const intent of intents) {
      const list = depositsByAsset[intent.asset] || [];
      if (!list.length) continue;

      const match = list.find(
        (d) =>
          d.address === intent.address &&
          String(d.status || "").toLowerCase() === "success"
      );
      if (!match) continue;

      const txid = match.txid || match.refid || `${intent.id}:${match.time}`;
      const amountStr = match.amount || match.volume || match.vol || "0";
      const amount = Number(amountStr);
      if (!Number.isFinite(amount) || amount <= 0) continue;

      const idemId = `krakenDeposit:${txid}`;

      // Convert crypto -> USD cents for internal ledger
      const usdCents = await cryptoToUsdCents(intent.asset, amount);
      if (!usdCents) continue;

      const whisperRef = db.collection("whispers").doc(intent.whisperId);
      const idemRef = db.collection("transactions").doc(idemId);
      const intentRef = db.collection("cryptoFundingIntents").doc(intent.id);

      try {
        await db.runTransaction(async (tx) => {
          const idemSnap = await tx.get(idemRef);
          if (idemSnap.exists) {
            return;
          }

          const wSnap = await tx.get(whisperRef);
          if (!wSnap.exists) return;
          const w = wSnap.data() || {};
          if (w.deleted) return;
          const armed = w.armed === undefined ? true : Boolean(w.armed);
          if (w.claimed === true || armed === false) {
            return;
          }

          const now = admin.firestore.Timestamp.now();

          tx.update(whisperRef, {
  	  balanceCents: admin.firestore.FieldValue.increment(usdCents),
          currency: "USD",
          hasCryptoBacking: true,              // 🔐 mark as crypto-backed
          updatedAt: now,
          });


          tx.set(idemRef, {
            type: "cryptoFundWhisper",
            whisperId: intent.whisperId,
            fromUid: intent.uid || null,
            asset: intent.asset,
            assetAmount: amount,
            usdCents,
            address: intent.address,
            txid,
            source: "kraken",
            ts: now,
          });

          tx.update(intentRef, {
            status: "COMPLETED",
            completedAt: now,
            updatedAt: now,
            txid,
            creditedUsdCents: usdCents,
          });
        });

        applied += 1;
      } catch (err) {
        console.error(
          "Failed to apply crypto deposit for intent",
          intent.id,
          err
        );
      }
    }

    return { success: true, processed: applied };
  });

/* ==================== Digital Wallet: Withdraw via Kraken ==================== */

/**
 * requestCryptoWithdrawal
 * - Moves USD balance -> crypto withdrawal via Kraken.
 * - Uses Kraken withdrawal "key" configured in your Kraken account.
 * - All math is in USD-equivalent to keep referrals/leaderboard consistent.
 */
exports.requestCryptoWithdrawal = functions
  .region("us-central1")
  .runWith({ secrets: ["KRAKEN_API_KEY", "KRAKEN_API_SECRET"] })
  .https.onCall(async (data, context) => {
    enforceAppCheckOrSkip(context);
    assertCryptoEnabled();

    const uid = context.auth?.uid;
    if (!uid) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "Authentication required."
      );
    }

    const asset = String(data?.asset || "USDC").toUpperCase();
    const amount = Number(data?.amount || 0); // asset units
    const withdrawalKey = String(data?.withdrawalKey || "").trim();
    const clientId = String(data?.idempotencyKey || "").trim();

    if (!SUPPORTED_CRYPTO_ASSETS.includes(asset)) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Unsupported asset."
      );
    }
    if (!Number.isFinite(amount) || amount <= 0) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Invalid amount."
      );
    }
    if (amount < (MIN_WITHDRAW[asset] || 0)) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        `Minimum withdrawal for ${asset} is ${MIN_WITHDRAW[asset]}.`
      );
    }
    if (!withdrawalKey) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Missing withdrawal key."
      );
    }

    const idemId = clientId
      ? `cryptoWithdraw:${uid}:${clientId}`
      : `cryptoWithdraw:${uid}:${asset}:${amount}:${Date.now()}`;
    const idemRef = db.collection("transactions").doc(idemId);
    const userRef = db.collection("users").doc(uid);

    const usdCentsNeeded = await cryptoToUsdCents(asset, amount);
    if (!usdCentsNeeded) {
      throw new functions.https.HttpsError(
        "internal",
        "Unable to price withdrawal."
      );
    }

    let proceed = false;

    await db.runTransaction(async (tx) => {
      const idemSnap = await tx.get(idemRef);
      if (idemSnap.exists) {
        proceed = false;
        return;
      }

      const userSnap = await tx.get(userRef);
      if (!userSnap.exists) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Wallet not found."
        );
      }
      const u = userSnap.data() || {};
      const avail = cents(
        u.echoBalanceUSD_cents !== undefined
          ? u.echoBalanceUSD_cents
          : u.availableCents || 0
      );

      if (avail < usdCentsNeeded) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Insufficient Echo Balance."
        );
      }

      const now = admin.firestore.Timestamp.now();

      tx.update(userRef, {
        echoBalanceUSD_cents: avail - usdCentsNeeded,
        pendingWithdrawalCents:
          cents(u.pendingWithdrawalCents) + usdCentsNeeded,
        updatedAt: now,
      });

      tx.set(idemRef, {
        type: "cryptoWithdrawalRequest",
        uid,
        asset,
        assetAmount: amount,
        usdCents: usdCentsNeeded,
        withdrawalKey,
        status: "PENDING",
        ts: now,
        source: "kraken",
      });

      proceed = true;
    });

    if (!proceed) {
      const existing = await idemRef.get();
      if (existing.exists) {
        return { success: true, status: existing.data().status || "PENDING" };
      }
      throw new functions.https.HttpsError(
        "internal",
        "Withdrawal already processed or could not start."
      );
    }

    // Call Kraken Withdraw
    let krakenRefId = null;
    try {
      const result = await krakenPrivate("/0/private/Withdraw", {
        asset:
          asset === "USDC"
            ? KRAKEN_USDC_ASSET
            : asset === "BTC"
            ? KRAKEN_BTC_ASSET
            : asset === "ETH"
            ? KRAKEN_ETH_ASSET
            : asset,
        key: withdrawalKey,
        amount: String(amount),
      });

      krakenRefId = result.refid || null;

      await idemRef.update({
        status: "SUBMITTED",
        krakenRefId,
        updatedAt: admin.firestore.Timestamp.now(),
      });

      // Mark pendingWithdrawalCents as completed
      await db.runTransaction(async (tx) => {
        const userSnap = await tx.get(userRef);
        if (!userSnap.exists) return;
        const u = userSnap.data() || {};
        const pending = cents(u.pendingWithdrawalCents);
        const newPending = Math.max(0, pending - usdCentsNeeded);
        tx.update(userRef, {
          pendingWithdrawalCents: newPending,
          updatedAt: admin.firestore.Timestamp.now(),
        });
      });

      return {
        success: true,
        status: "SUBMITTED",
        krakenRefId,
      };
    } catch (err) {
      console.error("Kraken withdraw failed:", err);

      // Roll back Echo Balance on failure
      await db.runTransaction(async (tx) => {
        const userSnap = await tx.get(userRef);
        const idemSnap = await tx.get(idemRef);
        if (!userSnap.exists || !idemSnap.exists) return;
        const u = userSnap.data() || {};
        const t = idemSnap.data() || {};
        if (t.status !== "PENDING") return;

        const now = admin.firestore.Timestamp.now();
        tx.update(userRef, {
          echoBalanceUSD_cents:
            cents(u.echoBalanceUSD_cents) + usdCentsNeeded,
          pendingWithdrawalCents: Math.max(
            0,
            cents(u.pendingWithdrawalCents) - usdCentsNeeded
          ),
          updatedAt: now,
        });
        tx.update(idemRef, {
          status: "FAILED",
          errorMessage: String(err.message || "Kraken withdraw failed"),
          updatedAt: now,
        });
      });

      throw new functions.https.HttpsError(
        "internal",
        "Crypto withdrawal failed. No funds were taken."
      );
    }
  });

/* ==================== Digital Wallet: USD -> Crypto Mode (Internal) ==================== */

/**
 * convertUsdToCryptoMode
 * - Optional: express user's Echo Balance in crypto units (internal only).
 * - Does NOT move real funds on Kraken; it's a ledger representation.
 * - Keeps totalEarnedCents and leaderboard logic USD-based.
 */
exports.convertUsdToCryptoMode = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    enforceAppCheckOrSkip(context);
    assertCryptoEnabled();

    const uid = context.auth?.uid;
    if (!uid) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "Authentication required."
      );
    }

    const targetAsset = String(data?.asset || "USDC").toUpperCase();
    const percent = Number(data?.percent || 100); // how much of USD balance to represent in this asset

    if (!SUPPORTED_CRYPTO_ASSETS.includes(targetAsset)) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Unsupported asset."
      );
    }
    if (!Number.isFinite(percent) || percent <= 0 || percent > 100) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Percent must be between 1 and 100."
      );
    }

    const userRef = await ensureUserWallet(uid);
    const { prices } = await getCachedKrakenPrices();

    let resultSnapshot = null;

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(userRef);
      if (!snap.exists) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "Wallet not found."
        );
      }

      const u = snap.data() || {};
      const usdCents = cents(
        u.echoBalanceUSD_cents !== undefined
          ? u.echoBalanceUSD_cents
          : u.availableCents || 0
      );
      if (!usdCents) {
        throw new functions.https.HttpsError(
          "failed-precondition",
          "No Echo Balance to convert."
        );
      }

      const useCents = Math.floor((usdCents * percent) / 100);

      let unitPrice = 1;
      if (targetAsset === "USDC") {
        unitPrice = prices.USDCUSD || 1;
      } else if (targetAsset === "BTC") {
        unitPrice = prices.BTCUSD || 0;
      } else if (targetAsset === "ETH") {
        unitPrice = prices.ETHUSD || 0;
      }
      if (!unitPrice) {
        throw new functions.https.HttpsError(
          "internal",
          "Pricing not available."
        );
      }

      const assetAmount = useCents / 100 / unitPrice;

      const echoCrypto = u.echoBalanceCrypto || {
        USDC: 0,
        BTC: 0,
        ETH: 0,
      };

      echoCrypto[targetAsset] =
        Number(echoCrypto[targetAsset] || 0) + assetAmount;

      const now = admin.firestore.Timestamp.now();

      tx.update(userRef, {
        echoBalanceUSD_cents: usdCents - useCents,
        echoBalanceCrypto: echoCrypto,
        digitalWalletModeEnabled: true,
        defaultPayoutAsset: targetAsset,
        updatedAt: now,
      });

      const txRef = db.collection("transactions").doc();
      tx.set(txRef, {
        type: "convertUsdToCrypto",
        uid,
        fromUsdCents: useCents,
        toAsset: targetAsset,
        toAssetAmount: assetAmount,
        prices,
        ts: now,
      });

      resultSnapshot = {
        echoBalanceUSD_cents: usdCents - useCents,
        echoBalanceCrypto: echoCrypto,
        defaultPayoutAsset: targetAsset,
      };
    });

    return {
      success: true,
      ...resultSnapshot,
    };
  });

/* ==================== Whisper created trigger ==================== */

exports.onWhisperCreated = functions
  .region("us-central1")
  .firestore.document("whispers/{id}")
  .onCreate(async (snap) => {
    try {
      const data = snap.data() || {};
      const ownerId = data.ownerId;
      if (!ownerId || typeof ownerId !== "string") return null;
      if (ownerId.startsWith("device-")) return null;

      const userRef = db.collection("users").doc(ownerId);

      await db.runTransaction(async (tx) => {
        const uSnap = await tx.get(userRef);
        if (!uSnap.exists) return;

        const u = uSnap.data() || {};
        const whispersUploaded = Number(u.whispersUploaded || 0) + 1;

        const updates = {
          whispersUploaded,
          updatedAt: admin.firestore.Timestamp.now(),
        };

        if (!u.referralQualified && u.referrerUid && whispersUploaded >= 100) {
          updates.referralQualified = true;
          updates.referralQualifiedAt = admin.firestore.Timestamp.now();
        }

        tx.update(userRef, updates);
      });

      return null;
    } catch (err) {
      console.error("onWhisperCreated error:", err);
      return null;
    }
  });

/* ==================== Claim Whisper (legacy + V2) ==================== */

exports.claimWhisper = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    try {
      enforceAppCheckOrSkip(context);

      const uid = context.auth?.uid;
      if (!uid) return { success: false, message: "Authentication required." };

      const whisperId = String(data?.whisperId || "");
      const lat = toNumber(data?.lat);
      const lon = toNumber(data?.lon);
      const providedHash = (data?.passwordHashHex || "")
        .toLowerCase()
        .trim();

      if (!whisperId || !isValidLatLon(lat, lon)) {
        return { success: false, message: "Invalid parameters." };
      }

      const whisperRef = db.collection("whispers").doc(whisperId);
      const userRef = await ensureUserWallet(uid);

      const result = await db.runTransaction(async (tx) => {
        const snap = await tx.get(whisperRef);
        if (!snap.exists)
          return { success: false, message: "Whisper not found." };

        const w = snap.data() || {};
        if (w.deleted)
          return { success: false, message: "Whisper deleted." };
        if (w.ownerId === uid) {
          return {
            success: false,
            message: "Owners cannot claim their own whisper.",
          };
        }

        const now = admin.firestore.Timestamp.now();
        const unlockAt = w.unlockAt || now;
        if (unlockAt.toMillis() > now.toMillis()) {
          return { success: false, message: "Not unlocked yet." };
        }

        const radius = Number(w.radiusMeters || 0);
        if (!radius || isNaN(radius)) {
          return { success: false, message: "Invalid radius." };
        }

        const dist = haversineMeters(
          lat,
          lon,
          Number(w.latitude),
          Number(w.longitude)
        );
        if (dist > radius + 5) {
          return {
            success: false,
            message: `Too far (${Math.round(dist)}m).`,
          };
        }

        const storedHash = (w.passwordHash || "").toLowerCase().trim();
        if (
          storedHash &&
          storedHash.length > 0 &&
          providedHash !== storedHash
        ) {
          return { success: false, message: "Incorrect password." };
        }

        if (w.claimed)
          return { success: false, message: "Already claimed." };

        const pot = cents(w.balanceCents);
        const currency = (w.currency || "USD").toUpperCase();

        const walletSnap = await tx.get(userRef);
        if (!walletSnap.exists) {
          tx.set(userRef, {
            availableCents: 0,
            pendingWithdrawalCents: 0,
            stripeAccountId: null,
            totalEarnedCents: 0,
            totalWhispersClaimed: 0,
            totalReferralCents: 0,
            echoBalanceUSD_cents: 0,
            echoBalanceCrypto: { USDC: 0, BTC: 0, ETH: 0 },
            digitalWalletModeEnabled: false,
            defaultPayoutAsset: "USD",
            createdAt: now,
            updatedAt: now,
          });
        }

        if (pot > 0) {
          tx.set(
            userRef,
            {
              availableCents:
                admin.firestore.FieldValue.increment(pot),
              totalEarnedCents:
                admin.firestore.FieldValue.increment(pot),
              totalWhispersClaimed:
                admin.firestore.FieldValue.increment(1),
              echoBalanceUSD_cents:
                admin.firestore.FieldValue.increment(pot),
              updatedAt: now,
            },
            { merge: true }
          );
        } else {
          tx.set(
            userRef,
            {
              totalWhispersClaimed:
                admin.firestore.FieldValue.increment(1),
              updatedAt: now,
            },
            { merge: true }
          );
        }

        tx.update(whisperRef, {
          claimed: true,
          claimedBy: uid,
          claimedAt: now,
          claimCount: Number(w.claimCount || 0) + 1,
          balanceCents: 0,
          armed: false,
          schemaVersion: 2,
          updatedAt: now,
        });

        tx.set(db.collection("transactions").doc(), {
          type: "claimP2P",
          whisperId,
          claimant: uid,
          fromOwner: w.ownerId || null,
          distanceMeters: Math.round(dist),
          movedCents: pot,
          currency,
          ts: now,
        });

        return {
          success: true,
          message:
            pot > 0
              ? `Claimed and received $${(pot / 100).toFixed(
                  2
                )} in your Echo Balance.`
              : "Claimed.",
          receivedCents: pot,
        };
      });

      return result;
    } catch (err) {
      console.error("claimWhisper error:", err);
      return { success: false, message: "Server error." };
    }
  });

exports.claimWhisperV2 = functions
  .region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
  .https.onCall(async (data, context) => {
    try {
      enforceAppCheckOrSkip(context);

      const uid = context.auth?.uid;
      if (!uid) return { success: false, message: "Authentication required." };

      const whisperId = String(data?.whisperId || "");
      const lat = toNumber(data?.lat);
      const lon = toNumber(data?.lon);
      const providedHash = (data?.passwordHashHex || "")
        .toLowerCase()
        .trim();
      const requirePayoutReady = Boolean(data?.requirePayoutReady);

      if (!whisperId || !isValidLatLon(lat, lon)) {
        return { success: false, message: "Invalid parameters." };
      }

      if (requirePayoutReady) {
        const stripe = Stripe(process.env.STRIPE_SECRET_KEY);
        const userDoc =
          (
            await db.collection("users").doc(uid).get()
          ).data() || {};
        const acctId = userDoc.stripeAccountId;
        if (!acctId) {
          return {
            success: false,
            code: "PAYOUTS_NOT_READY",
            message:
              "Stripe account not set up. Finish setup to claim funds.",
          };
        }
        const acct = await stripe.accounts.retrieve(acctId);
        if (!acct.payouts_enabled) {
          return {
            success: false,
            code: "PAYOUTS_NOT_READY",
            message:
              "Payouts not enabled. Finish Stripe setup to claim funds.",
          };
        }
      }

      const whisperRef = db.collection("whispers").doc(whisperId);
      const userRef = await ensureUserWallet(uid);

      const result = await db.runTransaction(async (tx) => {
        const snap = await tx.get(whisperRef);
        if (!snap.exists)
          return { success: false, message: "Whisper not found." };
        const w = snap.data() || {};

        if (w.deleted)
          return { success: false, message: "Whisper deleted." };
        if (w.ownerId === uid) {
          return {
            success: false,
            message: "Owners cannot claim their own whisper.",
          };
        }

        const now = admin.firestore.Timestamp.now();
        const unlockAt = w.unlockAt || now;
        if (unlockAt.toMillis() > now.toMillis()) {
          return { success: false, message: "Not unlocked yet." };
        }

        const radius = Number(w.radiusMeters || 0);
        if (!radius || isNaN(radius)) {
          return { success: false, message: "Invalid radius." };
        }

        const dist = haversineMeters(
          lat,
          lon,
          Number(w.latitude),
          Number(w.longitude)
        );
        if (dist > radius + 5) {
          return {
            success: false,
            message: `Too far (${Math.round(dist)}m).`,
          };
        }

        const storedHash = (w.passwordHash || "").toLowerCase().trim();
        if (
          storedHash &&
          storedHash.length > 0 &&
          providedHash !== storedHash
        ) {
          return { success: false, message: "Incorrect password." };
        }

        if (w.claimed)
          return { success: false, message: "Already claimed." };

        const pot = cents(w.balanceCents);
        const currency = (w.currency || "USD").toUpperCase();

        const walletSnap = await tx.get(userRef);
        if (!walletSnap.exists) {
          tx.set(userRef, {
            availableCents: 0,
            pendingWithdrawalCents: 0,
            stripeAccountId: null,
            totalEarnedCents: 0,
            totalWhispersClaimed: 0,
            totalReferralCents: 0,
            echoBalanceUSD_cents: 0,
            echoBalanceCrypto: { USDC: 0, BTC: 0, ETH: 0 },
            digitalWalletModeEnabled: false,
            defaultPayoutAsset: "USD",
            createdAt: now,
            updatedAt: now,
          });
        }

        if (pot > 0) {
          tx.set(
            userRef,
            {
              availableCents:
                admin.firestore.FieldValue.increment(pot),
              totalEarnedCents:
                admin.firestore.FieldValue.increment(pot),
              totalWhispersClaimed:
                admin.firestore.FieldValue.increment(1),
              echoBalanceUSD_cents:
                admin.firestore.FieldValue.increment(pot),
              updatedAt: now,
            },
            { merge: true }
          );
        } else {
          tx.set(
            userRef,
            {
              totalWhispersClaimed:
                admin.firestore.FieldValue.increment(1),
              updatedAt: now,
            },
            { merge: true }
          );
        }

        tx.update(whisperRef, {
          claimed: true,
          claimedBy: uid,
          claimedAt: now,
          claimCount: Number(w.claimCount || 0) + 1,
          balanceCents: 0,
          armed: false,
          schemaVersion: 2,
          updatedAt: now,
        });

        tx.set(db.collection("transactions").doc(), {
          type: "claimP2P_v2",
          whisperId,
          claimant: uid,
          fromOwner: w.ownerId || null,
          distanceMeters: Math.round(dist),
          movedCents: pot,
          currency,
          ts: now,
        });

        return {
          success: true,
          message:
            pot > 0
              ? `Claimed and received $${(pot / 100).toFixed(
                  2
                )} in your Echo Balance.`
              : "Claimed.",
          receivedCents: pot,
        };
      });

      return result;
    } catch (err) {
      console.error("claimWhisperV2 error:", err);
      return { success: false, message: "Server error." };
    }
  });

/* ==================== Whisper funding helpers (Stripe) ==================== */

exports.addFundsToWhisper = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    try {
      enforceAppCheckOrSkip(context);

      const uid = context.auth?.uid;
      if (!uid)
        return { success: false, message: "Authentication required." };

      const whisperId = String(data?.whisperId || "");
      const idempotencyKey = String(data?.idempotencyKey || "");
      const amount = Number(data?.cents || 0);

      if (!whisperId || !idempotencyKey) {
        return { success: false, message: "Missing parameters." };
      }
      if (!isInt(amount) || amount <= 0) {
        return { success: false, message: "Invalid amount." };
      }
      if (amount < 100 || amount > 500000) {
        return { success: false, message: "Amount out of range." };
      }

      const res = await creditWhisperFromStripe({
        whisperId,
        centsValue: amount,
        addedBy: uid,
        idemKey: `manual:${idempotencyKey}`,
      });
      return res;
    } catch (err) {
      console.error("addFundsToWhisper error:", err);
      return { success: false, message: "Server error." };
    }
  });

exports.createCheckoutSession = functions
  .region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
  .https.onCall(async (data, context) => {
    try {
      enforceAppCheckOrSkip(context);

      const uid = context.auth?.uid;
      if (!uid)
        return { success: false, message: "Authentication required." };

      const stripe = Stripe(process.env.STRIPE_SECRET_KEY);

      const whisperId = String(data?.whisperId || "");
      const centsValue = Number(data?.cents || 0);
      const successUrl = String(data?.successUrl || "");
      const cancelUrl = String(data?.cancelUrl || "");

      if (!whisperId || !successUrl || !cancelUrl) {
        return { success: false, message: "Missing parameters." };
      }
      if (
        !Number.isInteger(centsValue) ||
        centsValue < 100 ||
        centsValue > 500000
      ) {
        return {
          success: false,
          message: "Amount out of range (100..500000).",
        };
      }

      const wSnap = await db.collection("whispers").doc(whisperId).get();
      if (!wSnap.exists)
        return { success: false, message: "Whisper not found." };
      const w = wSnap.data() || {};
      if (w.deleted)
        return { success: false, message: "Whisper deleted." };

      const armed = w.armed === undefined ? true : Boolean(w.armed);
      if (w.claimed === true || armed === false) {
        return {
          success: false,
          message: "Whisper is closed to funding.",
        };
      }

      const currency = (w.currency || "usd").toLowerCase();

      const session = await stripe.checkout.sessions.create({
        mode: "payment",
        payment_method_types: ["card"],
        line_items: [
          {
            price_data: {
              currency,
              unit_amount: centsValue,
              product_data: {
                name: w.name
                  ? `Top up: ${w.name}`
                  : "Whisper top-up",
              },
            },
            quantity: 1,
          },
        ],
        metadata: {
          whisperId,
          cents: String(centsValue),
          addedBy: uid,
        },
        success_url: successUrl,
        cancel_url: cancelUrl,
      });

      return { success: true, url: session.url };
    } catch (err) {
      console.error("createCheckoutSession error:", err);
      return { success: false, message: "Server error." };
    }
  });

exports.handleStripeWebhook = functions
  .region("us-central1")
  .runWith({
    secrets: ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"],
  })
  .https.onRequest(async (req, res) => {
    if (req.method !== "POST")
      return res.status(405).send("Method Not Allowed");

    const stripe = Stripe(process.env.STRIPE_SECRET_KEY);
    const STRIPE_WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET;
    const sig = req.headers["stripe-signature"];

    let event;
    try {
      event = stripe.webhooks.constructEvent(
        req.rawBody,
        sig,
        STRIPE_WEBHOOK_SECRET
      );
    } catch (err) {
      console.error(
        "❌ Webhook signature verification failed:",
        err.message
      );
      return res.status(400).send(`Webhook Error: ${err.message}`);
    }

    try {
      if (event.type === "checkout.session.completed") {
        const session = event.data.object;

        const whisperId = session.metadata?.whisperId;
        const centsStr = session.metadata?.cents;
        const addedBy = session.metadata?.addedBy || null;
        const amt = Number(centsStr || 0);

        if (!whisperId || !Number.isInteger(amt) || amt <= 0) {
          console.warn(
            "⚠️ Invalid metadata in webhook:",
            session.metadata
          );
        } else {
          const wRef = db.collection("whispers").doc(whisperId);
          const wSnap = await wRef.get();

          const refundDocId = session.payment_intent
            ? `refund:${session.payment_intent}`
            : null;
          const refundRef = refundDocId
            ? db.collection("transactions").doc(refundDocId)
            : null;

          const refundIfNeeded = async (reasonNote) => {
            try {
              if (!session.payment_intent) return;
              if (refundRef) {
                const existing = await refundRef.get();
                if (existing.exists) return;
              }
              await stripe.refunds.create({
                payment_intent: session.payment_intent,
                reason: "requested_by_customer",
              });
              const doc = {
                type: "refundLateFunding",
                whisperId,
                cents: amt,
                addedBy,
                paymentIntentId: session.payment_intent,
                ts: admin.firestore.Timestamp.now(),
                note: reasonNote,
              };
              if (refundRef) {
                await refundRef.set(doc);
              } else {
                await db.collection("transactions").add(doc);
              }
            } catch (e) {
              console.error("Refund attempt failed:", e);
            }
          };

          if (!wSnap.exists) {
            await refundIfNeeded("Whisper not found.");
          } else {
            const w = wSnap.data() || {};
            const armed = w.armed === undefined ? true : Boolean(w.armed);
            if (w.deleted) {
              await refundIfNeeded("Whisper deleted.");
            } else if (w.claimed === true || armed === false) {
              await refundIfNeeded(
                "Whisper already claimed or disarmed."
              );
            } else {
              const idemKey = `stripe:${
                session.payment_intent || session.id
              }`;
              const currency = (session.currency || "usd").toUpperCase();
              const result = await creditWhisperFromStripe({
                whisperId,
                centsValue: amt,
                addedBy,
                idemKey,
                currency,
              });
              if (!result.success)
                console.error(
                  "Failed to credit whisper:",
                  result
                );
            }
          }
        }
      }

      return res.status(200).send({ received: true });
    } catch (err) {
      console.error("❌ Webhook handler error:", err);
      return res.status(500).send("Internal error");
    }
  });

/* ==================== Stripe Connect / Cash Out (Fiat) ==================== */

exports.connectCreateOrGetAccount = functions
  .region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
  .https.onCall(async (data, context) => {
    try {
      enforceAppCheckOrSkip(context);

      const uid = context.auth?.uid;
      if (!uid)
        return { success: false, message: "Authentication required." };

      const stripe = Stripe(process.env.STRIPE_SECRET_KEY);
      const userRef = await ensureUserWallet(uid);

      const snap = await userRef.get();
      const doc = snap.data() || {};
      let accountId = doc.stripeAccountId || null;

      if (!accountId) {
        const acct = await stripe.accounts.create({
        type: "express",
        business_type: "individual",

        individual: {},

        business_profile: {
        product_description: "Peer-to-peer in-app rewards and cash outs",
        url: "https://hardcoreamature.com",
        mcc: "7399",
        },

        capabilities: {
        card_payments: { requested: true },
        transfers: { requested: true },
        },
      });
        await userRef.update({
          stripeAccountId: acct.id,
          updatedAt: admin.firestore.Timestamp.now(),
        });
        accountId = acct.id;
      }

      return { success: true, accountId };
    } catch (err) {
      console.error("connectCreateOrGetAccount error:", err);
      return { success: false, message: "Server error." };
    }
  });

exports.connectOnboardingLink = functions
  .region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
  .https.onCall(async (data, context) => {
    try {
      enforceAppCheckOrSkip(context);

      const uid = context.auth?.uid;
      if (!uid)
        return { success: false, message: "Authentication required." };

      const stripe = Stripe(process.env.STRIPE_SECRET_KEY);
      const refreshUrl = String(data?.refreshUrl || "");
      const returnUrl = String(data?.returnUrl || "");
      const mode =
        String(data?.mode || "onboarding").toLowerCase() === "update"
          ? "account_update"
          : "account_onboarding";

      if (!refreshUrl || !returnUrl) {
        return {
          success: false,
          message: "Missing refresh/return URL.",
        };
      }

      const userDoc =
        (
          await db.collection("users").doc(uid).get()
        ).data() || {};
      const accountId = userDoc.stripeAccountId;
      if (!accountId) {
        return {
          success: false,
          message:
            "No account. Call connectCreateOrGetAccount first.",
        };
      }

      const link = await stripe.accountLinks.create({
        account: accountId,
        refresh_url: refreshUrl,
        return_url: returnUrl,
        type: mode,
      });

      return { success: true, url: link.url };
    } catch (err) {
      console.error("connectOnboardingLink error:", err);
      return { success: false, message: "Server error." };
    }
  });

exports.connectAccountStatus = functions
  .region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
  .https.onCall(async (data, context) => {
    try {
      enforceAppCheckOrSkip(context);

      const uid = context.auth?.uid;
      if (!uid)
        return { success: false, message: "Authentication required." };

      const stripe = Stripe(process.env.STRIPE_SECRET_KEY);
      const userDoc =
        (
          await db.collection("users").doc(uid).get()
        ).data() || {};
      const accountId = userDoc.stripeAccountId;
      if (!accountId) {
        return { success: false, message: "No account yet." };
      }

      const acct = await stripe.accounts.retrieve(accountId);
      return {
        success: true,
        accountId,
        chargesEnabled: acct.charges_enabled,
        payoutsEnabled: acct.payouts_enabled,
        requirements: acct.requirements,
      };
    } catch (err) {
      console.error("connectAccountStatus error:", err);
      return { success: false, message: "Server error." };
    }
  });

exports.cashOutAvailable = functions
  .region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
  .https.onCall(async (data, context) => {
    try {
      enforceAppCheckOrSkip(context);

      const uid = context.auth?.uid;
      if (!uid)
        return { success: false, message: "Authentication required." };

      const stripe = Stripe(process.env.STRIPE_SECRET_KEY);
      const userRef = db.collection("users").doc(uid);

      const userSnap = await userRef.get();
      if (!userSnap.exists) {
        return { success: false, message: "Wallet not found." };
      }

      const u = userSnap.data() || {};
      const accountId = u.stripeAccountId;
      if (!accountId) {
        return {
          success: false,
          message: "No Stripe account. Onboard first.",
        };
      }

      const acct = await stripe.accounts.retrieve(accountId);
      if (!acct.payouts_enabled) {
        return {
          success: false,
          message: "Payouts not enabled. Finish Stripe setup.",
        };
      }

      const requested = data?.cents
        ? cents(data.cents)
        : cents(u.availableCents);
      if (requested <= 0) {
        return { success: false, message: "Nothing to cash out." };
      }

      await db.runTransaction(async (tx) => {
        const snap = await tx.get(userRef);
        const cur = snap.data() || {};
        const avail = cents(cur.availableCents);

        if (avail <= 0) {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "Nothing to cash out."
          );
        }
        if (requested > avail) {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "Amount exceeds available balance."
          );
        }

        tx.update(userRef, {
          availableCents: avail - requested,
          pendingWithdrawalCents:
            cents(cur.pendingWithdrawalCents) + requested,
          updatedAt: admin.firestore.Timestamp.now(),
        });
      });

      const transfer = await stripe.transfers.create({
        amount: requested,
        currency: "usd",
        destination: accountId,
        metadata: { userId: uid, reason: "cashOut" },
      });

      await userRef.update({
        pendingWithdrawalCents:
          admin.firestore.FieldValue.increment(-requested),
        updatedAt: admin.firestore.Timestamp.now(),
        lastPayoutTransferId: transfer.id,
      });

      return {
        success: true,
        transferId: transfer.id,
        amountCents: requested,
      };
    } catch (err) {
      console.error("cashOutAvailable error:", err);
      const msg =
        err instanceof functions.https.HttpsError
          ? err.message
          : err?.message || "Server error.";
      return { success: false, message: msg };
    }
  });

/* ==================== claimAutoRelease (drops) ==================== */

exports.claimAutoRelease = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    try {
      enforceAppCheckOrSkip(context);

      const uid = context.auth?.uid;
      if (!uid)
        return { success: false, message: "Authentication required." };

      const dropId = String(data?.dropId || "");
      const lat = toNumber(data?.lat);
      const lon = toNumber(data?.lon);
      if (!dropId || !isValidLatLon(lat, lon)) {
        return { success: false, message: "Invalid parameters." };
      }

      const ref = db.collection("drops").doc(dropId);

      const result = await db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        if (!snap.exists)
          return { success: false, message: "Drop not found." };
        const d = snap.data() || {};

        const status = String(d.status || "PENDING");
        if (status !== "PENDING" && status !== "PARTIAL") {
          return { success: false, message: "Not claimable." };
        }

        const nb = d?.trigger?.notBefore;
        const notBeforeMs =
          typeof nb === "number"
            ? nb
            : nb?.toMillis
            ? nb.toMillis()
            : null;
        if (notBeforeMs && Date.now() < notBeforeMs) {
          return { success: false, message: "Not unlocked yet." };
        }

        if ((d?.trigger?.type || "LOCATION") === "LOCATION") {
          const loc = d.location || {};
          const r = Number(loc.radiusM || 0);
          const lat0 = Number(loc.lat);
          const lon0 = Number(loc.lng);
          if (!r || isNaN(r) || isNaN(lat0) || isNaN(lon0)) {
            return {
              success: false,
              message: "Invalid location trigger.",
            };
          }
          const dist = Math.round(
            haversineMeters(lat0, lon0, lat, lon)
          );
          if (dist > r + 5) {
            return {
              success: false,
              message: `Too far (${dist}m).`,
            };
          }
        }

        const mode = String(d.mode || "PERSON").toUpperCase();
        const meta = d.metadata || {};
        let winnerId = d.winnerId || null;
        const groupClaims = { ...(d.groupClaims || {}) };

        if (mode === "PERSON") {
          if (String(d.recipientId || "") !== uid) {
            return {
              success: false,
              message: "Not the intended recipient.",
            };
          }
          winnerId = uid;
        } else if (mode === "GROUP") {
          const groupId = String(meta.groupId || "");
          const policy = String(
            meta.groupClaimPolicy || "FIRST"
          ).toUpperCase();
          if (!groupId) {
            return {
              success: false,
              message: "Missing groupId.",
            };
          }

          const gref = db
            .collection("users")
            .doc(String(d.senderId || ""))
            .collection("groups")
            .doc(groupId);
          const gsnap = await tx.get(gref);
          if (!gsnap.exists) {
            return {
              success: false,
              message: "Group not found.",
            };
          }
          const members = gsnap.data()?.members || [];
          if (!members.includes(uid)) {
            return {
              success: false,
              message: "Not a member of the group.",
            };
          }

          if (policy === "FIRST") {
            if (winnerId) {
              return {
                success: false,
                message: "Already claimed.",
              };
            }
            winnerId = uid;
          } else {
            if (groupClaims[uid]) {
              return {
                success: false,
                message: "You already claimed.",
              };
            }
            groupClaims[uid] = true;
          }
        } else if (mode === "TRUSTED_ANY") {
          const policy = String(
            meta.trustedClaimPolicy || "FIRST"
          ).toUpperCase();
          const cap = Number(meta.perUserCap || 1);

          const tref = db
            .collection("users")
            .doc(String(d.senderId || ""))
            .collection("trusted")
            .doc(uid);
          const tsnap = await tx.get(tref);
          if (!tsnap.exists || tsnap.data()?.enabled === false) {
            return {
              success: false,
              message: "Not in trusted list.",
            };
          }

          if (policy === "FIRST") {
            if (winnerId) {
              return {
                success: false,
                message: "Already claimed.",
              };
            }
            winnerId = uid;
          } else {
            const count = Number(groupClaims[uid] || 0);
            if (count >= cap) {
              return {
                success: false,
                message:
                  "Reached per-person cap.",
              };
            }
            groupClaims[uid] = count + 1;
          }
        } else {
          return {
            success: false,
            message: "Unknown mode.",
          };
        }

        let nextStatus = "PENDING";
        if (mode === "PERSON") nextStatus = "CLAIMED";
        else if (mode === "GROUP")
          nextStatus =
            String(
              meta.groupClaimPolicy || "FIRST"
            ).toUpperCase() === "FIRST"
              ? "CLAIMED"
              : "PARTIAL";
        else if (mode === "TRUSTED_ANY")
          nextStatus =
            String(
              meta.trustedClaimPolicy || "FIRST"
            ).toUpperCase() === "FIRST"
              ? "CLAIMED"
              : "PARTIAL";

        const nowTs = admin.firestore.Timestamp.now();
        const updates = {
          status: nextStatus,
          claimedAt: nowTs,
          claimedBy: uid,
          claimLocation: { lat, lng: lon },
        };
        if (winnerId) updates.winnerId = winnerId;
        if (Object.keys(groupClaims).length)
          updates.groupClaims = groupClaims;

        tx.update(ref, updates);
        return { success: true, status: nextStatus };
      });

      return result;
    } catch (err) {
      console.error("claimAutoRelease error:", err);
      return { success: false, message: "Server error." };
    }
  });

/* ==================== setUsername / Referrals ==================== */

exports.setUsername = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    try {
      enforceAppCheckOrSkip(context);

      const uid = context.auth?.uid;
      if (!uid)
        return { success: false, message: "Authentication required." };

      const raw = String(data?.username || "").trim();
      const norm = normalizeUsername(raw);
      if (!norm.ok) {
        return {
          success: false,
          message: norm.message || "Invalid username.",
        };
      }

      const { username, usernameLower } = norm;

      const userRef = db.collection("users").doc(uid);
      const reservationRef = db
        .collection("usernames")
        .doc(usernameLower);

      const result = await db.runTransaction(async (tx) => {
        const userSnap = await tx.get(userRef);
        const userDoc = userSnap.exists ? userSnap.data() || {} : {};
        const currentLower = String(
          userDoc.usernameLower || ""
        );

        if (currentLower === usernameLower) {
          return {
            success: true,
            message: "Username unchanged.",
            username,
          };
        }

        const resSnap = await tx.get(reservationRef);
        if (
          resSnap.exists &&
          (resSnap.data() || {}).uid !== uid
        ) {
          return {
            success: false,
            message: "That username is taken.",
          };
        }

        if (currentLower && currentLower !== usernameLower) {
          const oldRef = db
            .collection("usernames")
            .doc(currentLower);
          const oldSnap = await tx.get(oldRef);
          if (
            oldSnap.exists &&
            (oldSnap.data() || {}).uid === uid
          ) {
            tx.delete(oldRef);
          }
        }

        tx.set(reservationRef, {
          uid,
          updatedAt: admin.firestore.Timestamp.now(),
        });

        tx.set(
          userRef,
          {
            username,
            usernameLower,
            updatedAt: admin.firestore.Timestamp.now(),
          },
          { merge: true }
        );

        return {
          success: true,
          message: "Username set.",
          username,
        };
      });

      return result;
    } catch (err) {
      console.error("setUsername error:", err);
      return { success: false, message: "Server error." };
    }
  });

exports.setReferrer = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    try {
      enforceAppCheckOrSkip(context);

      const uid = context.auth?.uid;
      if (!uid)
        return { success: false, message: "Authentication required." };

      const raw = String(data?.username || "").trim();
      if (!raw) {
        return {
          success: false,
          message: "Missing referrer username.",
        };
      }

      const handle = raw.startsWith("@")
        ? raw.slice(1)
        : raw;
      const lower = handle.toLowerCase();

      const res = await db
        .collection("usernames")
        .doc(lower)
        .get();
      if (!res.exists) {
        return {
          success: false,
          message: "Referrer not found.",
        };
      }

      const refUid = res.data().uid;
      if (!refUid || refUid === uid) {
        return {
          success: false,
          message: "Invalid referrer.",
        };
      }

      const userRef = db.collection("users").doc(uid);
      let alreadyHadReferrer = false;

      await db.runTransaction(async (tx) => {
        const snap = await tx.get(userRef);
        const u = snap.data() || {};
        if (u.referrerUid) {
          alreadyHadReferrer = true;
          return;
        }
        tx.set(
          userRef,
          {
            referrerUid: refUid,
            referrerUsernameLower: lower,
            referrerSetAt:
              admin.firestore.Timestamp.now(),
            hasReferrer: true,
          },
          { merge: true }
        );
      });

      return {
        success: true,
        alreadyHadReferrer,
        hasReferrer:
          !alreadyHadReferrer || true,
      };
    } catch (err) {
      console.error("setReferrer error:", err);
      return { success: false, message: "Server error." };
    }
  });

exports.getReferralStatus = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    try {
      enforceAppCheckOrSkip(context);
      const uid = context.auth?.uid;
      if (!uid) {
        return {
          success: false,
          message: "Authentication required.",
        };
      }

      const snap = await db
        .collection("users")
        .doc(uid)
        .get();
      if (!snap.exists) {
        return {
          success: true,
          hasReferrer: false,
        };
      }

      const u = snap.data() || {};
      const refUid = u.referrerUid || null;
      return {
        success: true,
        hasReferrer: !!refUid,
        referrerUid: refUid,
        referrerUsernameLower:
          u.referrerUsernameLower || null,
      };
    } catch (err) {
      console.error("getReferralStatus error:", err);
      return { success: false, message: "Server error." };
    }
  });

/* ==================== Subscription webhook -> referral payouts ==================== */

exports.handleSubscriptionWebhook = functions
  .region("us-central1")
  .https.onRequest(async (req, res) => {
    try {
      if (req.method !== "POST") {
        return res
          .status(405)
          .send("Method Not Allowed");
      }

      const secret =
        process.env.REFERRAL_WEBHOOK_SECRET;
      if (secret) {
        const incoming =
          req.headers["x-webhook-secret"] ||
          req.headers["X-Webhook-Secret"] ||
          req.query.secret;
        if (incoming !== secret) {
          return res
            .status(401)
            .send("Unauthorized");
        }
      }

      const body = req.body || {};
      const uid =
        body.app_user_id ||
        body.userId ||
        body.uid;
      if (!uid) {
        return res
          .status(400)
          .send("Missing user id.");
      }

      const rawType =
        body.type || body.event || "";
      const type = String(rawType).toUpperCase();
      const eligibleTypes = [
        "RENEWAL",
        "INITIAL_PURCHASE",
      ];
      if (!eligibleTypes.includes(type)) {
        return res
          .status(200)
          .send("Ignored event type.");
      }

      const userSnap = await db
        .collection("users")
        .doc(uid)
        .get();
      if (!userSnap.exists) {
        return res
          .status(200)
          .send("User doc not found.");
      }

      const u = userSnap.data() || {};
      const referrerUid = u.referrerUid;
      const referralQualified =
        !!u.referralQualified;

      if (!referrerUid || !referralQualified) {
        return res
          .status(200)
          .send("No eligible referrer.");
      }

      const grossCents = cents(
        body.grossCents || 199
      );
      const feeBps = Number(
        process.env.SUB_FEE_BPS || 3000
      );
      const netCents = Math.max(
        0,
        Math.floor(
          (grossCents *
            (10000 - feeBps)) /
            10000
        )
      );

      const rewardCents = cents(
        netCents * 0.2
      );
      if (!rewardCents) {
        return res
          .status(200)
          .send("No reward.");
      }

      const idemKey =
        "referral:" +
        (body.event_id ||
          body.id ||
          `${uid}:${type}:${grossCents}`);

      const result =
        await creditReferralEarning({
          referrerUid,
          fromUid: uid,
          centsValue: rewardCents,
          idemKey,
          source: "subscription",
        });

      if (!result.success) {
        console.error(
          "Referral credit failed:",
          result
        );
      }

      return res.status(200).send({
        ok: true,
        creditedCents: rewardCents,
      });
    } catch (err) {
      console.error(
        "handleSubscriptionWebhook error:",
        err
      );
      return res
        .status(500)
        .send("Internal error");
    }
  });

/* ==================== Leaderboard & Demo Users ==================== */

const DEMO_LEADERBOARD_COLLECTION =
  "leaderboard_demo";

const DEMO_USERNAMES = [
  "Mike",
  "Sofia",
  "Jordan",
  "Alex",
  "Taylor",
  "Chris",
  "Riley",
  "Sam",
  "Jamie",
  "Morgan",
];

async function ensureDemoLeaders() {
  const col = db.collection(
    DEMO_LEADERBOARD_COLLECTION
  );
  const snap = await col
    .limit(1)
    .get();
  if (!snap.empty) return;

  const batch = db.batch();
  const now = admin.firestore.Timestamp.now();

  DEMO_USERNAMES.forEach(
    (name, idx) => {
      const id = `demo_${idx + 1}`;
      const total = Math.floor(
        30000 + Math.random() * 170000
      );
      batch.set(col.doc(id), {
        username: name,
        totalEarnedCents: total,
        isDemo: true,
        createdAt: now,
        updatedAt: now,
      });
    }
  );

  await batch.commit();
  console.log(
    "✅ Seeded demo leaderboard users"
  );
}

async function bumpDemoLeaders() {
  const col = db.collection(
    DEMO_LEADERBOARD_COLLECTION
  );
  const snap = await col.get();

  if (snap.empty) {
    await ensureDemoLeaders();
    return;
  }

  const batch = db.batch();
  const now = admin.firestore.Timestamp.now();

  snap.forEach((doc) => {
    const bump = Math.floor(
      5000 + Math.random() * 75000
    );
    batch.update(doc.ref, {
      totalEarnedCents:
        admin.firestore.FieldValue.increment(
          bump
        ),
      updatedAt: now,
    });
  });

  await batch.commit();
  console.log(
    "✅ Bumped demo leaderboard users"
  );
}

exports.leaderboardTopEarners = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    try {
      enforceAppCheckOrSkip(context);

      let limit = parseInt(
        data?.limit,
        10
      );
      if (
        !Number.isInteger(limit) ||
        limit <= 0 ||
        limit > 50
      ) {
        limit = 10;
      }

      const usersSnap = await db
        .collection("users")
        .orderBy(
          "totalEarnedCents",
          "desc"
        )
        .limit(limit * 2)
        .get();

      const realEntries =
        usersSnap.docs
          .map((doc) => {
            const u =
              doc.data() || {};
            const val = cents(
              u.totalEarnedCents || 0
            );
            if (val <= 0) return null;

            const usernameRaw =
              u.username ||
              u.usernameLower ||
              u.displayName ||
              String(doc.id).slice(
                0,
                6
              );

            const username = String(
              usernameRaw
            ).trim() || "User";

            return {
              id: doc.id,
              username,
              totalEarnedCents: val,
              isDemo: !!u.isDemo,
            };
          })
          .filter(Boolean);

      await ensureDemoLeaders();

      const demoSnap = await db
        .collection(
          DEMO_LEADERBOARD_COLLECTION
        )
        .orderBy(
          "totalEarnedCents",
          "desc"
        )
        .limit(limit)
        .get();

      const demoEntries =
        demoSnap.docs
          .map((doc) => {
            const d =
              doc.data() || {};
            const val = cents(
              d.totalEarnedCents || 0
            );
            if (val <= 0) return null;

            const usernameRaw =
              d.username ||
              d.displayName ||
              String(doc.id).slice(
                0,
                6
              );
            const username = String(
              usernameRaw
            ).trim() || "User";

            return {
              id: doc.id,
              username,
              totalEarnedCents: val,
              isDemo: true,
            };
          })
          .filter(Boolean);

      const combined = [
        ...realEntries,
        ...demoEntries,
      ].sort(
        (a, b) =>
          (b.totalEarnedCents || 0) -
          (a.totalEarnedCents || 0)
      );

      return {
        success: true,
        entries: combined.slice(
          0,
          limit
        ),
      };
    } catch (err) {
      console.error(
        "leaderboardTopEarners error:",
        err
      );
      throw new functions.https.HttpsError(
        "internal",
        "Failed to load leaderboard."
      );
    }
  });

exports.bumpDemoLeadersNow = functions
  .region("us-central1")
  .https.onCall(async () => {
    await bumpDemoLeaders();
    return { success: true };
  });

exports.bumpDemoLeadersMonthly = functions
  .region("us-central1")
  .pubsub.schedule("0 7 1 * *")
  .onRun(async () => {
    await bumpDemoLeaders();
    return null;
  });

/* ==================== Echo Plinko Game (Real-Money) ==================== */

/**
 * House-profitable Plinko configuration.
 *
 * Multipliers must match the client UI:
 *  [0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0]
 *
 * Weights are relative probabilities in percent.
 * EV ≈ 0.96x (about 4% house edge).
 */
const PLINKO_MULTIPLIERS = [0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0];
const PLINKO_WEIGHTS =     [25,   25,   20,   15,   8,   5,   2]; // sum = 100

// Allowed bet sizes in cents. MUST match the iOS segmented control.
const PLINKO_ALLOWED_ENTRY_CENTS = [25, 50, 100]; // $0.25, $0.50, $1.00

function pickPlinkoSlotIndex() {
  const totalWeight = PLINKO_WEIGHTS.reduce((a, b) => a + b, 0);
  const r = Math.random() * totalWeight;
  let cum = 0;
  for (let i = 0; i < PLINKO_WEIGHTS.length; i++) {
    cum += PLINKO_WEIGHTS[i];
    if (r < cum) return i;
  }
  return PLINKO_WEIGHTS.length - 1; // fallback
}

/**
 * games_playEchoPlinko
 *
 * Real-money Plinko round:
 * - Verifies auth + App Check
 * - Verifies entryCostCents is allowed
 * - Debits entry from wallet
 * - Randomly selects a multiplier with house-edge odds
 * - Credits winnings back to wallet
 * - Logs a game record
 *
 * Returns to client:
 *  {
 *    success: true,
 *    newBalanceCents: number,
 *    winAmountCents: number,
 *    multiplier: number,
 *    slotIndex: number,
 *    message: string
 *  }
 *
 * On error (no funds / not signed in / invalid bet), throws HttpsError.
 */
exports.games_playEchoPlinko = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    // App Check + auth guard
    enforceAppCheckOrSkip(context);

    const uid = context.auth?.uid;
    if (!uid) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "Authentication required."
      );
    }

    // Validate entry cost
    const entryCostCents = cents(data?.entryCostCents);
    if (
      !isInt(entryCostCents) ||
      entryCostCents <= 0 ||
      !PLINKO_ALLOWED_ENTRY_CENTS.includes(entryCostCents)
    ) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Invalid entry cost."
      );
    }

    const userRef = await ensureUserWallet(uid);

    let outcome = null;

    try {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(userRef);
        if (!snap.exists) {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "Wallet not found."
          );
        }

        const u = snap.data() || {};
        const currentAvail = cents(u.availableCents || 0);

        if (currentAvail < entryCostCents) {
          throw new functions.https.HttpsError(
            "failed-precondition",
            "Not enough funds to play."
          );
        }

        // Current Echo Balance mirror (for Digital Wallet Mode)
        const currentEcho = cents(
          u.echoBalanceUSD_cents !== undefined
            ? u.echoBalanceUSD_cents
            : u.availableCents || 0
        );

        // ----- Random outcome (house edge baked into weights) -----
        const slotIndex = pickPlinkoSlotIndex();
        const multiplier = PLINKO_MULTIPLIERS[slotIndex] ?? 0.0;

        const winAmountCents = cents(entryCostCents * multiplier);

        // New balances after cost + win
        const newAvail =
          currentAvail - entryCostCents + winAmountCents;
        const newEcho =
          currentEcho - entryCostCents + winAmountCents;

                const now = admin.firestore.Timestamp.now();

        // Never allow negative
        const safeAvail = Math.max(0, newAvail);
        const safeEcho = Math.max(0, newEcho);

        // House result for this round (can be negative if player wins big)
        const houseNetCents = entryCostCents - winAmountCents; // >0 = house profit, <0 = house 	loss
        const houseResult =
          houseNetCents > 0 ? "PROFIT" :
          houseNetCents < 0 ? "LOSS" :
          "EVEN";

        tx.update(userRef, {
          availableCents: safeAvail,
          echoBalanceUSD_cents: safeEcho,
          updatedAt: now,
        });

        // Log game round for analytics / dispute review + house stats
        const gameRef = db.collection("games_echoPlinko").doc();
        tx.set(gameRef, {
          uid,
          entryCostCents,
          winAmountCents,
          multiplier,
          slotIndex,
          beforeBalanceCents: currentAvail,
          afterBalanceCents: safeAvail,
          echoBalanceUSD_cents_after: safeEcho,
          houseNetCents,
          houseResult,
          createdAt: now,
        });


        // Prepare outcome payload for client
        let message;
        if (winAmountCents > entryCostCents) {
          const profit = (winAmountCents - entryCostCents) / 100;
          message = `You won and profited $${profit.toFixed(2)}!`;
        } else if (winAmountCents === entryCostCents) {
          message = "You broke even.";
        } else if (winAmountCents > 0) {
          const netLoss =
            (entryCostCents - winAmountCents) / 100;
          message = `You won some back, net –$${netLoss.toFixed(
            2
          )}.`;
        } else {
          message = "Tough drop – you lost this round.";
        }

        outcome = {
          success: true,
          newBalanceCents: safeAvail,
          winAmountCents,
          multiplier,
          slotIndex,
          message,
        };
      });

      return outcome;
    } catch (err) {
      console.error("games_playEchoPlinko error:", err);

      // Keep HttpsError codes intact; convert others to generic internal error
      if (err instanceof functions.https.HttpsError) {
        throw err;
      }
      throw new functions.https.HttpsError(
        "internal",
        "Plinko round failed. Please try again."
      );
    }
  });

// ==== Wallet Top-Up Checkout Session (Stripe) =====

// ==== Wallet Top-Up Checkout Session (Stripe, game wallet only) =====

exports.wallet_createTopUpCheckoutSession = functions
  .region("us-central1")
  .runWith({ secrets: ["STRIPE_SECRET_KEY"] })
  .https.onCall(async (data, context) => {
    // Optional: App Check guard if you want it here too
    enforceAppCheckOrSkip(context);

    const uid = context.auth?.uid;
    if (!uid) {
      throw new functions.https.HttpsError(
        "unauthenticated",
        "Must be signed in."
      );
    }

    const rawAmount = data?.amountUSD;
    const amountUSD = Number(rawAmount);
    if (!Number.isFinite(amountUSD) || amountUSD <= 0) {
      throw new functions.https.HttpsError(
        "invalid-argument",
        "Invalid amount."
      );
    }

    // Clamp $1–$5,000 server-side too
    const safeUSD = Math.max(1, Math.min(5000, Math.floor(amountUSD)));
    const cents = Math.round(safeUSD * 100);

    const successUrl =
      typeof data?.successUrl === "string" && data.successUrl.length
        ? data.successUrl
        : "https://hardcoreamature.com/registration-complete/";
    const cancelUrl =
      typeof data?.cancelUrl === "string" && data.cancelUrl.length
        ? data.cancelUrl
        : "https://hardcoreamature.com/stripe-registration-failed/";

    try {
      const stripe = Stripe(process.env.STRIPE_SECRET_KEY);

      const session = await stripe.checkout.sessions.create({
        mode: "payment",
        payment_method_types: ["card"],
        line_items: [
          {
            price_data: {
              currency: "usd",
              product_data: {
                name: "EchoTether Game Wallet Top-Up",
              },
              unit_amount: cents,
            },
            quantity: 1,
          },
        ],
        success_url: successUrl,
        cancel_url: cancelUrl,
        metadata: {
          uid,
          type: "wallet_topup",
        },
      });

      return {
        success: true,
        url: session.url,
      };
    } catch (err) {
      console.error("wallet_createTopUpCheckoutSession Stripe error:", err);
      throw new functions.https.HttpsError("internal", "Stripe Error");
    }
  });

/**
 * stripeWebhook
 * - Dedicated webhook for WALLET top-ups only.
 * - Does NOT touch whispers; it only updates users/{uid}.availableCents & echoBalanceUSD_cents.
 *
 * Configure this URL as a Stripe webhook endpoint and send at least:
 *  - checkout.session.completed
 */
exports.stripeWebhook = functions
  .region("us-central1")
  .runWith({
    secrets: ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"],
  })
  .https.onRequest(async (req, res) => {
    if (req.method !== "POST") {
      return res.status(405).send("Method Not Allowed");
    }

    const stripe = Stripe(process.env.STRIPE_SECRET_KEY);
    const STRIPE_WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET;
    const sig = req.headers["stripe-signature"];

    let event;
    try {
      event = stripe.webhooks.constructEvent(
        req.rawBody,
        sig,
        STRIPE_WEBHOOK_SECRET
      );
    } catch (err) {
      console.error("Wallet webhook signature verification failed:", err);
      return res.status(400).send("Webhook Error");
    }

    try {
      if (event.type === "checkout.session.completed") {
        const session = event.data.object;

        // Only handle wallet top-ups here; ignore everything else
        if (session.metadata?.type === "wallet_topup") {
          const uid = session.metadata.uid;
          const amountTotal = session.amount_total; // cents

          if (!uid || !Number.isInteger(amountTotal) || amountTotal <= 0) {
            console.warn("⚠️ Wallet webhook: invalid metadata or amount:", {
              uid,
              amountTotal,
            });
          } else {
            const userRef = db.collection("users").doc(uid);

            // Idempotency guard
            const idemId = `walletTopup:${session.payment_intent || session.id}`;
            const idemRef = db.collection("transactions").doc(idemId);

            await db.runTransaction(async (tx) => {
              const already = await tx.get(idemRef);
              if (already.exists) return;

              const snap = await tx.get(userRef);
              const now = admin.firestore.Timestamp.now();

              if (!snap.exists) {
                // Create new wallet doc
                tx.set(userRef, {
                  availableCents: amountTotal,
                  pendingWithdrawalCents: 0,
                  stripeAccountId: null,
                  totalEarnedCents: 0,
                  totalWhispersClaimed: 0,
                  totalReferralCents: 0,
                  echoBalanceUSD_cents: amountTotal,
                  echoBalanceCrypto: { USDC: 0, BTC: 0, ETH: 0 },
                  digitalWalletModeEnabled: false,
                  defaultPayoutAsset: "USD",
                  createdAt: now,
                  updatedAt: now,
                });
              } else {
                const u = snap.data() || {};
                tx.update(userRef, {
                  availableCents: admin.firestore.FieldValue.increment(
                    amountTotal
                  ),
                  echoBalanceUSD_cents: admin.firestore.FieldValue.increment(
                    amountTotal
                  ),
                  updatedAt: now,
                });
              }

              tx.set(idemRef, {
                type: "walletTopup",
                uid,
                cents: amountTotal,
                paymentIntentId: session.payment_intent || null,
                ts: now,
                source: "stripe",
              });
            });
          }
        }
      }

      return res.json({ received: true });
    } catch (err) {
      console.error("stripeWebhook (wallet) handler error:", err);
      return res.status(500).send("Internal error");
    }
  });
