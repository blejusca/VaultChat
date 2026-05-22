# VaultChat ProGuard / R8 rules

# ── Flutter ────────────────────────────────────────────────────────────────────
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.**

# ── Flutter plugins ────────────────────────────────────────────────────────────
-keep class io.flutter.plugins.** { *; }

# ── Hive ───────────────────────────────────────────────────────────────────────
-keep class com.hivedb.** { *; }
-keepclassmembers class * {
    @com.hivedb.hive.annotations.HiveType *;
    @com.hivedb.hive.annotations.HiveField *;
}

# ── flutter_secure_storage ─────────────────────────────────────────────────────
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# ── local_auth (biometrics) ────────────────────────────────────────────────────
-keep class io.flutter.plugins.localauth.** { *; }

# ── Kotlin / coroutines ────────────────────────────────────────────────────────
-keep class kotlin.** { *; }
-keep class kotlinx.coroutines.** { *; }
-dontwarn kotlinx.coroutines.**

# ── General Android ────────────────────────────────────────────────────────────
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# ── Remove all logging in release ──────────────────────────────────────────────
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
    public static int w(...);
    public static int e(...);
}
