# libv2ray (AndroidLibXrayLite, gomobile): Go calls back into these classes
# over JNI by name, so R8 must not rename or drop them.
-keep class libv2ray.** { *; }
-keep class go.** { *; }
-keep class com.github.blueboytm.flutter_v2ray.** { *; }
