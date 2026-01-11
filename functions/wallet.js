const functions = require("firebase-functions");
const admin = require("firebase-admin");
if (!admin.apps.length) admin.initializeApp();
const db = admin.firestore();

exports.addFundsToWhisper = functions
  .region("us-central1")
  .https.onCall(async (data, context) => {
    const { whisperId, amount, txSource } = data;
    if (!whisperId || !amount) {
      throw new functions.https.HttpsError("invalid-argument", "Missing whisperId or amount");
    }
    if (amount <= 0) {
      throw new functions.https.HttpsError("failed-precondition", "Amount must be positive");
    }

    const whisperRef = db.collection("whispers").doc(whisperId);
    const snap = await whisperRef.get();
    if (!snap.exists) {
      throw new functions.https.HttpsError("not-found", "Whisper not found");
    }

    const whisper = snap.data();
    const prevBalance = whisper.balance || 0;
    const newBalance = prevBalance + amount;

    await whisperRef.update({
      balance: newBalance,
      lastTopUpAt: admin.firestore.FieldValue.serverTimestamp(),
      lastTxSource: txSource || "manual"
    });

    return { success: true, newBalance };
  });
