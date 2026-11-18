# Flutter wrapper & engine classes
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep MainActivity
-keep class com.bosskevs.mobile_app.** { *; }

# Prevent R8 warnings on optional annotations and unused Flutter Play Core deferred components
-dontwarn java.lang.invoke.StringConcatFactory
-dontwarn javax.annotation.**
-dontwarn com.google.android.play.core.**
