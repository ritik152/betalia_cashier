# ================================================================
# Verifone Payment SDK ProGuard Rules
# ================================================================
-keep class com.verifone.** { *; }
-keep class com.verifone.payment_sdk.** { *; }
-keep,allowobfuscation interface com.verifone.** { *; }
-dontwarn com.verifone.**

# Keep all enum values used by PSDK
-keepclassmembers,allowoptimization enum com.verifone.payment_sdk.** {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Keep CommerceListener implementations
-keep class * extends com.verifone.payment_sdk.CommerceListenerAdapter { *; }
-keep class * implements com.verifone.payment_sdk.CommerceListener { *; }

# Data Binding / View Binding used by PSDK
-keep class **.databinding.** { *; }
-keep class **.BR { *; }
-dontwarn **.databinding.**

# Keep serializable PSDK objects
-keepclassmembers class * extends com.verifone.payment_sdk.Status implements java.io.Serializable { *; }
-keepclassmembers class * extends com.verifone.payment_sdk.StatusInformation implements java.io.Serializable { *; }

# Keep PSDK event classes for reflection
-keep class com.verifone.payment_sdk.PaymentCompletedEvent { *; }
-keep class com.verifone.payment_sdk.TransactionEvent { *; }
-keep class com.verifone.payment_sdk.CommerceEvent { *; }
-keep class com.verifone.payment_sdk.Status { *; }

# Keep Parcelable/Serializeable classes
-keepclassmembers class * implements android.os.Parcelable {
    static ** CREATOR;
}
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    !static !transient <fields>;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# Maintain line numbers for debugging
-keepattributes SourceFile,LineNumberTable,*Annotation*,Signature,InnerClasses,EnclosingMethod

# Standard Flutter/Android rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Kotlin reflection
-keep class kotlin.reflect.** { *; }
-keep class kotlin.Metadata { *; }

# Coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-keepclassmembers class kotlinx.coroutines.** {
    volatile <fields>;
}

# Fix for missing Play Core classes in R8
-dontwarn com.google.android.play.core.**

# Keep org.json (used for JSON response building)
-keep class org.json.** { *; }
