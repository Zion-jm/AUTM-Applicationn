// ─────────────────────────────────────────────────────────────
// secrets.example.h
//
// Copy this file to `secrets.h` (same folder) and fill in your
// real values. `secrets.h` is gitignored so credentials never get
// committed.
//
//   cp secrets.example.h secrets.h
//
// IMPORTANT: if a DATABASE_SECRET was ever shared/leaked, regenerate
// it in the Firebase Console (Project Settings → Service accounts →
// Database secrets) before using it here.
// ─────────────────────────────────────────────────────────────
#pragma once

#define WIFI_SSID       "YOUR_WIFI_SSID"
#define WIFI_PASSWORD   "YOUR_WIFI_PASSWORD"

#define DATABASE_URL    "https://YOUR-PROJECT-default-rtdb.asia-southeast1.firebasedatabase.app"
#define DATABASE_SECRET "YOUR_REGENERATED_DATABASE_SECRET"
