# Verifone Payment SDK ProGuard Rules
-keep class com.verifone.** { *; }
-dontwarn com.verifone.**

# Data Binding / View Binding often used in SDKs
-keep class **.databinding.** { *; }
-keep class **.BR { *; }
-dontwarn **.databinding.**

# Maintain line numbers for easier debugging of crashes
-keepattributes SourceFile,LineNumberTable

# Standard Flutter/Android rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Fix for missing Play Core classes in R8
-dontwarn com.google.android.play.core.**
