# Keep JNI native methods
-keepclassmembers class io.github.ivere27.synurang.SynurangJni {
    native <methods>;
}

# Keep classes accessed via reflection in ProcessHost.createOkHttpChannel()
-keep class io.grpc.okhttp.OkHttpChannelBuilder {
    public static *** forTarget(...);
    public *** socketFactory(...);
    public *** build();
}
-keep class io.grpc.InsecureChannelCredentials {
    public static *** create();
}
-keep class io.grpc.ChannelCredentials { *; }
-dontwarn io.grpc.okhttp.OkHttpChannelBuilder
-dontwarn io.grpc.InsecureChannelCredentials
-dontwarn io.grpc.ChannelCredentials
