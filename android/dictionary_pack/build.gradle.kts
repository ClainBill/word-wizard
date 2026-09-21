// The dictionary (assets/db/dictionary.db, ~470 MB) as a Play Asset
// Delivery install-time pack. It installs with the app — the app never
// waits for a download — but lives outside the base module, whose size
// Play caps at 200 MB. The file under src/main/assets is a symlink to the
// pipeline's output so the same database serves iOS (a bundle resource)
// and the tests. The app reads it through AssetManager at first launch
// and copies it to app storage (MainActivity's `word_wizard/dictionary`
// channel); a plain `flutter build apk` includes the pack in the APK.
plugins {
    id("com.android.asset-pack")
}

assetPack {
    packName.set("dictionary_pack")
    dynamicDelivery {
        deliveryType.set("install-time")
    }
}
