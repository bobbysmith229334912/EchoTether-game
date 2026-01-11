{
  "indexes": [
    {
      "collectionGroup": "whispers",
      "queryScope": "COLLECTION",
      "fields": [
        { "fieldPath": "ownerId",   "order": "ASCENDING"  },
        { "fieldPath": "timestamp", "order": "DESCENDING" },
        { "fieldPath": "__name__",  "order": "ASCENDING"  }
      ]
    }
  ],
  "fieldOverrides": []
}
