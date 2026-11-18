# Google Play Store Publishing Guide — KEVS SIOMAI

This guide walks you step-by-step through publishing the **KEVS SIOMAI** Android app (`com.bosskevs.mobile_app`) using your **Google Play Console** account.

---

## What Is Already Configured in Your Project

- **App Name:** `KEVS SIOMAI` (`AndroidManifest.xml` & `Info.plist`)
- **Application ID / Package Name:** `com.bosskevs.mobile_app`
- **Release Signing:** Configured in `mobile_app/android/app/build.gradle.kts` using `mobile_app/android/key.properties` and `mobile_app/android/app/upload-keystore.jks`
- **Code Shrinking & Obfuscation (R8/ProGuard):** Enabled for release builds (`proguard-rules.pro`)
- **HTTPS-Only Network Security:** Enforced for release builds (`network_security_config.xml`), while debug builds still allow local LAN/localhost testing
- **Production Settings Polish:** Developer/localhost server IP settings are automatically hidden in release builds (`kDebugMode`), and customers see a clean **Privacy Policy** & **Customer Support** section
- **Privacy Policy Web Page:** Created at `frontend/privacy-policy.html` and served at `/privacy-policy` via `backend/app.py`
- **Play Store Graphics:** Ready in `play_store_assets/`:
  - `play_store_assets/app_icon_512x512.png` (512 × 512 px)
  - `play_store_assets/feature_graphic_1024x500.png` (1024 × 500 px)

---

## IMPORTANT: Back Up Your Upload Keystore Immediately!

Your release signing files are stored locally and are **ignored by Git** for security:
1. `mobile_app/android/app/upload-keystore.jks`
2. `mobile_app/android/key.properties`

> **WARNING:** Back up BOTH files to a secure private location (encrypted USB drive, password manager, or private cloud vault). **Never** push them to a public Git repository. If you lose `upload-keystore.jks`, you will have to request an upload key reset from Google Play Support before publishing updates.

---

## Step 1: Deploy Your Privacy Policy to Render

Google Play Console checks that your Privacy Policy URL loads publicly over HTTPS.

1. Commit and push the updated `backend/app.py` and `frontend/privacy-policy.html` to your Git repository connected to Render (remember: `.jks` and `key.properties` are automatically excluded by `.gitignore`).
2. Wait for Render to finish deploying.
3. Open this URL in your browser to confirm it loads cleanly:
   ```
   https://kevs-siomai.onrender.com/privacy-policy
   ```

---

## Step 2: Build (or Rebuild) Your Signed Android App Bundle (`.aab`)

If you ever need to rebuild the release `.aab` (or after making code changes):

```powershell
cd c:\Users\Vic\Desktop\KevsSiomai\kevs-siomai-main\mobile_app
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
flutter build appbundle --release
```

Your ready-to-upload file will be located at:
```
mobile_app\build\app\outputs\bundle\release\app-release.aab
```

> **Note:** Google Play requires **`.aab`** (Android App Bundle), NOT `.apk`.
>
> **Tip for Rebuilding on Windows:** If Flutter prints *"Release app bundle failed to strip debug symbols"* at the very end because Android SDK `cmdline-tools` (`apkanalyzer`) is not installed yet, Gradle still builds and signs `app-release.aab` with stripped native libraries and `.so.sym` debug symbols included. To clear that check permanently, open **Android Studio → Settings → Languages & Frameworks → Android SDK → SDK Tools** and install **Android SDK Command-line Tools (latest)**.

---

## Step 3: Create Your App in Google Play Console

1. Sign in to [Google Play Console](https://play.google.com/console).
2. Click **Create app**.
3. Fill out the initial details:
   - **App name:** `KEVS SIOMAI`
   - **Default language:** `English (United States)` (or `Filipino`)
   - **App or game:** `App`
   - **Free or paid:** `Free`
4. Check the **Developer Program Policies** and **US export laws** declarations.
5. Click **Create app**.

---

## Step 4: Complete "Set up your app" Tasks (Dashboard Checklist)

Go to **Dashboard → Set up your app** and complete every section:

### 1. Privacy policy
- Enter URL: `https://kevs-siomai.onrender.com/privacy-policy`
- Click **Save**.

### 2. App access
- Select: **All functionality in my app is available without any access restrictions** (customers can browse, order, and track queues without a mandatory login).
- Click **Save**.

### 3. Ads
- Select: **No, my app does not contain ads**.
- Click **Save**.

### 4. Content rating
- Click **Start questionnaire**, enter your developer email, and choose category: **All Other App Types**.
- Answer **No** to violence, sexuality, language, controlled substances, gambling, etc.
- Save and click **Submit** (you should receive an **Everyone / PEGI 3** rating).

### 5. Target audience and content
- Select target age group: **18 and over** (or **13–15, 16–17, 18 and over**).
- Do **NOT** select ages under 13 unless you intend to comply with Google Play's Families Policy.
- Appeal to children unintentionally? Select **No**.
- Click **Save**.

### 6. News apps
- Select: **No**.

### 7. COVID-19 contact tracing and status apps
- Select: **My app is not a publicly available COVID-19 contact tracing or status app**.

### 8. Data safety
Click **Next** through the overview, then answer:
- **Does your app collect or share any of the required user data types?** → **Yes**
- **Is all of the user data collected by your app encrypted in transit?** → **Yes** (HTTPS is enforced)
- **Do you provide a way for users to request that their data is deleted?** → **Yes** (users can contact store support as stated in the Privacy Policy)
- **Data types collected** (check ONLY these):
  - **Personal info → Name** (Collected, Optional/Required for orders, App functionality, NOT shared)
  - **Personal info → Phone number** (Collected, App functionality, NOT shared)
  - **Personal info → Address** (Collected, Optional — for delivery orders only, App functionality, NOT shared)
  - **Financial info → Purchase history** (Collected, App functionality — order history & queue records, NOT shared)
- Click **Save**.

### 9. Government apps
- Select: **No**.

### 10. Financial features
- Select: **My app doesn't provide any financial features** (customers pay via Cash or externally via GCash QR verified manually; the app does not process credit cards, loans, or digital wallets).

### 11. Health features
- Select: **My app doesn't have any health features**.

### 12. Store settings (Category & Contact Details)
- **App category:** `Food & Drink`
- **Tags (optional):** `Food ordering`, `Food & Drink`
- **Email address:** Enter your active support email address (displayed publicly on Google Play)
- **Phone number (optional):** `+639212961820`
- **Website (optional):** `https://kevs-siomai.onrender.com`

---

## Step 5: Set Up Your Main Store Listing

Go to **Grow users → Store presence → Main store listing** and fill in:

- **App name:** `KEVS SIOMAI`
- **Short description** *(max 80 characters)*:
  ```
  Order fresh HotSpot Siomai & drinks and track your queue live in real time!
  ```
- **Full description**:
  ```
  Craving hot, freshly steamed siomai in Santa Cruz, Laguna? Order faster and skip the waiting line with the official KEVS SIOMAI mobile app!

  KEY FEATURES:
  • Browse the Full Menu — Order our signature HotSpot Siomai, ice-cold drinks (Coke, Royal, Sprite), and house-made condiments (Chilli Garlic, Soy Sauce, Calamansi).
  • Pickup & Delivery — Choose convenient store pickup or local delivery right from your phone.
  • Live Real-Time Queue Tracker — Watch the current serving number and track your order status from Pending to Preparing to Ready!
  • Cash & GCash Support — Pay in cash or view our official GCash QR code for fast cashless checkout.
  • Saved Customer Profile — Save your name, contact number, and default address locally for one-tap checkout next time.
  • Store Location & Hours — Open directions to KEVS SIOMAI (070 Batisan, Gatid, Santa Cruz, Laguna) directly in Google Maps.
  • Light & Dark Mode — Switch themes anytime in Profile & Settings.

  Store Hours: Open Daily, 4:00 PM – 12:00 AM
  Support Hotline: 0921-296-1820
  ```
- **App icon (512 × 512 px):** Upload `play_store_assets/app_icon_512x512.png`
- **Feature graphic (1024 × 500 px):** Upload `play_store_assets/feature_graphic_1024x500.png`
- **Phone screenshots (Required — minimum 2 screenshots):**
  - Run the app on your Android phone or emulator (`flutter run --release`) and take **2 to 4 portrait screenshots**:
    1. Menu / Home screen
    2. Cart / Checkout screen
    3. Live Queue Tracker screen
    4. Store Location screen
  - Upload those screenshots under **Phone screenshots**.

Click **Save**.

---

## Step 6: Upload Your `.aab` & Publish

> **Check your Google Play Console Account Type:**
> - **Personal account created AFTER Nov 13, 2023:** Google requires **Closed Testing** with at least **12 testers opted in continuously for 14 days** before unlocking Production.
> - **Organization account (or Personal account created before Nov 13, 2023):** You can publish directly to **Production**.

### Option A: Personal Account (Closed Testing First — 14 Days)
1. Go to **Test and release → Testing → Closed testing**.
2. Click **Manage track** on the default `Closed testing - Alpha` track (or **Create track**).
3. Under **Countries / regions**, click **Add countries / regions** and select **Philippines** (or all countries).
4. Under **Testers**, create an email list and add at least **12–15 Gmail addresses** (friends, family, classmates, or teammates). Click **Save**.
5. Go to **Releases → Create new release**.
6. Under **App signing**, accept **Google Play App Signing** (recommended — click **Continue** / **Use Google-generated key**).
7. Upload `mobile_app\build\app\outputs\bundle\release\app-release.aab`.
8. **Release name:** `1.0.0 (1)`
9. **Release notes:**
   ```
   Initial release of KEVS SIOMAI mobile app featuring menu ordering, pickup & delivery checkout, GCash QR payment option, real-time queue tracking, and store map directions.
   ```
10. Click **Next → Save → Go to overview → Send changes for review**.
11. Once approved (usually 1–3 days), copy the **Join on Android / Join on the web** link from the **Testers** tab and send it to your testers so they opt in and install the app.
12. After **14 continuous days** with 12+ opted-in testers, go to **Dashboard → Apply for production access**, answer the brief testing summary questions, and once approved, promote your release to **Production**!

### Option B: Direct Production Release (Organization / Older Personal Account)
1. Go to **Test and release → Production**.
2. Under **Countries / regions**, select **Philippines** (or desired regions).
3. Click **Create new release**.
4. Accept **Google Play App Signing**.
5. Upload `mobile_app\build\app\outputs\bundle\release\app-release.aab`.
6. Fill in Release Name (`1.0.0 (1)`) and Release Notes.
7. Click **Next → Save → Send changes for review**.
8. Once Google's review passes (typically 1–7 days for a new app), your app goes live on Google Play!

---

## Step 7: Publishing Future App Updates

Whenever you want to release a new version:
1. Open `mobile_app/pubspec.yaml` and **increment BOTH numbers** in `version`:
   ```yaml
   # Example: moving from 1.0.0+1 to 1.0.1+2
   version: 1.0.1+2
   ```
   *(The number after `+` is the `versionCode`—Google Play requires it to be strictly higher on every upload.)*
2. Rebuild the signed bundle:
   ```powershell
   cd c:\Users\Vic\Desktop\KevsSiomai\kevs-siomai-main\mobile_app
   $env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
   flutter build appbundle --release
   ```
3. Upload the new `app-release.aab` in Google Play Console → **Production → Create new release**.
